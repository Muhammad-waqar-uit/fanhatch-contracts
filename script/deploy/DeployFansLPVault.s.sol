// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FansLPVault} from "../../src/swap/FansLPVault.sol";

/// @notice Minimal interface to point an LP {StakingManager} at a freshly deployed vault token.
interface IStakingTokenSetter {
    function stakingToken() external view returns (address);
}

/// @title DeployFansLPVault
/// @notice Phase-2 deploy: deploys the {FansLPVault} (ERC-20 FANS-LP) over the already-initialized
///         Phase-1 $FANS/ETH v4 pool, so the LP {StakingManager} instance can stake the vault token.
/// @dev The StakingManager is UUPS and its `stakingToken` is set at initialize-time. For a fresh LP
///      farm, initialize it with the vault address as the staking token (see `logStakingWiring`).
contract DeployFansLPVault is Script {
    int24 constant TICK_SPACING = 60;

    /// @notice Env-driven entrypoint.
    /// @dev Requires env: POOL_MANAGER, FANS, HOOK (the FansHook address on the pool).
    function run() external returns (FansLPVault vault) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address fans = vm.envAddress("FANS");
        address hook = vm.envAddress("HOOK");

        vm.startBroadcast();
        vault = deploy(poolManager, fans, hook, TICK_SPACING);
        vm.stopBroadcast();

        console.log("FansLPVault (FANS-LP):", address(vault));
        console.log("Point the LP StakingManager.stakingToken at:", address(vault));
    }

    /// @notice Deploy the vault against the canonical ETH/$FANS pool key.
    /// @param poolManager Uniswap v4 PoolManager.
    /// @param fans        $FANS token (pool currency1).
    /// @param hook        The FansHook deployed for the pool.
    /// @param tickSpacing Pool tick spacing (must match the initialized pool).
    function deploy(address poolManager, address fans, address hook, int24 tickSpacing)
        public
        returns (FansLPVault vault)
    {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(fans),
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        vault = new FansLPVault(IPoolManager(poolManager), poolKey);
    }
}
