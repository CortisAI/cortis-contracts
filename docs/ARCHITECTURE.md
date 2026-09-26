# Contract Architecture

## Overview

```
                         ┌───────────────────────────────┐
                         │            OWNER              │
                         │  (one wallet, up to 5 agents) │
                         └──────┬────────────────┬───────┘
             mint voucher       │                │  checkIn()            (wallet)
             (issuer-signed)    │                │  checkIn(agentId)     (agent)
                                ▼                ▼  mapMe / generateWorkflow / deployAgent
                    ┌────────────────┐   ┌─────────────────────────────┐
                    │  AgentPassport │◄──│      CortisEngagement       │
                    │  ERC-721/5192  │   │  (immutable engagement core)│
                    │  soulbound     │   │                             │
                    │  roster max 5  │   │  wallet checkIn → curve pts │
                    └────────────────┘   │  agent  checkIn → +1        │
                                         │  map/workflow/deploy → 0    │
                                         │  pause / unpause            │
                                         └──────────────┬──────────────┘
                                                        │ reads ownership/active
                                                        ▼
                                              (AgentPassport only)

            ┌──────────────────────────────────────────┐
            │        opBNB Mainnet (chainId 204)        │
            │      All events indexed and public        │
            └──────────────────────────────────────────┘

            ┌──────────────────────────────────────────┐
            │  BNB Smart Chain (chainId 56)             │
            │  $COR token — NOT in this repository,     │
            │  deployed separately at TGE               │
            └──────────────────────────────────────────┘
```

Two deployed contracts. No proxy, no upgradeability, no delegatecall. The
engagement core's only on-chain dependency is the immutable `AgentPassport`.

> **Proof-free model.** The earlier attestor subsystem (AttestorRegistry,
> attestor-signed action certificates, corrections, boost, points-spending, the
> fee-policy call path) was removed by product decision. On-chain points are a
> public, farmable engagement score; reward eligibility is decided off-chain.
> `NullFeePolicy` remains in the repo for TGE wiring parity but is not wired into
> the core and is not deployed at launch.

---

## Contract Relationships

### CortisEngagement → AgentPassport

The engagement core holds an immutable `IAgentPassport` reference. It reads
ownership/active state to bind a per-agent check-in to an agent the caller
actually owns. The passport reference is set once in the constructor and is not
repointable. This is the core's only external contract call.

The wallet-scoped `checkIn()` needs no passport at all: it is permissionless and
open to any caller, which is the top-of-funnel DAU action.

---

## Points

There is a single cumulative `points` value per wallet and per agent. It only
increases; there is **no spend, decrement, or correction path**, so `points`
and any notion of "lifetime points" can never diverge. (The old proof economy's
`lifetimePoints` and the unused `ENGAGEMENT_POINTS` constant were removed.)

| Action | Scope | Award |
|---|---|---|
| `checkIn()` | per wallet | `23*streak + 2*streak^2`, capped at 10,000 |
| `checkIn(agentId)` | per agent | flat +1 |
| `mapMe` / `generateWorkflow` / `deployAgent` | wallet or agent | 0 (activity signal only) |

### Wallet check-in curve

```
award = CHECKIN_LIN_COEFF * streak + CHECKIN_QUAD_COEFF * streak^2   (capped)
CHECKIN_LIN_COEFF = 23
CHECKIN_QUAD_COEFF = 2
CHECKIN_MAX_AWARD = 10_000     # reached ~day 66

  day 1  -> 25        day 21 -> 1,365     day 60 -> 8,580
  day 7  -> 259       day 30 -> 2,490     day 66 -> 10,000 (cap)
  day 14 -> 714       day 45 -> 5,085
```

A consecutive UTC day increments the streak; any gap of more than one day resets
it to 1. Integer arithmetic throughout; the `uint64` cast of the award is safe
because the award is capped at 10,000.

### Agent check-in

`checkIn(agentId)` requires an active passport owned by the caller, is limited
to one call per agent per UTC day, tracks a streak, and awards a flat +1.

### Activity events

`mapMe`, `generateWorkflow`, and `deployAgent` (both wallet-scoped and
agent-scoped overloads) record activity counts and emit events but award zero
points. They exist for on-chain activity signal only.

---

## AgentPassport

Soulbound ERC-721 (ERC-5192) on OpenZeppelin v5.

- **Identity model** — one passport per agent, up to 5 active per owner.
- **Mint** — voucher-based: the issuer signs an EIP-712 `MintVoucher` bound to
  the recipient, template, spec, per-owner nonce and deadline. The recipient
  submits it. Nonce is consumed once; deadline enforced; digest bound to the
  recipient so a leaked voucher is useless to anyone else.
- **Soulbound enforcement** — every mint/transfer/deactivate routes through the
  OZ v5 `_update` chokepoint; wallet-to-wallet transfer reverts. `approve` and
  `setApprovalForAll` revert. `locked(id)` returns true (ERC-5192).
- **Roster** — `activeCountOf(owner)` capped at 5; `deactivate` frees a slot but
  preserves ownership/history. `respecialize` updates the bound identity.

---

## Access Control

| Role | Holder (intended) | Powers |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Gnosis Safe multisig | `unpause()` (the only launch power) |
| `GUARDIAN_ROLE` | separate guardian | `pause()` only (cannot unpause) |
| issuer | signing service | sign mint vouchers (off-chain) |

What no key can do: mint/move/burn a passport out of the soulbound rules,
reduce an existing points balance, withdraw value (there is none), or upgrade
logic (no proxy). There is no attestor to add and no fee policy to swap
pre-TGE, so the admin has no routine on-chain job at launch.

---

## On-chain vs off-chain split

| Data | Location | Reason |
|---|---|---|
| Agent identity, ownership, active state | on-chain | publicly verifiable, non-transferable |
| Check-in timestamps, streak, points | on-chain | the engagement record is the point |
| Agent prompts, outputs, action logs, PII | off-chain | private |
| Reward eligibility, Sybil filtering | off-chain, derived | computed from on-chain events + snapshot |

---

## Immutability & fixes

Every contract is immutable and non-upgradeable. If the core is ever defective
the answer is a new deployment plus an audited state import — never an in-place
upgrade that could silently rewrite history. This is why the audited source is
deployed fresh and promoted only after the audit, rather than patched over a
staging address.
