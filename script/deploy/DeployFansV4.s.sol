// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {FansHook} from "../../src/swap/FansHook.sol";
import {FansV4Router} from "../../src/swap/FansV4Router.sol";
import {IFeeDistributor} from "../../src/interfaces/IFansInterfaces.sol";

/// @title DeployFansV4
/// @notice Standalone deploy of the Fanhatch Uniswap v4 hybrid (Phase 1): CREATE2-mines the
///         {FansHook} implementation to a flag-encoding address, initializes the $FANS/ETH pool,
///         and deploys the thin {FansV4Router}. NOT wired into DeployAll — run on its own.
/// @dev Mirrors mvmnt-memecoin-launchpad-contracts/script/deployments/DeployPositionManager.s.sol,
///      but non-upgradeable: the hook impl itself is mined (no proxy).
contract DeployFansV4 is Script {
    /// @notice Canonical CREATE2 deployer proxy — Foundry routes salted `new{salt}` through it in scripts.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Default pool tick spacing.
    int24 constant TICK_SPACING = 60;

    /// @notice Hook permission flags encoded into the mined address.
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice Env-driven entrypoint.
    /// @dev Requires env: POOL_MANAGER, FANS, FEE_DISTRIBUTOR, HOOK_OWNER, SQRT_PRICE_X96 (uint160).
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address fans = vm.envAddress("FANS");
        address feeDistributor = vm.envAddress("FEE_DISTRIBUTOR");
        address hookOwner = vm.envAddress("HOOK_OWNER");
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));

        vm.startBroadcast();
        (FansHook hook, PoolKey memory poolKey, FansV4Router router) =
            deploy(poolManager, hookOwner, fans, feeDistributor, 150, sqrtPriceX96);
        vm.stopBroadcast();

        console.log("FansHook       :", address(hook));
        console.log("FansV4Router   :", address(router));
        console.log("pool currency1 :", Currency.unwrap(poolKey.currency1));
    }

    /// @notice Mine + deploy the hook, initialize the ETH/$FANS pool, deploy the router.
    /// @return hook     The deployed FansHook (at the flag-encoding address).
    /// @return poolKey  The initialized $FANS/ETH pool key.
    /// @return router   The thin single-pool router.
    function deploy(
        address poolManager,
        address hookOwner,
        address fans,
        address feeDistributor,
        uint256 feeBps,
        uint160 sqrtPriceX96
    ) public returns (FansHook hook, PoolKey memory poolKey, FansV4Router router) {
        bytes memory constructorArgs =
            abi.encode(IPoolManager(poolManager), hookOwner, fans, IFeeDistributor(feeDistributor), feeBps);

        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(FansHook).creationCode, constructorArgs);

        hook = new FansHook{salt: salt}(
            IPoolManager(poolManager), hookOwner, fans, IFeeDistributor(feeDistributor), feeBps
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(fans),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        IPoolManager(poolManager).initialize(poolKey, sqrtPriceX96);

        router = new FansV4Router(IPoolManager(poolManager), poolKey);
    }
}
