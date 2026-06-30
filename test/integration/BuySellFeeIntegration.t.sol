// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @title BuySellFeeIntegration
/// @notice Cross-contract fee routing: for a series of buys and sells, the fee charged by the
///         ClubKey must land entirely in the FeeDistributor split (treasury delta + farmerRewards
///         delta == total fees), and the ClubKey's own $FANS reserve must equal exactly the net
///         curve cost it retained (buys in minus gross proceeds out). Verified on both the Linear
///         ("Casual") and Exponential ("Exclusive") curves.
contract BuySellFeeIntegration is FansBase {
    // Running totals over the whole sequence.
    uint256 internal totalFeesCharged;
    uint256 internal expectedReserve;

    function setUp() public override {
        super.setUp();
        totalFeesCharged = 0;
        expectedReserve = 0;
    }

    function test_feeRouting_linear() public {
        _runSequence(CurveType.Linear);
    }

    function test_feeRouting_exponential() public {
        _runSequence(CurveType.Exponential);
    }

    /// @dev A representative mix of buys and sells across multiple actors, with per-step
    ///      accounting assertions plus an end-of-run reconciliation.
    function _runSequence(CurveType curveType) internal {
        totalFeesCharged = 0;
        expectedReserve = 0; // ClubKey starts with a free first key and zero reserve.
        (, ClubKey key) = _createClub(curveType);
        assertEq(fans.balanceOf(address(key)), 0, "fresh club holds no reserve");

        uint256 treasuryStart = fans.balanceOf(treasury);
        uint256 farmerStart = fees.farmerRewards();

        _buyAndCheck(key, alice, 10);
        _buyAndCheck(key, bob, 5);
        _sellAndCheck(key, alice, 4);
        _buyAndCheck(key, bob, 7);
        _sellAndCheck(key, bob, 6);
        _buyAndCheck(key, alice, 3);
        _sellAndCheck(key, alice, 2);

        // End-of-run reconciliation across the three contracts.
        uint256 treasuryDelta = fans.balanceOf(treasury) - treasuryStart;
        uint256 farmerDelta = fees.farmerRewards() - farmerStart;
        assertEq(treasuryDelta + farmerDelta, totalFeesCharged, "all fees routed to the distributor split");
        assertEq(fans.balanceOf(address(key)), expectedReserve, "ClubKey reserve == net curve cost retained");
        // Sanity: a non-trivial amount of fees actually flowed.
        assertGt(totalFeesCharged, 0, "fees were charged");
    }

    function _buyAndCheck(ClubKey key, address who, uint256 amount) internal {
        uint256 cost = key.buyPrice(amount);
        uint256 fee = (cost * fees.feeBps()) / 10_000;
        uint256 toTreasury = (fee * fees.treasuryShareBps()) / 10_000;
        uint256 toFarmers = fee - toTreasury;

        uint256 treasuryBefore = fans.balanceOf(treasury);
        uint256 farmerBefore = fees.farmerRewards();
        uint256 reserveBefore = fans.balanceOf(address(key));

        _buy(key, who, amount);

        assertEq(fans.balanceOf(treasury) - treasuryBefore, toTreasury, "buy: treasury share");
        assertEq(fees.farmerRewards() - farmerBefore, toFarmers, "buy: farmer share");
        assertEq(
            (fans.balanceOf(treasury) - treasuryBefore) + (fees.farmerRewards() - farmerBefore),
            fee,
            "buy: treasury + farmer delta == fee"
        );
        // The cost (excl. fee) is retained by the ClubKey as curve reserve.
        assertEq(fans.balanceOf(address(key)) - reserveBefore, cost, "buy: reserve grows by net cost");

        totalFeesCharged += fee;
        expectedReserve += cost;
    }

    function _sellAndCheck(ClubKey key, address who, uint256 amount) internal {
        uint256 gross = key.sellPrice(amount);
        uint256 fee = (gross * fees.feeBps()) / 10_000;
        uint256 payout = gross - fee;
        uint256 toTreasury = (fee * fees.treasuryShareBps()) / 10_000;
        uint256 toFarmers = fee - toTreasury;

        uint256 treasuryBefore = fans.balanceOf(treasury);
        uint256 farmerBefore = fees.farmerRewards();
        uint256 reserveBefore = fans.balanceOf(address(key));
        uint256 sellerBefore = fans.balanceOf(who);

        vm.prank(who);
        key.sellKeys(amount, 0);

        assertEq(fans.balanceOf(who) - sellerBefore, payout, "sell: seller receives gross - fee");
        assertEq(fans.balanceOf(treasury) - treasuryBefore, toTreasury, "sell: treasury share");
        assertEq(fees.farmerRewards() - farmerBefore, toFarmers, "sell: farmer share");
        assertEq(
            (fans.balanceOf(treasury) - treasuryBefore) + (fees.farmerRewards() - farmerBefore),
            fee,
            "sell: treasury + farmer delta == fee"
        );
        // The reserve shrinks by the gross proceeds (payout to seller + fee to distributor).
        assertEq(reserveBefore - fans.balanceOf(address(key)), gross, "sell: reserve shrinks by gross");

        totalFeesCharged += fee;
        expectedReserve -= gross;
    }
}
