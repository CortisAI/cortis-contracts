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
- **Security:** `CortisEngagement` under security review by Hashlock — scope in `docs/AUDIT-SCOPE.md`

## Supported Networks

- opBNB Mainnet (Chain ID: 204) — `CortisEngagement` (+ `CortisPassport` dependency), pending deploy
- BNB Smart Chain (Chain ID: 56) — $COR token at TGE, contract not in this repository

## Contract Addresses

| Network | Passport | Engagement | Token |
|---|---|---|---|
| opBNB Mainnet (204) | TBD — pending deploy | TBD — pending deploy | — |
| BNB Smart Chain (56) | — | — | TBD at TGE |

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

## Quick Start

```bash
npm install
npm test       # 21 passing
npm run compile
```

Copy `.env.example` to `.env` before compiling against a network. `.env` is git-ignored.

## Repository Structure

```
contracts/
  CortisEngagement.sol      — check-in + per-agent attestation (audit scope)
  CortisPassport.sol        — soulbound ERC-721 identity (out-of-scope dependency)
docs/
  ARCHITECTURE.md           — contract design and interactions
  AUDIT-SCOPE.md            — audit scope and security properties
test/
  CortisEngagement.test.js
  CortisPassport.test.js
hardhat.config.js
.env.example
```

## Tests

21 tests, all passing. Covers the 24h gate, the 48h streak reset and both boundaries, per-wallet isolation, both attestation paths and their non-owner reverts, the unset-passport revert, owner access control on every setter, multiple passports per wallet, all four soulbound revert paths, and holder-only burn with count decrement.

## Verification

Contracts compile clean at Solidity 0.8.24 with the optimizer enabled (200 runs). Post-audit deployment and opBNBScan verification are handled from the private repository.

## Audit

The engagement contract (`contracts/CortisEngagement.sol`) is under security review by [Hashlock](https://hashlock.com). Review in progress.

Scope is deliberately narrow: **only `CortisEngagement` is under review.** `CortisPassport` is included as an out-of-scope dependency so the reviewers can read the `ownerOf` interface the engagement contract calls into. See [docs/AUDIT-SCOPE.md](docs/AUDIT-SCOPE.md) for the full target list, the security properties being checked, intentional design decisions, and known limitations.

The $COR token is a separate BNB Smart Chain deployment at TGE. It is not in this repository and not in scope. Nothing under review holds, mints, transfers or prices a token.
