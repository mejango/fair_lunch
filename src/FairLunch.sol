// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@jbx-protocol/juice-contracts-v3/contracts/abstract/JBPayoutRedemptionPaymentTerminal3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBCurrencies.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBSplitsGroups.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

// copy from import '@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol';
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// mmmmmmm, delicious.
//
// Pass the blunt to this contract to automatically launch an LP after a fundraise. No governance needed to decide who eats, ever. We believe in a fair lunch.
contract FairLunch is IERC721Receiver {
    // Thrown when some parameter doesn't make sense.
    error YUCK();
    // Can't serve lunch twice.
    error LUNCH_ALREADY_SERVED();
    // Only when the blunt has been passed can lunch be served.
    error LUNCH_CANT_BE_SERVED_YET();

    // Yumm
    event LunchWasServed(uint256 projectId, uint256 lpId, uint256 projectBalance, uint256 tokensToMint, address sender);
    // Yumm
    event CrumbsWereSwept(
        uint256 projectId, uint256 lpId, uint256 ethFeeAmount, uint256 tokenFeeAmount, address sender
    );
    event BluntHasBeenPassed(uint256 projectId);

    uint256 private constant _TOTAL_PERCENT = 100;
    mapping(uint256 => bool) lunchHasBeenServedFor;
    mapping(uint256 => bool) lunchCanBeServedFor;
    uint256 lpSupplyMultiplier;
    IJBController3_1 controller;
    INonfungiblePositionManager positionManager;
    string symbol;
    string name;
    IWETH9 weth;
    mapping(uint256 => uint256) lpIdOf;

    // _lpPercent is out of 100. The percent of currently outstanding tokens that should be minted for LPing.
    constructor(
        uint256 _lpSupplyMultiplier,
        string memory _symbol,
        string memory _name,
        IJBController3_1 _controller,
        INonfungiblePositionManager _positionManager,
        IWETH9 _weth
    ) {
        if (_lpSupplyMultiplier <= 0) revert YUCK();
        lpSupplyMultiplier = _lpSupplyMultiplier;
        symbol = _symbol;
        name = _name;
        controller = _controller;
        positionManager = _positionManager;
        weth = _weth;
    }

    // mmmmm delicious.
    //
    // Anyone can send this transaction to serve the lunch once the blunt has been passed. Lunch can only be served once.
    function serveLunch(uint256 _projectId) external {
        // Make sure lunch hasn't yet been served.
        if (lunchHasBeenServedFor[_projectId]) revert LUNCH_ALREADY_SERVED();

        // Make sure lunch is servable.
        if (!lunchCanBeServedFor[_projectId]) revert LUNCH_CANT_BE_SERVED_YET();

        // Keep a reference to the project's payment terminal, where its funds are stored.
        JBPayoutRedemptionPaymentTerminal3_1 _terminal = JBPayoutRedemptionPaymentTerminal3_1(
            address(controller.directory().primaryTerminalOf(_projectId, JBTokens.ETH))
        );

        // Keep a reference to the project's ETH balance.
        uint256 _projectBalance = _terminal.store().balanceOf(_terminal, _projectId);

        ///// 1. Create ERC-20 for the project.

        IERC20 _token = IERC20(address(controller.tokenStore().issueFor(_projectId, name, symbol)));

        // Keep a reference to the expected currency.
        uint256 _currency = _terminal.currencyForToken(JBTokens.ETH);

        ///// 2. Schedule new funding cycle rules starting immediately that allows owner minting and distribution of all ETH in the project treasury to this contract.

        // Set fund access constraints to make all funds distributable.
        JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
        _fundAccessConstraints[0] = JBFundAccessConstraints({
            terminal: _terminal,
            token: JBTokens.ETH,
            distributionLimit: _projectBalance,
            distributionLimitCurrency: _currency,
            overflowAllowance: 0,
            overflowAllowanceCurrency: 0
        });
        // Add a 100% split routed to this contract.
        JBSplit memory _split = JBSplit({
            preferClaimed: false,
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: payable(address(this)),
            lockedUntil: 0,
            allocator: IJBSplitAllocator(address(0))
        });
        // Package it up.
        JBSplit[] memory _splits = new JBSplit[](1);
        _splits[0] = _split;
        JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1);
        _groupedSplits[0] = JBGroupedSplits({group: JBSplitsGroups.ETH_PAYOUT, splits: _splits});

        // Set the new rules.
        controller.reconfigureFundingCyclesOf(
            _projectId,
            JBFundingCycleData({
                duration: 0, // doesn't matter since no other reconfigurations are possible.
                weight: 0, // doesn't matter since payments are paused.
                discountRate: 0, // doesn't matter since no other reconfigurations are possible.
                ballot: IJBFundingCycleBallot(address(0)) // doesn't matter since no other reconfigurations are possible.
            }),
            JBFundingCycleMetadata({
                global: JBGlobalFundingCycleMetadata({
                    allowSetTerminals: false, // no need
                    allowSetController: false, // no need
                    pauseTransfers: false // no need
                }),
                reservedRate: 0, // no need
                redemptionRate: JBConstants.MAX_REDEMPTION_RATE, // refund whenever.
                ballotRedemptionRate: JBConstants.MAX_REDEMPTION_RATE, // doesn't matter since no ballot is used.
                pausePay: true, // IMPORTANT. No more payments.
                pauseDistributions: false, // IMPORTANT. Distributions must be enabled.
                pauseRedeem: false, // IMPORTANT. Redeeming must be enabled.
                pauseBurn: false, // IMPORTANT. Burning must be enabled.
                allowMinting: true, // IMPORTANT. We must allow the project's owner (this contract) to be able to mint new tokens on demand.
                allowTerminalMigration: false, // no need
                allowControllerMigration: false, // no need
                holdFees: false, // no need
                preferClaimedTokenOverride: false, // no need
                useTotalOverflowForRedemptions: false, // no need
                useDataSourceForPay: false, // no data source needed
                useDataSourceForRedeem: false, // no data source needed
                dataSource: address(0), // no need
                metadata: 0 // no need
            }),
            0, // IMPORTANT. Start right away so that we can mint tokens and distribute funds immediately.
            _groupedSplits, // IMPORTANT. Set the splits.
            _fundAccessConstraints, // IMPORTANT. Set the fund access constraints.
            "Prepping lunch"
        );

        ///// 3. Mint tokens to this contract accoring to lpPercent.

        // The tokens to mint is a function of the current total supply and the multiplier.
        uint256 _tokensToMint = controller.tokenStore().totalSupplyOf(_projectId) * lpSupplyMultiplier;

        // Mint the tokens.
        controller.mintTokensOf({
            _projectId: _projectId,
            _tokenCount: _tokensToMint,
            _beneficiary: address(this),
            _memo: "Ingredients for lunch",
            _preferClaimedTokens: true, // Receive as ERC-20s.
            _useReservedRate: false
        });

        ///// 4. Distribute funds from project according to fund access constraints.

        _terminal.distributePayoutsOf({
            _projectId: _projectId,
            _amount: _projectBalance,
            _currency: _currency,
            _token: JBTokens.ETH,
            _minReturnedTokens: _projectBalance,
            _metadata: bytes("")
        });

        ///// 5. Do LP dance.

        // Wrap the ETH into WETH.
        weth.deposit{value: address(this).balance}();

        // Approve the position manage to move this contract's tokens.
        IERC20(_token).approve(address(positionManager), _tokensToMint);
        IERC20(weth).approve(address(positionManager), weth.balanceOf(address(this)));

        // Create the pool and get a reference to the LP position.
        (uint256 _lpId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(_token),
                token1: address(weth),
                fee: 10000, // 1%
                tickLower: -(887272 / 200) * 200, // max lower given 1% fee
                tickUpper: (887272 / 200) * 200, // max upper given 1% fee
                amount0Desired: _tokensToMint,
                amount1Desired: weth.balanceOf(address(this)),
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 1000 minutes
            })
        );
        // Save a reference to the LP position.
        lpIdOf[_projectId] = _lpId;

        // Mark the lunch as having been served.
        lunchHasBeenServedFor[_projectId] = true;

        emit LunchWasServed({
            projectId: _projectId,
            lpId: _lpId,
            projectBalance: _projectBalance,
            tokensToMint: _tokensToMint,
            sender: msg.sender
        });
    }

    // Collect ETH and token fees from the LP. Burn the tokens, and stick the ETH in the treasury to back the value of all remaining tokens.
    function sweepCrumbs(uint256 _projectId) external {
        // Keep a reference to the ID of the LP.
        uint256 _lpId = lpIdOf[_projectId];

        ///// 1. Collect the LP fees.

        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: _lpId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Unwind WETH to ETH.
        IWETH9(weth).withdraw(IERC20(weth).balanceOf(address(this)));

        ///// 2. Dump ETH in project.

        // Get the project's current ETH payment terminal.
        IJBPaymentTerminal _terminal = controller.directory().primaryTerminalOf(_projectId, JBTokens.ETH);

        uint256 _ethBalanceOf = address(this).balance;

        // Add the ETH to the project's balance.
        _terminal.addToBalanceOf{value: address(this).balance}({
            _projectId: _projectId,
            _amount: _ethBalanceOf,
            _token: JBTokens.ETH,
            _memo: "",
            _metadata: abi.encode(bytes32("1"))
        });

        ///// 3. Burn the tokens.

        uint256 _tokenBalanceOf = controller.tokenStore().balanceOf(address(this), _projectId);

        controller.burnTokensOf({
            _holder: address(this),
            _projectId: _projectId,
            _tokenCount: _tokenBalanceOf,
            _memo: "mmmmm, delicious",
            _preferClaimedTokens: true
        });

        emit CrumbsWereSwept({
            projectId: _projectId,
            lpId: _lpId,
            ethFeeAmount: _ethBalanceOf,
            tokenFeeAmount: _tokenBalanceOf,
            sender: msg.sender
        });
    }

    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data)
        external
        returns (bytes4)
    {
        _data;
        _from;
        _operator;

        // Make sure the 721 received is the JBProjects contract.
        if (msg.sender != address(controller.projects())) revert YUCK();

        // Allow lunch to be served.
        lunchCanBeServedFor[_tokenId] = true;

        emit BluntHasBeenPassed(_tokenId);

        return IERC721Receiver.onERC721Received.selector;
    }
}
