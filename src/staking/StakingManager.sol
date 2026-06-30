// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStakingManager} from "../interfaces/IFansInterfaces.sol";

/// @title StakingManager
/// @notice "Farm": stake a token (e.g. $FANS or FansSwap LP) and earn $FANS rewards dripped from
///         trading fees (spec §1.5 farmers; figma Wallet Farm Rewards + LP rewards).
/// @dev Synthetix StakingRewards time-based drip — O(1) per user. UUPS upgradeable.
///      Deploy one instance per stake token (a $FANS farm and an LP farm share this code).
///      ponytail: classic Synthetix caveat — if stakingToken == rewardToken, reward accounting is
///                kept separate from staked principal via notified amounts only; never sweep the
///                contract balance as reward. Documented, not a bug.
contract StakingManager is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IStakingManager
{
    using SafeERC20 for IERC20;

    IERC20 public stakingToken;
    IERC20 public rewardToken; // $FANS
    address public rewardsDistributor; // FeeDistributor, allowed to notify rewards

    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate; // reward tokens per second, scaled by 1e18
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);

    error ZeroAmount();
    error InsufficientStake();
    error NotDistributor();
    error RewardTooHigh();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IERC20 stakingToken_, IERC20 rewardToken_, address rewardsDistributor_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
        rewardsDistributor = rewardsDistributor_;
        rewardsDuration = 7 days;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientStake();
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    /// @inheritdoc IStakingManager
    /// @dev FeeDistributor transfers `reward` $FANS here, then calls this to start/extend the drip.
    function notifyRewardAmount(uint256 reward) external override updateReward(address(0)) {
        if (msg.sender != rewardsDistributor && msg.sender != owner()) revert NotDistributor();
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        // Guard against rewardRate that the contract balance can't cover (Synthetix invariant).
        uint256 balance = rewardToken.balanceOf(address(this));
        if (rewardRate > balance / rewardsDuration) revert RewardTooHigh();
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    function setRewardsDuration(uint256 duration) external onlyOwner {
        require(block.timestamp >= periodFinish, "drip active");
        rewardsDuration = duration;
    }

    function setRewardsDistributor(address distributor) external onlyOwner {
        rewardsDistributor = distributor;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
