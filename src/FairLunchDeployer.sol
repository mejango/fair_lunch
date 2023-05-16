// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/proxy/Clones.sol";
import '@jbx-protocol/juice-delegates-registry/src/interfaces/IJBDelegatesRegistry.sol';
import "./FairLunch.sol";

contract FairLunchDeployer {
    // The current nonce counting lunches served, used for the registry
    uint256 private _nonce;

    // The FairLunch code origin.
    FairLunch public immutable fairLunchOrigin;

    // A regitry to keep track of all fair lunches.
    IJBDelegatesRegistry public immutable delegatesRegistry;

    constructor(FairLunch _fairLunchOrigin, IJBDelegatesRegistry _delegatesRegistry) {
        fairLunchOrigin = _fairLunchOrigin;
        delegatesRegistry = _delegatesRegistry;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    // A fair lunch for all.
    function offerFairLunch(uint256 _lpSupplyMultiplier, JBSplit[] memory _splits)
        external
        returns (FairLunch _fairLunch)
    {
        _fairLunch = FairLunch(Clones.clone(address(fairLunchOrigin)));
        _fairLunch.setTheTable(_lpSupplyMultiplier, _splits);

        // Add the delegate to the registry, contract nonce starts at 1
        delegatesRegistry.addDelegate(address(this), ++_nonce);
    }
}
