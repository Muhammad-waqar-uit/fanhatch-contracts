// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurveLibrary} from "../../src/libraries/CurveLibrary.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @dev Thin external wrapper so the `internal` library functions can be called
///      through real CALLs (needed for `vm.expectRevert`) and asserted on.
contract CurveWrapper {
    function price(CurveType c, uint256 n) external pure returns (uint256) {
        return CurveLibrary.price(c, n);
    }

    function cost(CurveType c, uint256 supply, uint256 amount) external pure returns (uint256) {
        return CurveLibrary.cost(c, supply, amount);
    }

    function proceeds(CurveType c, uint256 supply, uint256 amount) external pure returns (uint256) {
        return CurveLibrary.proceeds(c, supply, amount);
    }

    function rpow(uint256 x, uint256 n) external pure returns (uint256) {
        return CurveLibrary.rpow(x, n);
    }
}

contract CurveLibraryUnit is Test {
    // Known constants (mirrored from CurveLibrary for exact-value assertions).
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BASE_PRICE = 1e16;
    uint256 internal constant LINEAR_SLOPE = 1e15;
    uint256 internal constant MAX_SUPPLY = 5000;

    CurveWrapper internal w;

    function setUp() public {
        w = new CurveWrapper();
    }

    // --- price (Linear) ---

    function test_PriceLinearExact() public view {
        assertEq(w.price(CurveType.Linear, 0), BASE_PRICE);
        assertEq(w.price(CurveType.Linear, 1), BASE_PRICE + LINEAR_SLOPE);
        for (uint256 n = 0; n <= 100; n++) {
            assertEq(w.price(CurveType.Linear, n), BASE_PRICE + LINEAR_SLOPE * n, "price(Linear,n)");
        }
    }

    // --- cost (Linear) exact closed form ---

    function _expectedLinearCost(uint256 supply, uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 indexSum = amount * supply + (amount * (amount - 1)) / 2;
        return amount * BASE_PRICE + LINEAR_SLOPE * indexSum;
    }

    function test_CostLinearExact() public view {
        uint256[4] memory supplies = [uint256(0), 1, 10, 250];
        uint256[4] memory amounts = [uint256(1), 5, 33, 100];
        for (uint256 i = 0; i < supplies.length; i++) {
            for (uint256 j = 0; j < amounts.length; j++) {
                uint256 s = supplies[i];
                uint256 a = amounts[j];
                assertEq(w.cost(CurveType.Linear, s, a), _expectedLinearCost(s, a), "cost(Linear)");
            }
        }
    }

    // --- cost with zero amount ---

    function test_CostZeroAmountIsZero() public view {
        assertEq(w.cost(CurveType.Linear, 0, 0), 0);
        assertEq(w.cost(CurveType.Linear, 123, 0), 0);
        assertEq(w.cost(CurveType.Exponential, 0, 0), 0);
        assertEq(w.cost(CurveType.Exponential, 4999, 0), 0); // even at/above cap, amount==0 short-circuits
        assertEq(w.proceeds(CurveType.Linear, 10, 0), 0);
        assertEq(w.proceeds(CurveType.Exponential, 10, 0), 0);
    }

    // --- round-trip symmetry: cost(s,a) == proceeds(s+a, a) ---

    function test_RoundTripSymmetryLinear() public view {
        uint256[5] memory supplies = [uint256(0), 1, 7, 100, 1000];
        uint256[4] memory amounts = [uint256(1), 3, 50, 200];
        for (uint256 i = 0; i < supplies.length; i++) {
            for (uint256 j = 0; j < amounts.length; j++) {
                uint256 s = supplies[i];
                uint256 a = amounts[j];
                assertEq(
                    w.cost(CurveType.Linear, s, a),
                    w.proceeds(CurveType.Linear, s + a, a),
                    "linear symmetry"
                );
            }
        }
    }

    function test_RoundTripSymmetryExponential() public view {
        uint256[5] memory supplies = [uint256(0), 1, 7, 100, 1000];
        uint256[4] memory amounts = [uint256(1), 3, 50, 200];
        for (uint256 i = 0; i < supplies.length; i++) {
            for (uint256 j = 0; j < amounts.length; j++) {
                uint256 s = supplies[i];
                uint256 a = amounts[j];
                assertEq(
                    w.cost(CurveType.Exponential, s, a),
                    w.proceeds(CurveType.Exponential, s + a, a),
                    "exp symmetry"
                );
            }
        }
    }

    // --- exponential cost monotonically increasing in amount ---

    function test_ExponentialCostMonotonicInAmount() public view {
        uint256 supply = 50;
        uint256 prev = w.cost(CurveType.Exponential, supply, 1);
        for (uint256 a = 2; a <= 200; a++) {
            uint256 cur = w.cost(CurveType.Exponential, supply, a);
            assertGt(cur, prev, "exp cost must strictly increase with amount");
            prev = cur;
        }
    }

    function test_ExponentialPriceMonotonicInSupply() public view {
        uint256 prev = w.price(CurveType.Exponential, 0);
        for (uint256 n = 1; n <= 200; n++) {
            uint256 cur = w.price(CurveType.Exponential, n);
            assertGt(cur, prev, "exp price must strictly increase with supply");
            prev = cur;
        }
    }

    // --- supply cap ---

    function test_SupplyCapExceededReverts_Linear() public {
        // 4999 + 1 == 5000 == MAX_SUPPLY: allowed (not strictly greater).
        w.cost(CurveType.Linear, MAX_SUPPLY - 1, 1);

        vm.expectRevert(CurveLibrary.SupplyCapExceeded.selector);
        w.cost(CurveType.Linear, MAX_SUPPLY, 1); // 5001 > 5000

        vm.expectRevert(CurveLibrary.SupplyCapExceeded.selector);
        w.cost(CurveType.Linear, MAX_SUPPLY - 1, 2); // 5001 > 5000
    }

    function test_SupplyCapExceededReverts_Exponential() public {
        w.cost(CurveType.Exponential, MAX_SUPPLY - 1, 1);

        vm.expectRevert(CurveLibrary.SupplyCapExceeded.selector);
        w.cost(CurveType.Exponential, MAX_SUPPLY, 1);

        vm.expectRevert(CurveLibrary.SupplyCapExceeded.selector);
        w.cost(CurveType.Exponential, 3000, 2001);
    }

    // --- rpow ---

    function test_RpowOfWadIsWad() public view {
        for (uint256 n = 0; n <= 256; n++) {
            assertEq(w.rpow(WAD, n), WAD, "rpow(WAD,n) == WAD");
        }
    }

    function test_RpowToZeroIsWad() public view {
        assertEq(w.rpow(0, 0), WAD);
        assertEq(w.rpow(WAD, 0), WAD);
        assertEq(w.rpow(1.008e18, 0), WAD);
        assertEq(w.rpow(2e18, 0), WAD);
        assertEq(w.rpow(type(uint128).max, 0), WAD);
    }
}
