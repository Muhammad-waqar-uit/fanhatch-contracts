// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Curve presets — selected once at club creation, immutable thereafter (spec §1.4).
enum CurveType {
    Linear, // "Casual"   — Price(n) = basePrice + slope·n
    Exponential // "Exclusive" — Price(n) = basePrice · multiplier^n

}

/// @title IStakingManager
/// @notice Synthetix-style staking: stake a token, earn $FANS dripped from fees (figma Farm/LP rewards).
interface IStakingManager {
    /// @dev Caller must transfer `reward` $FANS to this contract before calling. Streams over rewardsDuration.
    function notifyRewardAmount(uint256 reward) external;
}

/// @title IFeeDistributor
/// @notice Routes the 1.5% trade fee to treasury and farmer rewards (spec §1.5).
interface IFeeDistributor {
    event FeeDistributed(address indexed source, uint256 total, uint256 toTreasury, uint256 toFarmers);

    /// @notice Fee rate in basis points (150 = 1.5%).
    function feeBps() external view returns (uint256);

    /// @dev Caller must have already transferred `amount` of $FANS to this contract.
    function distribute(uint256 amount) external;
}

/// @title IClubKey
/// @notice Per-club key contract: bonding-curve pricing, buy/sell, gifting (spec §1.3, §1.7).
interface IClubKey {
    event KeyBought(address indexed buyer, uint256 amount, uint256 price);
    event KeySold(address indexed seller, uint256 amount, uint256 proceeds);
    event Gift(address indexed from, address indexed to, uint256 amount);

    function clubId() external view returns (uint256);
    function creator() external view returns (address);
    function curveType() external view returns (CurveType);
    function totalSupplyKeys() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);

    function buyKeys(uint256 amount, uint256 maxCost) external;
    function sellKeys(uint256 amount, uint256 minProceeds) external;
    function gift(address to, uint256 amount) external;
}

/// @title IClubFactory
/// @notice Deploys ClubKey contracts and maintains the registry (spec §1.2).
interface IClubFactory {
    event ClubCreated(uint256 indexed clubId, address indexed creator, string ticker, CurveType curveType, address clubKey);

    function clubKeyOf(uint256 clubId) external view returns (address);
    function clubCount() external view returns (uint256);
}
