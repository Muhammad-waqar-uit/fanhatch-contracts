// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IClubKey, IClubFactory} from "../interfaces/IFansInterfaces.sol";

/// @title GovernanceModule
/// @notice Keyholder voting for each club's president + moderator management (spec §1.6).
/// @dev Single registry keyed by clubId (cheaper than one contract per club). Vote weight =
///      keys held, read live from the club's ClubKey. A candidate becomes president once their
///      tallied weight passes a simple majority of current key supply.
///      ponytail: weight is read at vote time, not checkpointed — fine for a president poll.
///                Swap to ERC20Votes-style checkpoints if flash-loaned key buys become a concern.
contract GovernanceModule is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    IClubFactory public factory;

    struct Poll {
        address president;
        mapping(address => address) choiceOf; // voter => candidate
        mapping(address => uint256) weightOf; // voter => weight counted
        mapping(address => uint256) tally; // candidate => summed weight
        mapping(address => bool) isModerator;
    }

    mapping(uint256 => Poll) private _polls;

    event Voted(uint256 indexed clubId, address indexed voter, address indexed candidate, uint256 weight);
    event PresidentChanged(uint256 indexed clubId, address newPresident);
    event ModeratorSet(uint256 indexed clubId, address moderator, bool enabled);

    error UnknownClub();
    error NotPresident();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IClubFactory factory_) external initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        factory = factory_;
    }

    function presidentOf(uint256 clubId) external view returns (address) {
        return _polls[clubId].president;
    }

    function votesFor(uint256 clubId, address candidate) external view returns (uint256) {
        return _polls[clubId].tally[candidate];
    }

    function isModerator(uint256 clubId, address account) external view returns (bool) {
        return _polls[clubId].isModerator[account];
    }

    /// @notice Cast (or change) your vote for a club's president. Weight = your current key balance.
    function voteForPresident(uint256 clubId, address candidate) external {
        address clubKey = factory.clubKeyOf(clubId);
        if (clubKey == address(0)) revert UnknownClub();
        Poll storage p = _polls[clubId];

        // Remove previous weight from the prior choice, then re-count at the current balance.
        address prev = p.choiceOf[msg.sender];
        if (prev != address(0)) {
            p.tally[prev] -= p.weightOf[msg.sender];
        }
        uint256 weight = IClubKey(clubKey).balanceOf(msg.sender);
        p.choiceOf[msg.sender] = candidate;
        p.weightOf[msg.sender] = weight;
        p.tally[candidate] += weight;
        emit Voted(clubId, msg.sender, candidate, weight);

        // Simple majority of current supply elects the president (spec §1.6).
        uint256 supply = IClubKey(clubKey).totalSupplyKeys();
        if (candidate != p.president && p.tally[candidate] * 2 > supply) {
            p.president = candidate;
            emit PresidentChanged(clubId, candidate);
        }
    }

    /// @notice President sets/clears a moderator for their club (spec §1.6).
    function setModerator(uint256 clubId, address moderator, bool enabled) external {
        if (msg.sender != _polls[clubId].president) revert NotPresident();
        _polls[clubId].isModerator[moderator] = enabled;
        emit ModeratorSet(clubId, moderator, enabled);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
