# Fans.tech — Smart Contracts

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

Key proxies (Sepolia): **$FANS** `0xeaD4…3AeA` · **ClubFactory** `0x85Eb…516f` · **FansSwap** `0x8B37…6510` · **FeeDistributor** `0xfb8d…ee10E` · **GovernanceModule** `0xF217…3b56` · **StakingManager** ($FANS farm) `0xc790…679B`. Full list + Etherscan links in the deployment README.

## Architecture

| Contract | Path | Responsibility (spec) |
|---|---|---|
| `PlatformToken` | `src/token/PlatformToken.sol` | ERC-20 **$FANS** — currency for all key trades. Votes + Pausable, UUPS. (§1.1) |
| `ClubFactory` | `src/factory/ClubFactory.sol` | Deploys a `ClubKey` BeaconProxy per club, keeps the `clubId → address` registry, `FT#` ids. (§1.2) |
| `ClubKey` | `src/club/ClubKey.sol` | Per-club key supply, bonding-curve buy/sell, free first key, **gift** (§1.7). (§1.3) |
| `CurveLibrary` | `src/libraries/CurveLibrary.sol` | Fixed-point math for Linear + Exponential curves. (§1.4, §1.9) |
| `FeeDistributor` | `src/fees/FeeDistributor.sol` | Routes the 1.5% trade fee to treasury + farmer rewards, in $FANS. (§1.5) |
| `GovernanceModule` | `src/governance/GovernanceModule.sol` | Keyholder president voting + moderators, weight = keys held. (§1.6) |
| `FansSwap` | `src/swap/FansSwap.sol` | Minimal constant-product AMM, ETH ↔ $FANS. LP positions are an ERC-20 ("FANS-LP"). (§1.8 / §2.5) |
| `StakingManager` | `src/staking/StakingManager.sol` | "Farm": stake $FANS or LP, earn $FANS dripped from fees (the §1.5 "farmers"; figma Wallet Farm/LP rewards). |

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
| `BASE_RPC_URL` | Base RPC (Fans.tech target chain) |
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
