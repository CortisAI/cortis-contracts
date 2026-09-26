# Audit Scope & Guidance — Cortis

## Context

Cortis is a personal AI operator product. Each owner runs a small roster of
specialised AI agents trained on their own private data. An agent's identity and
its owner's engagement are recorded on-chain on opBNB.

This repository contains the **simplified proof-free smart-contract set**: the
soulbound agent passport and the engagement/check-in core. This is the source
deployed on opBNB Mainnet (chain 204). See `deployment-addresses.json`.

The `$COR` token contract is **not in this repository and not in this audit
scope**. It is a separate BNB Smart Chain deployment at TGE. Nothing in the
contracts under review holds, mints, transfers or prices a token. Pre-TGE the
contracts are gas-only.

> **Model change (recorded).** An earlier revision used an attestor subsystem:
> `AttestorRegistry`, attestor-signed `ActionCertificate`s, `correctActionOutcome`,
> a boost economy with points-spending, and a fee-policy call path. That entire
> subsystem was removed by product decision. On-chain points are now a public,
> farmable engagement score and reward eligibility is decided off-chain. If a
> signed audit report references `AttestorRegistry` or the attestor/boost/
> correction paths, its scope predates this simplification and must be
> reconciled against the current source before deploy.

---

## In Scope

| File | Priority |
|---|---|
| `src/CortisEngagement.sol` | Critical |
| `src/AgentPassport.sol` | Critical |
| `src/interfaces/ICortis.sol` | Reference |

Retained but not deployed at launch: `src/policies/Policies.sol` (`NullFeePolicy`)
— zero-fee policy kept for TGE wiring parity, not referenced by the engagement
core.

Out of scope: `test/`, the off-chain API/indexer/frontend, and the frontend. The
`$COR` token and any post-TGE fee/tier policy are out of scope.

---

## Toolchain

- Solidity `0.8.28` (pragma `^0.8.27`), optimizer enabled, 400 runs, via-IR off
- OpenZeppelin Contracts `5.6.1` (`AccessControl`, `Pausable`, `EIP712`, `ECDSA`, `ERC721`)
- Foundry (`forge`) — `foundry.toml` pins solc, runs, remappings
- Target chain: opBNB Mainnet, chainId 204
- 28 tests, all passing (`forge test`)

---

## Prior Security Review & Hashlock Fixes

An independent source-level review preceded the Hashlock audit. The Hashlock
engagement produced findings **M-01, L-01..L-06, Q-01..Q-03** and **L-02
(reject active keys in `markCompromised()`)**; all fixes are applied in this
source. Note that some of those findings were raised against the attestor
revision; the proof-free simplification removed the code paths several of them
touched. Auditors should confirm the fixes hold on the current source and look
for regressions.

Key surviving properties to confirm on the proof-free core:

- Telemetry (map/workflow/deploy) awards **zero points**.
- `points` is a single cumulative value with **no spend/decrement/correction
  path**, so it cannot be inflated or double-credited.
- Wallet check-in award follows the capped quadratic curve and cannot exceed
  `CHECKIN_MAX_AWARD`.

---

## Design Intent (read before reviewing)

1. **Pre-TGE the contracts are gas-only.** No token, no fee, no stake, no
   payable function is reachable. `NullFeePolicy` is not wired into the core.
2. **On-chain points are a public engagement score, not a scarce asset.** There
   is one monotonic `points` value per wallet and per agent, no spend path, and
   no cross-account transfer. Reward eligibility is decided off-chain.
3. **Wallet check-in is permissionless.** `checkIn()` takes no passport and no
   role; it is the top-of-funnel DAU action. `checkIn(agentId)` requires an
   active passport owned by the caller.
4. **Passports are soulbound (ERC-5192).** Transfers and approvals revert. Mint
   and deactivate are the state transitions. Roster capped at 5 active per owner.
5. **Immutable, no proxy.** Both contracts are immutable. A fix is a fresh
   deploy plus an audited state import, never an in-place upgrade.
6. **Governance is role-based and minimal.** `DEFAULT_ADMIN_ROLE` (Gnosis Safe
   multisig) can only `unpause()`; a separate `GUARDIAN_ROLE` can `pause()` but
   not unpause. There is no attestor to add and no fee policy to swap pre-TGE.

---

## Check-in curve (growth ledger)

- Award per wallet check-in = `CHECKIN_LIN_COEFF (23) * streak + CHECKIN_QUAD_COEFF (2) * streak^2`, capped at `CHECKIN_MAX_AWARD (10,000)`.
- Streak increments on consecutive UTC days; a gap over one day resets to 1.
- Views: `walletStateOf(address)`, `walletCheckedInToday(address)`, `walletNextCheckInAward(address) -> (uint64 award, uint16 streakAfter)`.
- Per-agent check-in is a flat +1 with independent streak tracking, one per UTC day.
- Integer truncation is intentional; the `uint64(award)` cast is safe because the award is capped at 10,000.

