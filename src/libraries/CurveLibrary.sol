// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveType} from "../interfaces/IFansInterfaces.sol";

/// @title CurveLibrary
/// @notice Fixed-point bonding-curve math shared by all clubs (spec §1.4, §1.9).
/// @dev All prices are in $FANS wei (18 decimals). No floats — WAD fixed point with rpow.
///      Curve parameters are protocol-hardcoded per preset; creators pick a type only.
library CurveLibrary {
    uint256 internal constant WAD = 1e18;

    // --- Hardcoded preset parameters (spec §1.4: "Curve parameters are hardcoded per preset") ---

    /// @notice Base price of the first paid key for both presets: 0.01 $FANS.
    uint256 internal constant BASE_PRICE = 1e16;

    /// @notice Linear ("Casual") slope: +0.001 $FANS per key.
    uint256 internal constant LINEAR_SLOPE = 1e15;

    /// @notice Exponential ("Exclusive") multiplier: 1.008x per key (WAD).
    /// ponytail: kept modest so rpow stays well inside uint256 for realistic supplies;
    ///           raise toward the spec's 1.1 example only if you also cap supply.
    uint256 internal constant EXP_MULTIPLIER = 1.008e18;

    /// @notice Hard supply ceiling that keeps exponential rpow from overflowing. Buys past this revert.
    uint256 internal constant MAX_SUPPLY = 5000;

    error SupplyCapExceeded();

    /// @notice Spot price of the single key minted when current supply is `n`.
    function price(CurveType curveType, uint256 n) internal pure returns (uint256) {
        if (curveType == CurveType.Linear) {
            return BASE_PRICE + LINEAR_SLOPE * n;
        }
        return (BASE_PRICE * rpow(EXP_MULTIPLIER, n)) / WAD;
    }

    /// @notice Total cost to buy `amount` keys when current supply is `supply`.
    /// @dev Integral of the curve over [supply, supply + amount).
    function cost(CurveType curveType, uint256 supply, uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        if (supply + amount > MAX_SUPPLY) revert SupplyCapExceeded();
        if (curveType == CurveType.Linear) {
            return _linearSum(supply, amount);
        }
        return _expSum(supply, amount);
    }

    /// @notice Proceeds from selling `amount` keys when current supply is `supply`.
    /// @dev Symmetric to cost: integral over [supply - amount, supply). Caller ensures amount <= supply.
    function proceeds(CurveType curveType, uint256 supply, uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 start = supply - amount;
        if (curveType == CurveType.Linear) {
            return _linearSum(start, amount);
        }
        return _expSum(start, amount);
    }

    // --- internals ---

    /// @dev sum_{i=start}^{start+amount-1} (BASE_PRICE + LINEAR_SLOPE·i)
    function _linearSum(uint256 start, uint256 amount) private pure returns (uint256) {
        // amount·BASE_PRICE + LINEAR_SLOPE·(amount·start + amount·(amount-1)/2)
        uint256 indexSum = amount * start + (amount * (amount - 1)) / 2;
        return amount * BASE_PRICE + LINEAR_SLOPE * indexSum;
    }

    /// @dev BASE_PRICE · sum_{i=start}^{start+amount-1} m^i  (geometric series, WAD).
    ///      = BASE_PRICE · m^start · (m^amount - 1) / (m - 1)
    function _expSum(uint256 start, uint256 amount) private pure returns (uint256) {
        uint256 m = EXP_MULTIPLIER;
        uint256 mStart = rpow(m, start); // WAD
        uint256 mAmount = rpow(m, amount); // WAD
        // numerator/denominator both WAD-scaled → ratio is WAD; multiply by mStart (WAD) then /WAD.
        uint256 series = ((mAmount - WAD) * WAD) / (m - WAD); // WAD: (m^amount - 1)/(m - 1)
        // The intermediate `/ WAD` is deliberate: mStart and series are WAD-scaled and can be
        // very large, so multiplying all three terms before dividing would overflow uint256.
        // forge-lint: disable-next-line(divide-before-multiply)
        return (BASE_PRICE * mStart / WAD) * series / WAD;
    }

    /// @notice x^n in WAD fixed point via exponentiation-by-squaring (Maker-style rpow).
    function rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = WAD;
        while (n > 0) {
            if (n & 1 == 1) {
                z = (z * x) / WAD;
            }
            x = (x * x) / WAD;
            n >>= 1;
        }
    }
}
