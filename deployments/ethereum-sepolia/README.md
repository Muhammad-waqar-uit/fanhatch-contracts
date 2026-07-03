# Fans.tech — Ethereum Sepolia Deployment

**Network:** Ethereum Sepolia · **chainId:** `11155111`
**Deployed:** 2026-07-02 · **Block:** `11193463`
**Deployer / Owner:** `0x664dc8bb57bEA1278C47779F915F879029232E61`
**Treasury:** `0x7A562401680002fFeADDEf1fBF5022B72f171190`
**Status:** all 15 contracts **verified on Etherscan** ✅ · **testnet only** (not hardened for mainnet — see caveat).

> Machine-readable addresses: [`addresses.json`](./addresses.json).
> Interact with the **proxy** addresses; the **impl** addresses are for verification/upgrades.

## Core contracts (interact with the proxy)

| Contract | Kind | Address | Etherscan |
|---|---|---|---|
| **$FANS** — PlatformToken | UUPS proxy | `0xeaD4ea56B35Db340F0d8E9fc21929994751e3AeA` | [↗](https://sepolia.etherscan.io/address/0xeaD4ea56B35Db340F0d8E9fc21929994751e3AeA) |
| **FeeDistributor** | UUPS proxy | `0xfb8d90D93fB43bCDde37b40151BE088EFc5ee10E` | [↗](https://sepolia.etherscan.io/address/0xfb8d90D93fB43bCDde37b40151BE088EFc5ee10E) |
| **ClubFactory** | UUPS proxy | `0x85Eb6F843E17D5b11127791678A6c9A457Ae516f` | [↗](https://sepolia.etherscan.io/address/0x85Eb6F843E17D5b11127791678A6c9A457Ae516f) |
| **GovernanceModule** | UUPS proxy | `0xF217867fb25bE6f22B99eDA2399d9f4D01323b56` | [↗](https://sepolia.etherscan.io/address/0xF217867fb25bE6f22B99eDA2399d9f4D01323b56) |
| **FansSwap** (ETH↔$FANS AMM) | UUPS proxy | `0x8B37DCFBd1fBcA862bF45B81D9Ba4FbC057d6510` | [↗](https://sepolia.etherscan.io/address/0x8B37DCFBd1fBcA862bF45B81D9Ba4FbC057d6510) |
| **StakingManager — $FANS farm** | UUPS proxy | `0xc7909d54003DdfDDEFa769EEEEd713312d29679B` | [↗](https://sepolia.etherscan.io/address/0xc7909d54003DdfDDEFa769EEEEd713312d29679B) |
| **StakingManager — LP farm** | UUPS proxy | `0x8C7a0103D73986cd5A4009aaB674be141517d199` | [↗](https://sepolia.etherscan.io/address/0x8C7a0103D73986cd5A4009aaB674be141517d199) |
| **ClubKey UpgradeableBeacon** | beacon | `0x5205905477DA696088Ec24Ee091000ab3d4698c4` | [↗](https://sepolia.etherscan.io/address/0x5205905477DA696088Ec24Ee091000ab3d4698c4) |

> `ClubKey` instances are BeaconProxies deployed per-club by `ClubFactory.createClub(...)`; they all point at the beacon above.

## Implementations (for verification / upgrades)

| Impl of | Address |
|---|---|
| PlatformToken | `0x6D98ad49CC76946B385CA4eFa530763817E3FDc0` |
| FeeDistributor | `0x94A27d29aCf3b773B57B08B2423d4c39c1d7d807` |
| ClubFactory | `0x26aeB23693904065Bb019E544Dcd1BFB01C69A09` |
| ClubKey (beacon impl) | `0x177B33E6aF4187436b4a488945F4e4A3D6Ab0AB4` |
| GovernanceModule | `0x6B3227F43DDd11a2917CFA87dF880d1420B42044` |
| FansSwap | `0x1bE00A04e5a476d9627B2CD82566e0c015055558` |
| StakingManager (shared by both farms) | `0xb6Da8df800f8036973457D6568769a40C82ECC03` |

## Post-deploy wiring
- `FeeDistributor.setStakingManager → 0xc790…679B` ($FANS farm) — so the 30% farmer share of the 1.5% trade fee drips to the $FANS farm.
- `$FANS`: name **"Fans.tech"**, symbol **FANS**, initial supply **1,000,000,000** minted to the owner.

## Reproduce / redeploy
```bash
# simulate
forge script script/deploy/DeployAll.s.sol:DeployAll --sig "run()" --rpc-url sepolia -vvv
# broadcast + verify (writes deployments/<network>/addresses.json)
DEPLOY_NETWORK=ethereum-sepolia forge script script/deploy/DeployAll.s.sol:DeployAll \
  --sig "run()" --rpc-url sepolia --broadcast --verify -vvv
```

## ⚠️ Caveat — testnet only
This is a Sepolia deploy for integration/testing. **Before mainnet**, address the known hardening gap:
**no timelock/multisig on upgrades** — the owner (deployer EOA) can currently upgrade any proxy instantly.
Move ownership to a `TimelockController` + Gnosis Safe first.
