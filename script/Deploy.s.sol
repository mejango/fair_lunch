// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import "forge-std/Script.sol";
import "../src/FairLunchDeployer.sol";

contract DeployMainnet is Script {
    IJBDelegatesRegistry _delegatesRegistry =
      IJBDelegatesRegistry(0x7A53cAA1dC4d752CAD283d039501c0Ee45719FaC);
    function setUp() public {}

    function run() public {
        vm.broadcast();
    }
}

contract DeployGoerli is Script {
    uint256 _lpPercent = 50;
    INonfungiblePositionManager _positionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IJBDelegatesRegistry _delegatesRegistry =
      IJBDelegatesRegistry(0xCe3Ebe8A7339D1f7703bAF363d26cD2b15D23C23);
    IWETH9 _weth = IWETH9(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6);

    // V3_1 goerli controller.
    IJBController3_1 _controller = IJBController3_1(0x1d260DE91233e650F136Bf35f8A4ea1F2b68aDB6);

    function run() external {
        vm.startBroadcast();

        // Deploy the deployer with an original FairLunch instance.
        new FairLunchDeployer({
            _fairLunchOrigin: new FairLunch(
                _controller,
                _positionManager,
                _weth
            ),
            _delegatesRegistry: _delegatesRegistry
        });
    }
}
