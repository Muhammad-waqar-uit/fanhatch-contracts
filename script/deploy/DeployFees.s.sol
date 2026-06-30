// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeDistributor} from "../../src/fees/FeeDistributor.sol";

/// @title DeployFees
/// @notice Deploys FeeDistributor as a UUPS proxy (impl + ERC1967Proxy + initialize).
contract DeployFees is Script {
    struct FeesResult {
        address feeDistributorImpl;
        address feeDistributor;
    }

    function deployFees(address owner_, address fans, address treasury)
        internal
        returns (FeesResult memory result)
    {
        FeeDistributor feesImpl = new FeeDistributor();
        result.feeDistributorImpl = address(feesImpl);
        console.log("FeeDistributor impl:", result.feeDistributorImpl);

        bytes memory initData = abi.encodeWithSelector(FeeDistributor.initialize.selector, owner_, fans, treasury);
        result.feeDistributor = address(new ERC1967Proxy(address(feesImpl), initData));
        console.log("FeeDistributor proxy:", result.feeDistributor);
    }

    /// @dev Standalone entry point — hardcode params below before running.
    function run() external virtual {
        address owner_ = msg.sender;
        address fans = address(0xdead01); // TODO: replace with $FANS token address
        address treasury = vm.envAddress("FANS_TREASURY");

        vm.startBroadcast();
        deployFees(owner_, fans, treasury);
        vm.stopBroadcast();
    }
}
