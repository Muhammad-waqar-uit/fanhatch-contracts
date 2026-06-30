// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {ClubFactory} from "../../src/factory/ClubFactory.sol";

/// @title DeployFactory
/// @notice Deploys the ClubKey beacon implementation, then ClubFactory as a UUPS proxy.
/// @dev ClubFactory.initialize creates the UpgradeableBeacon internally from `clubKeyImpl`.
contract DeployFactory is Script {
    struct FactoryResult {
        address clubKeyImpl;
        address clubFactoryImpl;
        address clubFactory;
    }

    function deployFactory(address owner_, address fans, address feeDistributor)
        internal
        returns (FactoryResult memory result)
    {
        // 1. ClubKey beacon implementation (passed into the factory, which builds the beacon).
        ClubKey clubKeyImpl = new ClubKey();
        result.clubKeyImpl = address(clubKeyImpl);
        console.log("ClubKey impl (beacon):", result.clubKeyImpl);

        // 2. ClubFactory UUPS proxy.
        ClubFactory factoryImpl = new ClubFactory();
        result.clubFactoryImpl = address(factoryImpl);
        console.log("ClubFactory impl:", result.clubFactoryImpl);

        bytes memory initData = abi.encodeWithSelector(
            ClubFactory.initialize.selector, owner_, result.clubKeyImpl, fans, feeDistributor
        );
        result.clubFactory = address(new ERC1967Proxy(address(factoryImpl), initData));
        console.log("ClubFactory proxy:", result.clubFactory);
    }

    /// @dev Standalone entry point — hardcode params below before running.
    function run() external virtual {
        address owner_ = msg.sender;
        address fans = address(0xdead01); // TODO: replace with $FANS token address
        address feeDistributor = address(0xdead02); // TODO: replace with FeeDistributor address

        vm.startBroadcast();
        deployFactory(owner_, fans, feeDistributor);
        vm.stopBroadcast();
    }
}