---

## Key Security Properties to Verify

### CortisEngagement

1. **Points can only come from check-in.** Confirm map/workflow/deploy paths
   (both wallet and agent overloads) credit zero points. Only `checkIn()`
   (wallet curve) and `checkIn(agentId)` (agent +1) credit.
2. **Curve safety.** `_checkInAward` cannot exceed `CHECKIN_MAX_AWARD`; the
   `uint64` cast cannot truncate a larger value; streak arithmetic saturates at
   `type(uint16).max` and never overflows.
3. **One check-in per day.** A wallet and an agent can each check in at most once
   per UTC day; consecutive-day detection and gap-reset behave as documented.
4. **Passport binding.** `checkIn(agentId)` and the agent activity overloads
   require an active passport owned by `msg.sender`; reject zero/out-of-range
   agentIds (`uint240` bound) and non-owners.
5. **Pause semantics.** Guardian can pause but not unpause; `whenNotPaused`
   gates the mutating functions; paused state cannot strand funds (there are
   none).
6. **No value handling.** No `payable`, `receive`, or `fallback`. Confirm the
   contract cannot custody or be drained of BNB.
7. **No admin over-reach.** Enumerate what an admin-key compromise achieves;
   confirm it cannot mint/move/burn a passport, cannot rewrite history, and
   cannot reduce a points balance. The only admin power is `unpause()`.

### AgentPassport (ERC-721 soulbound, ERC-5192)

1. **Soulbound enforcement** at the OZ v5 `_update` chokepoint; every transfer
   overload and `approve`/`setApprovalForAll` reverts. `locked(id)` returns true.
2. **Voucher mint** — EIP-712 `MINT_VOUCHER_TYPEHASH` signed by the issuer;
   per-owner voucher nonce consumed once; deadline enforced; voucher bound to
   the recipient.
3. **Roster cap** — max 5 active passports per owner; `deactivate` frees a slot
   without erasing ownership/history; `respecialize` updates the bound identity.
4. **Access control** — issuer, guardian and admin roles are separated; confirm
   role assignment in the constructor and that pausing blocks minting.

---

## Intentional Design Decisions (Not Bugs)

- **Telemetry (map/workflow/deploy) awards zero points.** Kept for on-chain
  activity signal only.
- **Wallet check-in is Sybil-farmable by design at the activity layer.** The
  streak curve is a retention rule, not proof of a unique human. Reward
  eligibility is gated off-chain at snapshot; raw check-in count is an activity
  metric, not an allocation.
- **Permissionless wallet check-in; no supply cap on passports beyond the
  per-owner roster of 5.** Agent identity is meant to be cheap to create.
- **Immutable, no proxy, no delegatecall.** A defect is fixed by fresh deploy +
  audited state import.

---

## Known Limitations

- **No on-chain identity oracle.** The contracts cannot distinguish one human
  with ten wallets from ten humans. Snapshot-time Sybil filtering is off-chain.
- **`block.timestamp` / UTC-day dependence** for check-in and streaks. opBNB
  sequencer timestamps move within bounds; windows are wide enough that minor
  manipulation yields no meaningful advantage.
- **Points are an engagement signal, not proof of work.** With the attestor
  subsystem removed, on-chain points make no claim about unique humans or real
  work; all such weighting is off-chain.

---

## Listing Considerations

- No admin path that can drain user funds. The contracts never hold funds.
- No hidden mint or inflation in any token sense (points are not a transferable
  asset).
- No blacklist, no transfer tax, no owner-controlled transfer restriction beyond
  the blanket soulbound rule.
- No proxy, no upgradeability, no delegatecall. All contracts are immutable.
- Contracts must verify cleanly on opBNBScan.

---

## Test Suite

28 tests. Run with Foundry:

```bash
forge install
forge test
```

Expected: `28 passed`. Coverage spans soulbound/roster/voucher paths, wallet and
agent check-in and streak boundaries, the accelerating curve and its cap,
zero-point telemetry, and pause/guardian rules.

---

## Deployment Status

Deployed on opBNB Mainnet (chain 204) on 2026-09-24 from this source, and
source-verified on Sourcify (exact match):

- `CortisEngagement`: `0xF77C3f4c0b835B93d8d47D52F3a44f7Fe8d2269b`
- `AgentPassport`: `0x932E0E70763C7156c445c4f6F3f7926a4A3F4b4D`

Full details in `deployment-addresses.json`.

---

## Questions

Any question about a design decision or intent should be raised rather than
assumed.
