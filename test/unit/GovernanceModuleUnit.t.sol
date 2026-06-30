// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {GovernanceModule} from "../../src/governance/GovernanceModule.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @title GovernanceModuleUnit
/// @notice Unit tests for keyholder voting + moderator management (spec §1.6).
contract GovernanceModuleUnit is FansBase {
    // Mirror of GovernanceModule events for expectEmit.
    event Voted(uint256 indexed clubId, address indexed voter, address indexed candidate, uint256 weight);
    event PresidentChanged(uint256 indexed clubId, address newPresident);
    event ModeratorSet(uint256 indexed clubId, address moderator, bool enabled);

    uint256 internal clubId;
    ClubKey internal key;

    function setUp() public override {
        super.setUp();
        (clubId, key) = _createClub(CurveType.Linear);
    }

    /// voteForPresident counts the voter's current key balance as weight and emits Voted.
    function test_voteTalliesWeightAndEmitsVoted() public {
        // alice: 3 keys, bob: 4 keys. supply = 1 (creator) + 3 + 4 = 8 → no majority for alice.
        _buy(key, alice, 3);
        _buy(key, bob, 4);
        assertEq(key.balanceOf(alice), 3);

        vm.expectEmit(true, true, true, true);
        emit Voted(clubId, alice, creator, 3);
        vm.prank(alice);
        gov.voteForPresident(clubId, creator);

        assertEq(gov.votesFor(clubId, creator), 3, "tally == keys held");
        assertEq(gov.presidentOf(clubId), address(0), "no majority yet");
    }

    /// A candidate becomes president once tally*2 > supply; PresidentChanged fires and presidentOf updates.
    function test_majorityElectsPresident() public {
        // alice: 10 keys, bob: 2 keys. supply = 13. alice weight 10 → 20 > 13 majority.
        _buy(key, alice, 10);
        _buy(key, bob, 2);

        vm.expectEmit(true, false, false, true);
        emit PresidentChanged(clubId, bob);
        vm.prank(alice);
        gov.voteForPresident(clubId, bob); // alice elects bob

        assertEq(gov.presidentOf(clubId), bob, "bob is president");
        assertEq(gov.votesFor(clubId, bob), 10);
    }

    /// Changing a vote moves the voter's weight off the old candidate onto the new one.
    function test_changingVoteMovesWeight() public {
        // alice: 3, bob: 4 → supply 8, no majority so president stays unset (isolates bookkeeping).
        _buy(key, alice, 3);
        _buy(key, bob, 4);

        vm.prank(alice);
        gov.voteForPresident(clubId, creator);
        assertEq(gov.votesFor(clubId, creator), 3);

        vm.prank(alice);
        gov.voteForPresident(clubId, bob);
        assertEq(gov.votesFor(clubId, creator), 0, "weight removed from old candidate");
        assertEq(gov.votesFor(clubId, bob), 3, "weight moved to new candidate");
        assertEq(gov.presidentOf(clubId), address(0), "still no majority");
    }

    /// voteForPresident reverts UnknownClub for a clubId that was never created.
    function test_voteRevertsUnknownClub() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceModule.UnknownClub.selector);
        gov.voteForPresident(999, creator);
    }

    /// setModerator is president-only; isModerator reflects the toggle.
    function test_setModeratorOnlyPresident() public {
        // Elect creator president: alice buys 10 → supply 11, weight 10 → 20 > 11.
        _buy(key, alice, 10);
        vm.prank(alice);
        gov.voteForPresident(clubId, creator);
        assertEq(gov.presidentOf(clubId), creator);

        // Non-president cannot set a moderator.
        vm.prank(alice);
        vm.expectRevert(GovernanceModule.NotPresident.selector);
        gov.setModerator(clubId, bob, true);

        // President can.
        vm.expectEmit(false, false, false, true);
        emit ModeratorSet(clubId, bob, true);
        vm.prank(creator);
        gov.setModerator(clubId, bob, true);
        assertTrue(gov.isModerator(clubId, bob));

        // And can clear it.
        vm.prank(creator);
        gov.setModerator(clubId, bob, false);
        assertFalse(gov.isModerator(clubId, bob));
    }
}
