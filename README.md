# Cortis AI

A personal AI executive team with on-chain agent identity and engagement, built on **BNB Chain (opBNB)** and compatible with other EVM networks.

Cortis gives every user a team of specialist AI executive agents trained on their own data. Each agent is minted as a soulbound **Agent Passport** on opBNB, and its owner's engagement (check-ins, profile mapping, workflows, deployments) is recorded on-chain by **CortisEngagement**. This repository is the official smart-contract source for both, deployed on opBNB Mainnet (Chain ID 204).

- App: https://app.cortisai.com
- Website: https://cortisai.com
- X: https://x.com/cortis_ai

## Technology Stack

- **Blockchain**: BNB Chain, opBNB Mainnet (engagement layer). The $COR token launches on BNB Smart Chain at TGE.
- **Smart Contracts**: Solidity 0.8.28 (pragma `^0.8.27`), optimizer enabled, 400 runs
- **Frontend**: React + Vite + viem (app.cortisai.com, separate repository)
- **Development**: Foundry (`forge`), OpenZeppelin Contracts 5.x

## Supported Networks

- **opBNB Mainnet** (Chain ID: 204): AgentPassport + CortisEngagement, live
- **BNB Smart Chain Mainnet** (Chain ID: 56): $COR token at TGE (not yet deployed)

## Contract Addresses

| Network | Core Contract (CortisEngagement) | Identity (AgentPassport) | Token ($COR) |
|---|---|---|---|
| opBNB Mainnet (204) | [`0xF77C3f4c0b835B93d8d47D52F3a44f7Fe8d2269b`](https://opbnbscan.com/address/0xF77C3f4c0b835B93d8d47D52F3a44f7Fe8d2269b) | [`0x932E0E70763C7156c445c4f6F3f7926a4A3F4b4D`](https://opbnbscan.com/address/0x932E0E70763C7156c445c4f6F3f7926a4A3F4b4D) | n/a |
| BNB Smart Chain (56) | n/a | n/a | TBD at TGE |

Both opBNB contracts are source-verified on Sourcify (exact match, runtime and creation bytecode). Deployment details, roles and transaction hashes are in [`deployment-addresses.json`](deployment-addresses.json). Admin rights are held by a Gnosis Safe multisig; the deployer holds no roles.

## Features

- **Soulbound agent identity on opBNB**: each AI agent is a non-transferable ERC-721 (ERC-5192) Agent Passport, minted with an issuer-signed voucher. Up to 5 active agents per owner.
- **On-chain engagement**: daily wallet and agent check-ins with an accelerating streak curve, plus `mapMe`, `generateWorkflow` and `deployAgent` activity events.
- **Low-cost by design for opBNB**: gas-only pre-TGE. No token, fee or stake paths; the only user cost is opBNB gas.
- **Security controls**: role-based access with a Safe-held admin and a separate guardian that can pause but not unpause. No one can move, mint for, or rewrite another user's history.
- **Immutable contracts**: no proxy, no upgradeability, no delegatecall.

## Contracts

| Contract | File | Purpose |
|---|---|---|
| `CortisEngagement` | `src/CortisEngagement.sol` | Wallet + agent daily check-in, activity events |
| `AgentPassport` | `src/AgentPassport.sol` | Soulbound ERC-721 (ERC-5192) agent identity |
| `NullFeePolicy` | `src/policies/Policies.sol` | Zero-fee policy kept for TGE wiring parity (not deployed) |
| `ICortis` | `src/interfaces/ICortis.sol` | Shared interfaces |

## Quick Start

```bash
forge install foundry-rs/forge-std --no-git
npm install
forge build
forge test        # 28 passing
```

Deploying to opBNB (RPC configured in `foundry.toml` as `opbnb`):

```bash
cp .env.example .env   # fill in values, never commit a key
forge create src/AgentPassport.sol:AgentPassport --rpc-url opbnb --private-key "$DEPLOYER_PRIVATE_KEY" ...
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Security scope](docs/AUDIT-SCOPE.md)

## Security

Security review by Hashlock. The final report will be linked here once published. The $COR token is a separate BNB Smart Chain deployment at TGE and is not in this repository.

## License

MIT
