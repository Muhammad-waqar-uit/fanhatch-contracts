// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "./FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @title ClubKeyBase
/// @notice Reusable base that spins up one Linear ("Casual") club in setUp and exposes
///         `clubId` / `key`, so per-club suites can focus on behaviour rather than wiring.
contract ClubKeyBase is FansBase {
    uint256 public clubId;
    ClubKey public key;

    function setUp() public virtual override {
        super.setUp();
        (clubId, key) = _createClub(CurveType.Linear);
    }

    /// @dev Trivial sanity check so the file isn't empty: the free first key sets supply to 1.
    function test_baseSetUp() public view {
        assertEq(key.totalSupplyKeys(), 1);
        assertEq(key.balanceOf(creator), 1);
        assertEq(clubId, 1);
    }
}
