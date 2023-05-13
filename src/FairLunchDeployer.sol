// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./FairLunch.sol";

contract FairLunchDeployer {
    // The FairLunch code origin.
    FairLunch public immutable fairLunchOrigin;

    constructor(FairLunch _fairLunchOrigin) {
        fairLunchOrigin = _fairLunchOrigin;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    // A fair lunch for all.
    function offerFairLunch(uint256 _lpSupplyMultiplier, JBSplit[] memory _splits) external returns (FairLunch _fairLunch) {
        _fairLunch = FairLunch(Clones.clone(address(fairLunchOrigin)));
        _fairLunch.setTheTable(_lpSupplyMultiplier, _splits);
    }
}
