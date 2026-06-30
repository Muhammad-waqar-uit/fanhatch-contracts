// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlatformToken} from "../../src/token/PlatformToken.sol";

/// @title DeployToken
/// @notice Deploys PlatformToken ($FANS) as a UUPS proxy (impl + ERC1967Proxy + initialize).
contract DeployToken is Script {
    struct TokenResult {
        address tokenImpl;
        address token;
    }

    function deployToken(string memory name_, string memory symbol_, address owner_, uint256 initialSupply)
        internal
        returns (TokenResult memory result)
    {
        PlatformToken tokenImpl = new PlatformToken();
        result.tokenImpl = address(tokenImpl);
        console.log("PlatformToken impl:", result.tokenImpl);

        bytes memory initData =
            abi.encodeWithSelector(PlatformToken.initialize.selector, name_, symbol_, owner_, initialSupply);
        result.token = address(new ERC1967Proxy(address(tokenImpl), initData));
        console.log("PlatformToken proxy:", result.token);
    }

    /// @dev Standalone entry point — hardcode params below before running.
    function run() external virtual {
        string memory name_ = "Fans.tech";
        string memory symbol_ = "FANS";
        address owner_ = msg.sender;
        uint256 initialSupply = 1_000_000_000 ether; // TODO: set desired initial supply

        vm.startBroadcast();
        deployToken(name_, symbol_, owner_, initialSupply);
        vm.stopBroadcast();
    }
}
