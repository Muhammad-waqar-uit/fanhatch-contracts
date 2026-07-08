# Fanhatch — Smart Contracts

Social-token platform: creators launch **clubs**, each club has bonding-curve-priced **keys**
that gate a private chat, key holders **vote** for a president and can **gift** keys, and
everything is paid in the platform token **$FANS**. Target chain: **Base** (Ethereum L2).

> Scope: smart contracts only (spec §1). Backend services (§2) and frontend are out of scope.

Built with [Foundry](https://book.getfoundry.sh/).

## Deployments

| Network | Status | Addresses |
|---|---|---|
| **Ethereum Sepolia** (`11155111`) | ✅ live + verified (2026-07-02) | [`deployments/ethereum-sepolia/`](./deployments/ethereum-sepolia/README.md) |
| Base | not deployed yet | — |

Key proxies (Sepolia): **$FANS** `0xeaD4…3AeA` · **ClubFactory** `0x85Eb…516f` · **FeeDistributor** `0xfb8d…ee10E` · **GovernanceModule** `0xF217…3b56` · **StakingManager** ($FANS farm) `0xc790…679B` · **StakingManager** (base LP farm) `0x8C7a…d199` (superseded by the v4 LP farm `0xF4A8…BC3b` below). Full list + Etherscan links in the deployment README.

### $FANS/ETH — Uniswap v4 hybrid (deployed)

The $FANS/ETH market has migrated from the custom `FansSwap` AMM to a **Uniswap v4** pool
(`currency0 = ETH 0x0`, `currency1 = $FANS`, `fee = 0` dynamic — `FansHook` charges the fee,
`tickSpacing = 60`). Swaps route through `FansV4Router`; liquidity is the ERC-20 vault
`FansLPVault` (`FANS-LP`) over one full-range v4 position. `FansSwap` is **deprecated but still
deployed**.

| Contract | Address (Sepolia) |
|---|---|
| Uniswap v4 PoolManager (canonical) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| FansHook | `0xB2015C1c323d22D68E06042EB9A70a3b4f7760CC` |
| FansV4Router | `0x19dbb0CBbf6910D39a6513f36E8CDC418f586545` |
| FansLPVault (`FANS-LP`) | `0x96bC0735c79666a68d779584974e1F93F42F0Df9` |
| LP StakingManager (v4 LP farm) | `0xF4A8F3c8ac866551B1aAa78cF19C238D7243BC3b` |
| FansSwap (legacy, deprecated) | `0x8B37…6510` |

`FeeDistributor` has been repointed (`setStakingManager`) at the LP StakingManager above, so
the whole trade-fee farmer share — v4 swap fees (via `FansHook`) **and** club-key trade fees —
now drips to **FANS-LP** stakers. The base-deployment $FANS farm (`0xc790…679B`) is no longer
fee-funded (treasury-funded / dormant incentive).

## Architecture

| Contract | Path | Responsibility (spec) |
|---|---|---|
| `PlatformToken` | `src/token/PlatformToken.sol` | ERC-20 **$FANS** — currency for all key trades. Votes + Pausable, UUPS. (§1.1) |
| `ClubFactory` | `src/factory/ClubFactory.sol` | Deploys a `ClubKey` BeaconProxy per club, keeps the `clubId → address` registry, `FT#` ids. (§1.2) |
| `ClubKey` | `src/club/ClubKey.sol` | Per-club key supply, bonding-curve buy/sell, free first key, **gift** (§1.7). (§1.3) |
| `CurveLibrary` | `src/libraries/CurveLibrary.sol` | Fixed-point math for Linear + Exponential curves. (§1.4, §1.9) |
| `FeeDistributor` | `src/fees/FeeDistributor.sol` | Routes the 1.5% trade fee to treasury + farmer rewards, in $FANS. (§1.5) |
| `GovernanceModule` | `src/governance/GovernanceModule.sol` | Keyholder president voting + moderators, weight = keys held. (§1.6) |
| `FansHook` | `src/swap/FansHook.sol` | Uniswap v4 hook for the $FANS/ETH pool: sets the dynamic trade fee (default 1.5%), takes it via `poolManager.take`, and forwards it to `FeeDistributor → StakingManager`. |
| `FansV4Router` | `src/swap/FansV4Router.sol` | Swap entrypoint for the v4 pool: `swapExactEthForFans(minOut)` payable, `swapExactFansForEth(amountIn, minOut)`. |
| `FansLPVault` | `src/swap/FansLPVault.sol` | ERC-20 liquidity vault (`FANS-LP`) over one full-range v4 position: `deposit(fansIn)` payable → mints FANS-LP; `withdraw(shares)` → burns → ETH + $FANS. Stakeable in the LP farm. |
| `FansSwap` | `src/swap/FansSwap.sol` | **Deprecated** (still deployed). Minimal constant-product AMM, ETH ↔ $FANS, LP as an ERC-20 ("FANS-LP"). Superseded by the Uniswap v4 hybrid above. (§1.8 / §2.5) |
| `StakingManager` | `src/staking/StakingManager.sol` | "Farm": stake $FANS or FANS-LP, earn $FANS dripped from fees (the §1.5 "farmers"; figma Wallet Farm/LP rewards). |

**Bonding curves** (parameters hardcoded per preset; creator picks a type, locked at launch):
- **Linear ("Casual")** — `Price(n) = BASE_PRICE + LINEAR_SLOPE·n` — steady, accessible.
- **Exponential ("Exclusive")** — `Price(n) = BASE_PRICE · MULTIPLIER^n` — explosive, scarce.

**Upgradeability:** core contracts are UUPS (ERC1967) proxies; `ClubKey` uses a single
`UpgradeableBeacon` so every club upgrades from one point. Buy/sell/gift are reentrancy-guarded
and atomic (price + transfer + fee in one tx).

## Usage

```shell
forge build              # compile
forge test               # full suite (unit / fuzz / invariant / integration / e2e / security)
forge test --gas-report  # with gas
forge fmt                # format
forge coverage           # coverage
```

### Deploy

Env keys live in `.env` (see below). Deploy the whole system to Sepolia:

```shell
source .env
forge script script/deploy/DeployAll.s.sol --sig "run()" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY_1 --broadcast --verify
```

To Base:

```shell
forge script script/deploy/DeployAll.s.sol --sig "run()" \
  --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY_1 --broadcast
```

Individual layers: `DeployToken`, `DeployFees`, `DeployFactory`, `DeployGovernance`, `DeploySwap`.

### Environment (`.env`)

| Key | Purpose |
|---|---|
| `PRIVATE_KEY_1` / `_2` / `_3` | Deployer / test signer keys |
| `SEPOLIA_RPC_URL` | Sepolia RPC (Alchemy) |
| `BASE_RPC_URL` | Base RPC (Fanhatch target chain) |
| `ETHERSCAN_API_KEY` | Contract verification |
| `FANS_TREASURY` | Protocol multisig / fee recipient |

## Layout

```
src/        contracts, organized by domain
test/       base/ unit/ fuzz/ invariant/ integration/ e2e/ security/
script/     deploy/ deployment scripts (UUPS proxy pattern)
deployments/<network>/addresses.json   deployed addresses
lib/        forge-std, openzeppelin-contracts, openzeppelin-contracts-upgradeable
```

## Open questions (spec §4)

Tokenomics ($FANS supply/allocation), farmer definition + fee split %, president voting
threshold, on/off-chain moderators, supply cap, and gift fee are TBD — current defaults:
1.5% fee (70/30 treasury/farmer split), free gifting, simple-majority president, per-curve
supply ceiling of 5000.
