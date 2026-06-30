// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurveLibrary} from "../libraries/CurveLibrary.sol";
import {CurveType, IClubKey, IFeeDistributor} from "../interfaces/IFansInterfaces.sol";

/// @title ClubKey
/// @notice Per-club key contract: bonding-curve pricing, buy/sell, gifting (spec §1.3, §1.7).
/// @dev One instance per club, deployed as a BeaconProxy by ClubFactory. Payment in $FANS.
///      All trades atomic; reentrancy-guarded; first key minted free to the creator.
///      Gift (spec §1.7) lives here since balances live here.
///      ponytail: gifting is a method, not a separate GiftKey contract — a standalone contract
///                would only re-enter this one to move balances. Split it out if gifting ever
///                needs its own fee schedule or allowance model.
contract ClubKey is Initializable, ReentrancyGuardUpgradeable, IClubKey {
    using SafeERC20 for IERC20;

    uint256 public override clubId;
    address public override creator;
    CurveType public override curveType;
    string public name;
    string public ticker;
    string public avatarURI;

    IERC20 public fans;
    IFeeDistributor public feeDistributor;

    uint256 public override totalSupplyKeys;
    mapping(address => uint256) public override balanceOf;

    error ZeroAmount();
    error InsufficientKeys();
    error SlippageExceeded();
    error NotCreator();
    error CannotSellLastKey();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 clubId_,
        address creator_,
        string memory name_,
        string memory ticker_,
        string memory avatarURI_,
        CurveType curveType_,
        IERC20 fans_,
        IFeeDistributor feeDistributor_
    ) external initializer {
        __ReentrancyGuard_init();
        clubId = clubId_;
        creator = creator_;
        name = name_;
        ticker = ticker_;
        avatarURI = avatarURI_;
        curveType = curveType_;
        fans = fans_;
        feeDistributor = feeDistributor_;

        // First key free to the creator (spec §1.3).
        totalSupplyKeys = 1;
        balanceOf[creator_] = 1;
        emit KeyBought(creator_, 1, 0);
    }

    /// @notice Cost (excl. fee) to buy `amount` keys at the current supply.
    function buyPrice(uint256 amount) public view returns (uint256) {
        return CurveLibrary.cost(curveType, totalSupplyKeys, amount);
    }

    /// @notice Proceeds (excl. fee) from selling `amount` keys at the current supply.
    function sellPrice(uint256 amount) public view returns (uint256) {
        return CurveLibrary.proceeds(curveType, totalSupplyKeys, amount);
    }

    /// @inheritdoc IClubKey
    function buyKeys(uint256 amount, uint256 maxCost) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 cost = CurveLibrary.cost(curveType, totalSupplyKeys, amount);
        uint256 fee = (cost * feeDistributor.feeBps()) / 10_000;
        uint256 total = cost + fee;
        if (total > maxCost) revert SlippageExceeded();

        // Effects
        totalSupplyKeys += amount;
        balanceOf[msg.sender] += amount;

        // Interactions: pull cost (held as curve reserve) + fee (routed to distributor).
        fans.safeTransferFrom(msg.sender, address(this), cost);
        if (fee > 0) {
            fans.safeTransferFrom(msg.sender, address(feeDistributor), fee);
            feeDistributor.distribute(fee);
        }
        emit KeyBought(msg.sender, amount, cost);
    }

    /// @inheritdoc IClubKey
    function sellKeys(uint256 amount, uint256 minProceeds) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientKeys();
        // The creator's first key was minted free (no reserve backs it), so supply can never
        // be sold to zero — otherwise the contract would owe BASE_PRICE it never collected.
        if (totalSupplyKeys - amount < 1) revert CannotSellLastKey();
        uint256 gross = CurveLibrary.proceeds(curveType, totalSupplyKeys, amount);
        uint256 fee = (gross * feeDistributor.feeBps()) / 10_000;
        uint256 payout = gross - fee;
        if (payout < minProceeds) revert SlippageExceeded();

        // Effects
        totalSupplyKeys -= amount;
        balanceOf[msg.sender] -= amount;

        // Interactions: pay seller from reserve, route fee.
        fans.safeTransfer(msg.sender, payout);
        if (fee > 0) {
            fans.safeTransfer(address(feeDistributor), fee);
            feeDistributor.distribute(fee);
        }
        emit KeySold(msg.sender, amount, payout);
    }

    /// @inheritdoc IClubKey
    /// @dev Transfers keys with no payment and no fee (spec §1.7: gifting is free).
    function gift(address to, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert NotCreator();
        if (balanceOf[msg.sender] < amount) revert InsufficientKeys();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Gift(msg.sender, to, amount);
    }
}
