// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveLibrary} from "../../src/libraries/CurveLibrary.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @dev External wrapper so library math can be exercised through real CALLs.
contract CurveMath {
    function cost(CurveType c, uint256 supply, uint256 amount) external pure returns (uint256) {
        return CurveLibrary.cost(c, supply, amount);
    }

    function proceeds(CurveType c, uint256 supply, uint256 amount) external pure returns (uint256) {
        return CurveLibrary.proceeds(c, supply, amount);
    }
}

contract CurveFuzz is FansBase {
    CurveMath internal math;

    function setUp() public override {
        super.setUp();
        math = new CurveMath();
        // Drop fees to zero so the curve math is the only economic effect.
        vm.prank(owner);
        fees.setFeeConfig(0, 7000);
    }

    /// @notice cost must be strictly increasing in amount (each extra key costs > 0).
    function testFuzz_CostStrictlyIncreasingInAmount(uint256 supply, uint256 amount) public view {
        supply = bound(supply, 0, 1000);
        amount = bound(amount, 1, 500);

        uint256 cLess = math.cost(CurveType.Linear, supply, amount);
        uint256 cMore = math.cost(CurveType.Linear, supply, amount + 1);
        assertGt(cMore, cLess, "cost must strictly increase with amount");

        uint256 eLess = math.cost(CurveType.Exponential, supply, amount);
        uint256 eMore = math.cost(CurveType.Exponential, supply, amount + 1);
        assertGt(eMore, eLess, "exp cost must strictly increase with amount");
    }

    /// @notice Selling out of a higher supply pays no more than it cost to buy into it.
    ///         proceeds(supply, amount) <= cost(supply - amount, amount): the integral over a
    ///         lower window is never larger than over the higher window it was bought at.
    function testFuzz_ProceedsNeverExceedMatchingCost(uint256 supply, uint256 amount) public view {
        amount = bound(amount, 1, 500);
        supply = bound(supply, amount, 1000); // ensure supply >= amount

        // Symmetry: selling `amount` from `supply` == cost of buying `amount` from `supply - amount`.
        assertEq(
            math.proceeds(CurveType.Linear, supply, amount),
            math.cost(CurveType.Linear, supply - amount, amount),
            "linear proceeds == matching cost"
        );
        // And it never exceeds the cost of buying that same amount from the *current* supply.
        assertLe(
            math.proceeds(CurveType.Linear, supply, amount),
            math.cost(CurveType.Linear, supply, amount),
            "proceeds <= forward cost"
        );

        assertEq(
            math.proceeds(CurveType.Exponential, supply, amount),
            math.cost(CurveType.Exponential, supply - amount, amount),
            "exp proceeds == matching cost"
        );
        assertLe(
            math.proceeds(CurveType.Exponential, supply, amount),
            math.cost(CurveType.Exponential, supply, amount),
            "exp proceeds <= forward cost"
        );
    }

    /// @notice No free money: buying then immediately selling the same amount through a real
    ///         ClubKey never returns MORE $FANS than was spent (with fees at zero, it is exactly equal).
    function testFuzz_BuyThenSellNoFreeMoney(uint256 supply, uint256 amount) public {
        supply = bound(supply, 0, 1000);
        amount = bound(amount, 1, 500);

        (, ClubKey key) = _createClub(CurveType.Linear);

        // Pre-seed supply so the round trip starts from a non-trivial point.
        if (supply > 0) {
            _buy(key, bob, supply);
        }

        uint256 balBefore = fans.balanceOf(alice);

        // Buy then sell the same amount as alice.
        vm.startPrank(alice);
        fans.approve(address(key), type(uint256).max);
        key.buyKeys(amount, type(uint256).max);
        key.sellKeys(amount, 0);
        vm.stopPrank();

        uint256 balAfter = fans.balanceOf(alice);
        assertLe(balAfter, balBefore, "round trip must never mint free $FANS");
        // With fees disabled the curve is perfectly symmetric.
        assertEq(balAfter, balBefore, "fee-free round trip is exactly break-even");
    }
}
