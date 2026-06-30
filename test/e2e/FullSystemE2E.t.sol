// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @title FullSystemE2E
/// @notice One end-to-end story exercising the whole Fans.tech spec: club creation with a free
///         first key, buys that push the price up, fee accrual to treasury + farmers, gifting,
///         keyholder voting that elects a president, moderator management, selling at a lower
///         price, and finally the owner claiming accrued farmer rewards. State is asserted at
///         every major step so a regression anywhere in the pipeline trips a clear failure.
contract FullSystemE2E is FansBase {
    address charlie = makeAddr("charlie");

    function test_fullLifecycle() public {
        // --- 1. Creator makes a club; first key is minted free to the creator (spec §1.3). ---
        (uint256 clubId, ClubKey key) = _createClub(CurveType.Linear);
        assertEq(clubId, 1, "first club id");
        assertEq(key.creator(), creator, "creator recorded");
        assertEq(key.totalSupplyKeys(), 1, "free first key minted");
        assertEq(key.balanceOf(creator), 1, "creator holds free key");
        assertEq(uint256(key.curveType()), uint256(CurveType.Linear), "curve type");

        // --- 2. Alice & bob buy keys; price must strictly rise as supply grows. ---
        uint256 priceAtSupply1 = key.buyPrice(1);
        _buy(key, alice, 5); // supply 1 -> 6, alice holds 5
        uint256 priceAtSupply6 = key.buyPrice(1);
        _buy(key, bob, 3); // supply 6 -> 9, bob holds 3
        uint256 priceAtSupply9 = key.buyPrice(1);

        assertGt(priceAtSupply6, priceAtSupply1, "price rises after alice buys");
        assertGt(priceAtSupply9, priceAtSupply6, "price rises after bob buys");
        assertEq(key.totalSupplyKeys(), 9, "supply after buys");
        assertEq(key.balanceOf(alice), 5, "alice keys");
        assertEq(key.balanceOf(bob), 3, "bob keys");

        // The curve reserve held by the ClubKey equals exactly what buyers paid (excl. fees).
        // First key was free, so the reserve = cost of keys minted at supply 1..8.
        assertEq(fans.balanceOf(address(key)), key.sellPrice(8), "reserve == cost paid in");

        // --- 3. Fees accrued: split between treasury (70%) and farmer rewards (30%). ---
        uint256 treasuryBal = fans.balanceOf(treasury);
        uint256 farmerBal = fees.farmerRewards();
        assertGt(treasuryBal, 0, "treasury received fees");
        assertGt(farmerBal, 0, "farmer rewards accrued");
        // Treasury share should dominate the farmer share at the default 70/30 split.
        assertGt(treasuryBal, farmerBal, "treasury share > farmer share");

        // --- 4. Alice gifts one key to charlie: free transfer, supply unchanged (spec §1.7). ---
        vm.prank(alice);
        key.gift(charlie, 1);
        assertEq(key.balanceOf(alice), 4, "alice gave away a key");
        assertEq(key.balanceOf(charlie), 1, "charlie received a gift");
        assertEq(key.totalSupplyKeys(), 9, "gifting does not change supply");

        // --- 5. Bob & alice vote for a president; combined weight clears a simple majority. ---
        // Supply is 9, so a candidate needs tally*2 > 9 (i.e. >= 5 weight) to be elected.
        // Alice alone (4) is not enough; once bob (3) adds his weight, creator is elected.
        vm.prank(alice);
        gov.voteForPresident(clubId, creator);
        assertEq(gov.presidentOf(clubId), address(0), "no majority from alice alone");

        vm.prank(bob);
        gov.voteForPresident(clubId, creator);
        assertEq(gov.votesFor(clubId, creator), 7, "combined tally");
        assertEq(gov.presidentOf(clubId), creator, "majority elects creator president");

        // --- 6. President sets a moderator (spec §1.6). ---
        vm.prank(creator);
        gov.setModerator(clubId, bob, true);
        assertTrue(gov.isModerator(clubId, bob), "bob is moderator");
        // A non-president cannot manage moderators.
        vm.prank(alice);
        vm.expectRevert();
        gov.setModerator(clubId, charlie, true);

        // --- 7. Alice sells keys: price falls and she receives gross proceeds minus the fee. ---
        uint256 sellPriceBefore = key.sellPrice(1); // spot at supply 9
        uint256 gross = key.sellPrice(2); // proceeds for selling 2 from supply 9
        uint256 fee = (gross * fees.feeBps()) / 10_000;
        uint256 expectedPayout = gross - fee;

        uint256 aliceFansBefore = fans.balanceOf(alice);
        uint256 treasuryBeforeSell = fans.balanceOf(treasury);
        uint256 farmerBeforeSell = fees.farmerRewards();

        vm.prank(alice);
        key.sellKeys(2, 0);

        uint256 sellPriceAfter = key.sellPrice(1); // spot at supply 7
        assertLt(sellPriceAfter, sellPriceBefore, "price falls after sell");
        assertEq(key.totalSupplyKeys(), 7, "supply after sell");
        assertEq(key.balanceOf(alice), 2, "alice keys after sell");
        assertEq(fans.balanceOf(alice) - aliceFansBefore, expectedPayout, "alice paid proceeds - fee");

        // The sell fee is routed through the distributor just like a buy.
        uint256 treasuryDelta = fans.balanceOf(treasury) - treasuryBeforeSell;
        uint256 farmerDelta = fees.farmerRewards() - farmerBeforeSell;
        assertEq(treasuryDelta + farmerDelta, fee, "sell fee fully routed");

        // --- 8. Owner claims accrued farmer rewards to a payout address. ---
        address farmPayout = makeAddr("farmPayout");
        uint256 pending = fees.farmerRewards();
        assertGt(pending, 0, "there are rewards to claim");

        vm.prank(owner);
        fees.claimFarmerRewards(farmPayout);

        assertEq(fees.farmerRewards(), 0, "rewards zeroed after claim");
        assertEq(fans.balanceOf(farmPayout), pending, "payout received full pending amount");
    }
}
