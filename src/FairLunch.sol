// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@jbx-protocol/juice-contracts-v3/contracts/abstract/JBPayoutRedemptionPaymentTerminal3_1.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBCurrencies.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBSplitsGroups.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol';
import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';

// copy from import '@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol';
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// mmmmmmm, delicious.
contract FairLunch is IERC721Receiver {
  error YUCK();
  error LUNCH_ALREADY_SERVED();
  error LUNCH_CANT_BE_SERVED_YET();

  uint256 constant TOTAL_PERCENT = 100;
  mapping(uint256 => bool) lunchHasBeenServedFor;
  mapping(uint256 => bool) lunchCanBeServedFor;
  uint256 lpSupplyMultiplier;
  IJBController3_1 private controller;
  INonfungiblePositionManager private positionManager;
  string symbol;
  string name;
  IWETH9 weth;
  mapping(uint256 => uint256) lpIdOf;
  uint256 serverRefund;

  // _lpPercent is out of 100. The percent of currently outstanding tokens that should be minted for LPing.
  constructor(
    uint256 _lpSupplyMultiplier,
    string memory _symbol,
    string memory _name,
    IJBController3_1 _controller,
    INonfungiblePositionManager _positionManager,
    IWETH9 _weth,
    uint256 _serverRefund
  ) {
    if (_lpSupplyMultiplier == 0) revert YUCK();
    lpSupplyMultiplier = _lpSupplyMultiplier;
    symbol = _symbol;
    name = _name;
    controller = _controller;
    positionManager = _positionManager;
    weth = _weth;
    serverRefund = _serverRefund;
  }

  // mmmmm delicious.
  function serveLunch(uint256 _projectId) external {
    // Make sure lunch hasn't yet been served.
    if (lunchHasBeenServedFor[_projectId]) revert LUNCH_ALREADY_SERVED();

    // Make sure lunch is servable.
    if (!lunchCanBeServedFor[_projectId]) revert LUNCH_CANT_BE_SERVED_YET();

    // Keep a reference to the project's payment terminal.
    JBPayoutRedemptionPaymentTerminal3_1 _terminal = JBPayoutRedemptionPaymentTerminal3_1(address(controller.directory().primaryTerminalOf(_projectId, JBTokens.ETH)));
    // Keep a reference to the project's ETH balance.
    uint256 _projectBalance =  _terminal.store().balanceOf(_terminal, _projectId);

    // 1. Create ERC-20 for the project.
    IERC20 _token = IERC20(address(controller.tokenStore().issueFor(_projectId, name, symbol)));

    // 2. Schedules a funding cycle starting immediately that allows owner minting and distribution of all ETH in the project treasury to this contract.
    // Set fund access constraints to make all funds distributable.
    JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
    uint256 _currency = _terminal.currencyForToken(JBTokens.ETH);
    _fundAccessConstraints[0] = JBFundAccessConstraints({
      terminal: _terminal,
      token: JBTokens.ETH,
      distributionLimit: _projectBalance,
      distributionLimitCurrency: _currency,
      overflowAllowance: 0,
      overflowAllowanceCurrency: 0
    });
    // Add a 100% split to this contract.
    JBSplit memory _split =  JBSplit({
      preferClaimed: false,
      preferAddToBalance: false,
      percent: JBConstants.SPLITS_TOTAL_PERCENT,
      projectId: 0,
      beneficiary: payable(address(this)),
      lockedUntil: 0,
      allocator: IJBSplitAllocator(address(0))
    });
    // Make a group split for ETH payouts.
    JBSplit[] memory _splits = new JBSplit[](1);
    _splits[0] = _split;
    JBGroupedSplits[] memory _groupedSplits = new JBGroupedSplits[](1);
    _groupedSplits[0] = JBGroupedSplits({group: JBSplitsGroups.ETH_PAYOUT, splits: _splits});
    
    // Set the new rules.
    controller.reconfigureFundingCyclesOf(
        _projectId,
        JBFundingCycleData ({
          duration: 0, // doesn't matter since no other reconfigurations are possible.
          weight: 0, // doesn't matter since payments are paused.
          discountRate: 0, // doesnt matter.
          ballot: IJBFundingCycleBallot(address(0))
        }),
        JBFundingCycleMetadata({
         global: JBGlobalFundingCycleMetadata({
            allowSetTerminals: false,
            allowSetController: false,
            pauseTransfers: false
          }),
          reservedRate: 0,
          redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
          ballotRedemptionRate: JBConstants.MAX_REDEMPTION_RATE,
          // IMPORTANT. No more payments.
          pausePay: true,
          pauseDistributions: false,
          pauseRedeem: false,
          pauseBurn: false,
          // IMPORTANT. We must allow the project's owner (this contract) to be able to mint new tokens on demand.
          allowMinting: true,
          allowTerminalMigration: false,
          allowControllerMigration: false,
          holdFees: false,
          preferClaimedTokenOverride: false,
          useTotalOverflowForRedemptions: false,
          useDataSourceForPay: false,
          useDataSourceForRedeem: false,
          dataSource: address(0),
          metadata: 0
        }),
        // IMPORTANT. Start right away so that we can mint tokens and distribute funds immediately.
        0,
        // IMPORTANT. Set the splits.
        _groupedSplits,
        // IMPORTANT. Set the fund access constraints.
        _fundAccessConstraints,
        'Prepping lunch'
      );

    // 3. Mint tokens to this contract accoring to lpPercent.
    uint256 _tokensToMint = controller.tokenStore().totalSupplyOf(_projectId) * lpSupplyMultiplier;
    controller.mintTokensOf(
      _projectId,
      _tokensToMint,
      address(this),
      "Ingredients for lunch",
      true, // Receive as ERC-20s.
      false // Don't use reserved rate.
    );

    // 4. Distribute funds from project according to fund access constraints.
    _terminal.distributePayoutsOf(
      _projectId,
      _projectBalance,
      _currency,
      JBTokens.ETH,
      _projectBalance,
      bytes("")
    );

    // 5. Do LP dance.

    // Wrap it into WETH.
    weth.deposit{value: address(this).balance - serverRefund }();
    // Approve the position manage to move this contract's tokens.
    IERC20(_token).approve(address(positionManager), _tokensToMint);
    IERC20(weth).approve(address(positionManager), weth.balanceOf(address(this)));

    // Create the pool and get a reference to the LP position.
    (uint256 _lpId, , , ) = positionManager.mint(
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

     // 6. Refund whoever served the lunch. 
    Address.sendValue(payable(tx.origin), serverRefund);
  }

  function sweepCrumbs(uint256 _projectId) external {
    // 1. Collect the fees
    positionManager.collect(
        INonfungiblePositionManager.CollectParams({
            tokenId: lpIdOf[_projectId],
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        })
    );

    // Unwind WETH to ETH.
    IWETH9(weth).withdraw(IERC20(weth).balanceOf(address(this)));

    // 2. Dump ETH in project.
    IJBPaymentTerminal _terminal = controller.directory().primaryTerminalOf(_projectId, JBTokens.ETH);
    // Dump in project.
    _terminal.addToBalanceOf{value: address(this).balance}(
        _projectId,
        address(this).balance,
        JBTokens.ETH,
        "",
        abi.encode(bytes32("1"))
    );

    // 3. Burn tokens.
    controller.burnTokensOf(
    address(this),
     _projectId,
     controller.tokenStore().balanceOf(address(this), _projectId),
     "mmmmm, delicious",
     true
    );

    lunchHasBeenServedFor[_projectId] = true;
  }

  function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes calldata _data
    ) external returns (bytes4) {
      _data;
      _from;
      _operator;

      // Make sure the 721 received is a JBProject.
      if (msg.sender != address(controller.projects())) revert YUCK();

      // Allow lunch to be served.
      lunchCanBeServedFor[_tokenId] = true;

      return IERC721Receiver.onERC721Received.selector;
    }
}
