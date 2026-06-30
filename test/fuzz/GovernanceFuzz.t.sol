// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @title GovernanceFuzz
/// @notice Fuzzes vote weight against live key balances and the majority threshold.
contract GovernanceFuzz is FansBase {
    uint256 internal clubId;
    ClubKey internal key;

    function setUp() public override {
        super.setUp();
        (clubId, key) = _createClub(CurveType.Linear);
    }

    /// For any bounded number of keys alice buys, her vote tally equals her current balance,
    /// and the candidate is elected president exactly when a simple majority is crossed.
    function testFuzz_voteWeightEqualsBalance(uint256 amount) public {
        // Bounded well under the 5000 supply cap; creator already holds 1 key.
        amount = bound(amount, 1, 1_000);
        _buy(key, alice, amount);
        assertEq(key.balanceOf(alice), amount, "alice holds what she bought");

        vm.prank(alice);
        gov.voteForPresident(clubId, bob);

        // Tally always equals her current key balance read at vote time.
        assertEq(gov.votesFor(clubId, bob), amount);

        uint256 supply = key.totalSupplyKeys(); // 1 + amount
        bool majority = amount * 2 > supply;
        if (majority) {
            assertEq(gov.presidentOf(clubId), bob, "elected on majority");
        } else {
            assertEq(gov.presidentOf(clubId), address(0), "not elected without majority");
        }
    }
}
