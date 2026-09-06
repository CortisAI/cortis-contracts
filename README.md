# Cortis Contracts

On-chain engagement and soulbound agent identity for Cortis, built for opBNB Mainnet.

Cortis is a personal AI operator. Each owner runs a small roster of specialised AI agents trained on their own private data. These contracts record an agent's identity and its completed work on-chain.

## Status

**Pre-audit. Built and tested, not deployed.** No contract in this repository is live on any public network. There are no addresses to verify yet.

## Technology Stack

- **Blockchain:** opBNB Mainnet (engagement layer). $COR launches separately on BNB Smart Chain at TGE.
- **Smart Contracts:** Solidity 0.8.24, optimizer enabled, 200 runs
- **Libraries:** OpenZeppelin Contracts 5.x (`_update` hook model, not v4)
- **Development:** Hardhat 2.22
- **Frontend:** Vanilla JS + ethers.js v6 (in `../app`)
- **Security:** under audit review by Hashlock — scope defined in `docs/AUDIT-SCOPE.md`

## Supported Networks

- opBNB Mainnet (Chain ID: 204) — `CortisPassport` + `CortisEngagement`, pending deploy
- BNB Smart Chain (Chain ID: 56) — $COR token at TGE, contract not in this repository

## Contract Addresses

| Network | Passport | Engagement | Token |
|---|---|---|---|
| opBNB Mainnet (204) | TBD — pending deploy | TBD — pending deploy | — |
| BNB Smart Chain (56) | — | — | TBD at TGE |

See `deployment-addresses.json`.

## Contracts

**`CortisPassport`** — soulbound ERC-721 agent identity. Minting commits an agent on-chain. One wallet may hold many passports, one per agent. Transfers revert; `approve` and `setApprovalForAll` revert. The holder may burn their own passport. 160 lines.

**`CortisEngagement`** — daily check-in on a rolling 24h window with streak tracking on a 48h continuation gap, plus per-agent attestation of map and workflow hashes. Attestation requires the caller to own the referenced passport, which is what binds attested work to a specific agent rather than a wallet. 203 lines.

## Features

- **Gas-only pre-TGE** — no token, no fee, no stake, no `payable` function. The only user cost is opBNB gas.
- **Soulbound agent identity** — non-transferable, enforced at the single OpenZeppelin v5 `_update` chokepoint so every transfer overload is covered by one guard.
- **Per-agent attestation** — map and workflow hashes written against a passport the caller owns. Only hashes on-chain, never prompts, outputs or PII.
- **Streak-compounding engagement** — check-in points scale with a maintained streak; nothing decays, nothing is subtracted.
- **TGE-additive by design** — a reserved `corToken` address lets post-TGE fee and stake modules attach without redeploying the engagement contract or migrating the points ledger.
- **No proxy, no upgradeability, no delegatecall** — both contracts are immutable once deployed.
- **Multisig ownership after deploy** — a documented post-deploy step; the owner key cannot mint, move or burn a passport, cannot reduce a points balance, and cannot withdraw anything.

## Documentation

| Document | Description |
|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Contract interactions, state machines, on-chain vs off-chain split, access control |
| [AUDIT SCOPE](docs/AUDIT-SCOPE.md) | Audit targets, security properties, intentional design decisions, known limitations |
| [TOKENOMICS](../CORTIS-TOKENOMICS.md) | $COR supply, allocation, depth-metered release |
| [DEPLOY CHECKLIST](DEPLOY-CHECKLIST.md) | Step-by-step opBNB deployment and verification |

## Quick Start

```bash
npm install
npm test              # 21 passing
npm run compile
npm run deploy:local  # in-memory hardhat, free
npm run deploy:opbnb  # opBNB mainnet, requires funded DEPLOYER_PRIVATE_KEY
```

Copy `.env.example` to `.env` before deploying. `.env` is git-ignored.

## Repository Structure

```
contracts/
  CortisPassport.sol        — soulbound ERC-721 agent identity
  CortisEngagement.sol      — check-in + per-agent attestation
flattened/                  — single-file versions for explorer verification
docs/
  ARCHITECTURE.md           — contract design and interactions
  AUDIT-SCOPE.md            — audit scope and security properties
test/
  CortisPassport.test.js
  CortisEngagement.test.js
scripts/
  deploy.js                 — deploys both, wires them, writes addresses
hardhat.config.js
deployment-addresses.json
DEPLOY-CHECKLIST.md
.env.example
```

## Tests

21 tests, all passing. Covers the 24h gate, the 48h streak reset and both boundaries, per-wallet isolation, both attestation paths and their non-owner reverts, the unset-passport revert, owner access control on every setter, multiple passports per wallet, all four soulbound revert paths, and holder-only burn with count decrement.

## Verification

`flattened/` contains single-file flattened sources for opBNBScan verification. They inline all OpenZeppelin dependencies, which is why they are longer; the Cortis logic is identical to `contracts/`. Both flattened files compile clean at 0.8.24 with the same optimizer settings.

## Audit

Under review by [Hashlock](https://hashlock.com). Audit in progress.

| Document | Description |
|---|---|
| [Audit Scope](docs/AUDIT-SCOPE.md) | Audit targets, security properties to verify, intentional design decisions, and known limitations |

The $COR token contract is a separate BNB Smart Chain deployment and is **not** in this repository or in audit scope. Nothing under review holds, mints, transfers or prices a token.
