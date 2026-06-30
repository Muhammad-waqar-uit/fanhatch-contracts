// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ClubKey} from "../club/ClubKey.sol";
import {CurveType, IClubFactory, IFeeDistributor} from "../interfaces/IFansInterfaces.sol";

/// @title ClubFactory
/// @notice Deploys a ClubKey BeaconProxy per club and maintains the registry (spec §1.2).
/// @dev Beacon pattern: one upgrade point for every ClubKey instance. UUPS-upgradeable itself.
contract ClubFactory is Initializable, OwnableUpgradeable, UUPSUpgradeable, IClubFactory {
    UpgradeableBeacon public beacon;
    IERC20 public fans;
    IFeeDistributor public feeDistributor;

    uint256 public override clubCount;
    mapping(uint256 => address) public override clubKeyOf;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address clubKeyImpl, IERC20 fans_, IFeeDistributor feeDistributor_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        beacon = new UpgradeableBeacon(clubKeyImpl, owner_);
        fans = fans_;
        feeDistributor = feeDistributor_;
    }

    /// @notice Creates a club: deploys its ClubKey, mints the creator's free first key, registers it.
    /// @return clubId Sequential id. The club's human identifier is `FT{clubId}` (spec §1.2).
    /// @return clubKey Address of the new ClubKey proxy.
    function createClub(string calldata name, string calldata ticker, string calldata avatarURI, CurveType curveType)
        external
        returns (uint256 clubId, address clubKey)
    {
        clubId = ++clubCount;
        bytes memory initData = abi.encodeWithSelector(
            ClubKey.initialize.selector, clubId, msg.sender, name, ticker, avatarURI, curveType, fans, feeDistributor
        );
        clubKey = address(new BeaconProxy(address(beacon), initData));
        clubKeyOf[clubId] = clubKey;
        emit ClubCreated(clubId, msg.sender, ticker, curveType, clubKey);
    }

    /// @notice Human-readable club identifier, e.g. "FT1" (spec §1.2).
    function ftId(uint256 clubId) external pure returns (string memory) {
        return string.concat("FT", Strings.toString(clubId));
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
