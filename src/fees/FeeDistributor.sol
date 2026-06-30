// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeDistributor, IStakingManager} from "../interfaces/IFansInterfaces.sol";

/// @title FeeDistributor
/// @notice Routes the 1.5% trade fee to treasury and farmer rewards, paid in $FANS (spec §1.5).
/// @dev Called atomically inside every ClubKey buy/sell. Farmer share accrues here for claim;
///      who counts as a "farmer" is a tokenomics decision (spec §4) — left as a claimable pool.
contract FeeDistributor is Initializable, OwnableUpgradeable, UUPSUpgradeable, IFeeDistributor {
    using SafeERC20 for IERC20;

    IERC20 public fans;
    address public treasury;

    /// @notice Total fee rate (basis points). 150 = 1.5% (spec §1.5).
    uint256 public override feeBps;
    /// @notice Share of the fee routed to treasury (bps of the fee). Remainder goes to farmers.
    uint256 public treasuryShareBps;

    /// @notice Unclaimed farmer rewards accrued in $FANS (fallback when no staking manager is set).
    uint256 public farmerRewards;

    /// @notice Farm that the farmer share is dripped to. If unset, the share accrues to `farmerRewards`.
    address public stakingManager;

    event FeeConfigUpdated(uint256 feeBps, uint256 treasuryShareBps);
    event FarmerRewardsClaimed(address indexed to, uint256 amount);
    event StakingManagerUpdated(address stakingManager);

    error InvalidBps();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IERC20 fans_, address treasury_) external initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        fans = fans_;
        treasury = treasury_;
        feeBps = 150; // 1.5%
        treasuryShareBps = 7000; // 70% treasury / 30% farmers (default split)
    }

    /// @inheritdoc IFeeDistributor
    /// @dev Caller (ClubKey) must transfer `amount` $FANS to this contract before calling.
    function distribute(uint256 amount) external override {
        if (amount == 0) return;
        uint256 toTreasury = (amount * treasuryShareBps) / 10_000;
        uint256 toFarmers = amount - toTreasury;
        if (toTreasury > 0) fans.safeTransfer(treasury, toTreasury);
        if (toFarmers > 0) {
            if (stakingManager != address(0)) {
                // Push the farmer share into the staking drip.
                fans.safeTransfer(stakingManager, toFarmers);
                IStakingManager(stakingManager).notifyRewardAmount(toFarmers);
            } else {
                farmerRewards += toFarmers; // fallback: owner claims manually until a farm exists
            }
        }
        emit FeeDistributed(msg.sender, amount, toTreasury, toFarmers);
    }

    /// @notice Owner pulls accrued farmer rewards to a distribution address (e.g. staking contract).
    function claimFarmerRewards(address to) external onlyOwner {
        uint256 amount = farmerRewards;
        farmerRewards = 0;
        if (amount > 0) fans.safeTransfer(to, amount);
        emit FarmerRewardsClaimed(to, amount);
    }

    function setFeeConfig(uint256 feeBps_, uint256 treasuryShareBps_) external onlyOwner {
        if (feeBps_ > 1000 || treasuryShareBps_ > 10_000) revert InvalidBps(); // cap fee at 10%
        feeBps = feeBps_;
        treasuryShareBps = treasuryShareBps_;
        emit FeeConfigUpdated(feeBps_, treasuryShareBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
    }

    function setStakingManager(address stakingManager_) external onlyOwner {
        stakingManager = stakingManager_;
        emit StakingManagerUpdated(stakingManager_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
