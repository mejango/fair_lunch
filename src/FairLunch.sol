// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@jbx-protocol/juice-contracts-v3/contracts/abstract/JBPayoutRedemptionPaymentTerminal3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBCurrencies.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBSplitsGroups.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/structs/JBSplit.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "prb-math/contracts/PRBMath.sol";

// copy from import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
library TickMath {
    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;
}

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

    event LunchWasServed(
        uint256 indexed projectId,
        uint256 indexed lpId,
        uint256 projectBalance,
        uint256 ethBalance,
        uint256 tokenBalance,
        address sender
    );
    event CrumbsWereSwept(
        uint256 indexed projectId, uint256 indexed lpId, uint256 ethFeeAmount, uint256 tokenFeeAmount, address sender
    );

    // A reference to the WETH contract
    IWETH9 internal _weth;

    // Who will receive a subset of ingredients before serving lunch.
    JBSplit[] internal _splits;

    // The address of the origin 'FairLunch', used to check in the init if the contract is the original or not.
    address public immutable codeOrigin;

    // How many multiples of the original total supply should be minted for the LP.
    uint256 public lpSupplyMultiplier;

    // Access to JB ecosystem.
    IJBController3_1 public controller;

    // Access to Uniswap LPs.
    INonfungiblePositionManager public positionManager;

    // The LP ID of a project who has had its lunch served.
    mapping(uint256 => uint256) public lpIdOf;

    // The percent of lunch, out of SPLITS_TOTAL_PERCENT, going to LPing.
    uint256 public lpPercent;

    /**
     * @notice
     * Get the splits.
     *
     * @return The splits the lunch will be distributed between.
     */
    function splits() external view returns (JBSplit[] memory) {
        return _splits;
    }

    // Set the boring stuff once.
    constructor(IJBController3_1 _controller, INonfungiblePositionManager _positionManager, IWETH9 __weth) {
        controller = _controller;
        positionManager = _positionManager;
        _weth = __weth;
        codeOrigin = address(this);
    }

    // How many tokens will make up the lunch? Who will the lunch be split between before LPing?
    // The amount of tokens minted into the LP is a function of this `_lpSupplyMultiplier'
    // multiplied by the total supply at the time of serving.
    function setTheTable(uint256 _lpSupplyMultiplier, JBSplit[] calldata __splits) public {
        // Make the original un-initializable.
        if (address(this) == codeOrigin) revert();

        // Stop re-initialization.
        if (address(controller) != address(0)) revert();

        if (_lpSupplyMultiplier <= 0) revert YUCK();

        lpSupplyMultiplier = _lpSupplyMultiplier;

        // Keep a reference to teh number of splits that are stored.
        uint256 _numberOfSplits = __splits.length;

        // Keep a reference to the split being iterated on.
        JBSplit memory _split;

        // Keep a reference to the percentage of payouts going to splits.
        uint256 _splitsPercent = JBConstants.SPLITS_TOTAL_PERCENT;

        for (uint256 _i; _i < _numberOfSplits;) {
            // Set the split being iterated on.
            _split = __splits[_i];

            // Increment the splits percent;
            _splitsPercent += _split.percent;

            // Make sure percents don't add up to more than 100%.
            if (_splitsPercent > JBConstants.SPLITS_TOTAL_PERCENT) revert YUCK();

            // Store the split.
            _splits[_i] = JBSplit({
                preferClaimed: _split.preferClaimed,
                preferAddToBalance: _split.preferAddToBalance,
                percent: _split.percent,
                projectId: _split.projectId,
                beneficiary: _split.beneficiary,
                lockedUntil: _split.lockedUntil,
                allocator: _split.allocator
            });

            unchecked {
                ++_i;
            }
        }

        // Store the percent going to LP.
        lpPercent = JBConstants.SPLITS_TOTAL_PERCENT - _splitsPercent;
    }

    // Serve lunch once the Blunt has been received.
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data)
        external
        returns (bytes4)
    {
        _data;
        _from;
        _operator;

        // Make sure the 721 received is the JBProjects contract.
        if (msg.sender != address(controller.projects())) revert YUCK();

        // Serve lunch.
        _serveLunch(_tokenId);

        return IERC721Receiver.onERC721Received.selector;
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
        IWETH9(_weth).withdraw(IERC20(_weth).balanceOf(address(this)));

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

    // mmmmm delicious.
    //
    // The lunch is serve once the blunt has been passed. Any lunch not portioned to a pre-programmed split will be pooled in an LP.
    function _serveLunch(uint256 _projectId) internal {
        // Keep a reference to the project's payment terminal, where its funds are stored.
        JBPayoutRedemptionPaymentTerminal3_1 _terminal = JBPayoutRedemptionPaymentTerminal3_1(
            address(controller.directory().primaryTerminalOf(_projectId, JBTokens.ETH))
        );

        // Keep a reference to the project's ETH balance.
        uint256 _projectBalance = _terminal.store().balanceOf(_terminal, _projectId);

        // Get a reference to the project's token.
        address _token = address(controller.tokenStore().tokenOf(_projectId));

        // Keep a reference to the expected currency.
        uint256 _currency = _terminal.currencyForToken(JBTokens.ETH);

        ///// 1. Schedule new funding cycle rules starting immediately that allows owner minting and distribution of all ETH in the project treasury to this contract.

        {
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

            // Keep a reference to teh number of splits that are stored.
            uint256 _numberOfSplits = _splits.length;

            // Keep a reference to the splits that will be configured. There will be one more split than the amount stored, the LP portion.
            JBSplit[] memory __splits = new JBSplit[](_numberOfSplits + 1);

            // Populate the values.
            for (uint256 _i; _i < _numberOfSplits;) {
                // Set the split in the array of splits.
                __splits[_i] = _splits[_i];
                unchecked {
                    ++_i;
                }
            }

            // Add a split routed to this contract that takes up any unused percents.
            __splits[_numberOfSplits] = JBSplit({
                preferClaimed: false,
                preferAddToBalance: false,
                percent: lpPercent,
                projectId: 0,
                beneficiary: payable(address(this)),
                lockedUntil: 0,
                allocator: IJBSplitAllocator(address(0))
            });

            // Package it up.
            JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1);
            _groupedSplits[0] = JBGroupedSplits({group: JBSplitsGroups.ETH_PAYOUT, splits: __splits});

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
        }

        ///// 2. Mint tokens to this contract accoring to lpPercent.

        // The tokens to mint is a function of the current total supply, the multiplier, and the percent of funds going to the LP.
        uint256 _tokensToMint = PRBMath.mulDiv(
            controller.tokenStore().totalSupplyOf(_projectId), lpPercent, JBConstants.SPLITS_TOTAL_PERCENT 
        ) * lpSupplyMultiplier;

        // Mint the tokens.
        controller.mintTokensOf({
            _projectId: _projectId,
            _tokenCount: _tokensToMint,
            _beneficiary: address(this),
            _memo: "Ingredients for lunch",
            _preferClaimedTokens: true, // Receive as ERC-20s.
            _useReservedRate: false
        });

        ///// 3. Distribute funds from project according to fund access constraints.

        _terminal.distributePayoutsOf({
            _projectId: _projectId,
            _amount: _projectBalance,
            _currency: _currency,
            _token: JBTokens.ETH,
            _minReturnedTokens: _projectBalance,
            _metadata: bytes("")
        });

        ///// 4. Do LP dance.

        uint256 _ethBalance = address(this).balance;

        // Wrap the ETH into WETH.
        _weth.deposit{value: _ethBalance}();

        // Approve the position manage to move this contract's tokens.
        IERC20(_token).approve(address(positionManager), _tokensToMint);
        IERC20(_weth).approve(address(positionManager), _weth.balanceOf(address(this)));

        // Create the pool and get a reference to the LP position.
        (uint256 _lpId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(_token),
                token1: address(_weth),
                fee: 10000, // 1%
                tickLower: TickMath.MIN_TICK, // max lower given 1% fee
                tickUpper: TickMath.MAX_TICK, // max upper given 1% fee
                amount0Desired: _tokensToMint,
                amount1Desired: _weth.balanceOf(address(this)),
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 1000 minutes
            })
        );
        // Save a reference to the LP position.
        lpIdOf[_projectId] = _lpId;

        emit LunchWasServed({
            projectId: _projectId,
            lpId: _lpId,
            projectBalance: _projectBalance,
            ethBalance: _ethBalance,
            tokenBalance: _tokensToMint,
            sender: msg.sender
        });
    }
}
