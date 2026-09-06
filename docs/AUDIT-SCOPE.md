# Audit Scope & Guidance — Cortis

## Context

Cortis is a personal AI operator product. Each owner runs a small roster of specialised AI agents trained on their own private data. An agent's identity and its completed work are recorded on-chain.

This repository contains the **Phase 1 contracts only**: the soulbound agent passport and the engagement/attestation layer. Both are **built and tested but not yet deployed to any public network**. There are no live addresses to review.

The `$COR` token contract is **not in this repository and not in this audit scope**. It is a separate BNB Smart Chain deployment at TGE. Nothing in the contracts under review holds, mints, transfers or prices a token.

---

## In Scope

| File | Lines | Priority |
|---|---|---|
| `contracts/CortisPassport.sol` | 160 | Critical |
| `contracts/CortisEngagement.sol` | 203 | Critical |

Out of scope: `scripts/`, `test/`, `flattened/`, and the frontend in `../app`. The frontend ABI in `../app/public/js/contracts.js` is provided only so auditors can confirm the interface matches the contracts.

---

## Toolchain

- Solidity `0.8.24`, optimizer enabled, 200 runs
- OpenZeppelin Contracts `^5.0.2` (note: v5, not v4 — `_update` hook, not `_beforeTokenTransfer`)
- Hardhat `^2.22.10`
- Target chain: opBNB Mainnet, chainId 204
- 21 tests, all passing (`npm test`)

`flattened/` holds single-file versions for explorer verification only. They inline all OpenZeppelin dependencies and are not for audit review; the Cortis logic is identical to `contracts/`.

---

## Design Intent (read before reviewing)

1. **Pre-TGE the contracts are gas-only.** No token, no fee, no stake, no payable function. The only cost to a user is opBNB gas.
2. **Sybil resistance pre-TGE is gas cost plus bound identity only.** There is no on-chain identity oracle. This is a known and accepted limitation, not an oversight.
3. **Passports are soulbound.** Transfers are blocked. Mint and burn are the only state transitions.
4. **Attestation is per-agent, not per-account.** `attestMap` and `attestWorkflow` require the caller to own the referenced passport. This is what makes reputation attach to a specific agent rather than a wallet.
5. **`setCorToken` is a reserved hook.** It stores an address and nothing else. It exists so post-TGE fee and stake modules can attach without redeploying the engagement contract. Confirm it has no reachable effect on any code path today.
6. **One wallet may hold many passports.** This is intentional: one passport per agent, several agents per owner.

---

## Key Security Properties to Verify

### CortisPassport

1. **Soulbound enforcement** — `_update` reverts when `from != address(0) && to != address(0)`. Verify no path allows a wallet-to-wallet transfer, including `safeTransferFrom` overloads, and that the OZ v5 `_update` override is the correct and complete interception point.
2. **Approvals disabled** — `approve` and `setApprovalForAll` revert unconditionally as `pure` overrides. Confirm this does not break ERC-721 interface detection in a way that matters, and that no internal OZ path depends on them.
3. **Per-owner count integrity** — `passportsOf` is incremented on mint and decremented on burn inside `_update`. Verify it cannot desynchronise from `balanceOf`, and that the decrement cannot underflow.
4. **Burn authorisation** — `burnPassport` checks `ownerOf(tokenId) != msg.sender`. Verify only the holder can burn and that burning cleans `agentIdOf` and the token URI.
5. **Token id monotonicity** — `_nextId` starts at 1 and only increments. Verify burned ids are never reissued and that `totalMinted()` correctly reports ever-minted rather than currently-held.
6. **`_safeMint` receiver callback** — `mintPassport` calls `_safeMint`, which invokes `onERC721Received` on contract recipients. State is written before the callback. Assess whether a reentrant call into `mintPassport` from that hook can produce any inconsistent state, even though the obvious outcome is only an additional mint.
7. **`tokenURI` is caller-supplied** — the minter, not the contract owner, sets the metadata URI at mint time, and it is stored verbatim with no validation. Confirm this cannot be used to break `tokenURI()` for other tokens, and flag any concern about arbitrary URI content.
8. **`agentId` is unvalidated and non-unique** — arbitrary caller-supplied string, no uniqueness constraint, no length bound. Flag gas or griefing implications of very long strings.

### CortisEngagement

1. **24h check-in gate** — first call is always allowed (`last == 0`); afterwards `block.timestamp < last + CHECK_IN_INTERVAL` reverts with `CheckInTooSoon`. Verify the gate cannot be bypassed.
2. **Streak correctness** — streak increments when `block.timestamp <= last + STREAK_RESET_GAP` (48h), otherwise resets to 1. Verify behaviour in the 24h-to-48h continuation window and at both exact boundaries, and that there is no cap on streak growth.
3. **Attestation ownership guard** — `_requireAgentOwner` reverts `PassportNotSet` when `passport == address(0)` and `NotAgentOwner` when the caller does not own the passport. Verify neither attestation function can write state or emit before the guard runs.
4. **External call surface** — the only external call is `passport.ownerOf(passportId)`, a view on a settable address. Assess what a malicious or misconfigured `passport` address could do: revert, consume gas, or return an attacker-chosen owner. Note that `setPassport` is owner-only and has no lock.
5. **Unbounded attestation** — `attestMap` and `attestWorkflow` have no rate limit and no per-day cap. A passport owner can call them repeatedly in one block and inflate `points` without bound. Confirm this affects only the points counter and creates no other risk. See "Intentional Design Decisions".
6. **Points arithmetic** — `points`, `streak` and `totalCheckIns` are plain `uint256` with no decimals and no cap. Verify no realistic overflow path, including via `setPoints` with extreme values.
7. **Owner config blast radius** — `setPoints` accepts arbitrary values with no bounds, and `setPassport` can be repointed at any time. Enumerate what an owner key compromise achieves. Note it cannot mint, burn, move a passport, or reduce an existing points balance.
8. **`corToken` is inert** — verify `corToken` is written by `setCorToken` and read nowhere, and that no branch in the contract depends on it.
9. **No value handling** — no function is `payable`, and there is no `receive` or `fallback`. Confirm the contract cannot custody or be drained of BNB, and consider whether the absence of an explicit reverting `receive()` matters for this deployment.

---

## Intentional Design Decisions (Not Bugs)

**No pause mechanism.** Neither contract is pausable. The contracts hold no funds and no token, and the worst outcome of abuse is inflated point counters in an off-chain-scored system. We judged the centralisation cost of a pause switch higher than the benefit at this phase. Flag it if you disagree, with reasoning.

**Permissionless minting with no supply cap.** Anyone can call `mintPassport` and mint unlimited passports for the cost of gas. Agent identity is meant to be free to create; scarcity lives in the private data and accumulated attestation history, not in the mint. Sybil filtering at any future snapshot is off-chain.

**Unlimited attestations per day.** Attestation frequency is deliberately uncapped because a productive agent may complete many pieces of work in a day. Raw `points` is therefore not a scarce or trustworthy standalone metric, and downstream scoring is expected to weight attestation content off-chain rather than count events. We would still like this called out explicitly if you see a consequence we have not.

**Points are not 18-decimal.** `points` is a plain integer counter, not ERC-20-style precision. It is an engagement signal, never a balance, and there is no path from points to a transferable asset in these contracts.

**Burn is allowed.** A holder may burn their own passport. Soulbound means non-transferable, not non-destructible. Burning is the exit path for a bound identity, and it deliberately does not refund, reverse or preserve anything.

**`totalMinted()` counts burned tokens.** It reports ever-minted, derived from `_nextId - 1`, and does not decrease on burn. Ids are never reused.

**`setCorToken` exists before the token does.** It is dead storage today by design, so that TGE does not require redeploying the engagement contract or migrating the points ledger.

---

## Known Limitations

- **No on-chain identity.** The contracts cannot distinguish one human with ten wallets from ten humans. Pre-TGE sybil resistance is gas cost plus the requirement to own a passport before attesting. Any snapshot-time filtering is off-chain cluster analysis.
- **`block.timestamp` dependence.** Used for the 24h check-in gate and the 48h streak window. opBNB sequencer timestamps can move within bounds; the windows are wide enough that minor manipulation yields no meaningful advantage.
- **No oracle, no price feed, no external protocol dependency.** All logic is self-contained apart from the `ownerOf` view on the passport contract.
- **Attested hashes are opaque on-chain.** The contracts store `bytes32` hashes and emit them. They prove that a specific passport owner committed to a specific value at a specific time. They do **not** prove the underlying work was correct, useful, or actually performed by an AI agent. That guarantee lives off-chain in the signed action log.
- **Ownership is a single key at deploy time.** The deploy script sets the deployer as owner. Transferring ownership to a multisig is a required post-deploy step, documented in `../DEPLOY-CHECKLIST.md`, not enforced in the contract. Note that `renounceOwnership` is **not** disabled; the inherited OpenZeppelin implementation is reachable. Flag this if you consider it a defect for this design.

---

## Listing Considerations

If any pattern here would cause a review team at Binance DappBay, opBNB ecosystem, or a CEX listing desk to flag or reject a submission, please note it explicitly even where it is not a traditional vulnerability. Specific things we want checked:

- No admin path that can drain user funds. The contracts never hold funds.
- No hidden mint or inflation mechanism in any token sense.
- No blacklist, no transfer tax, no owner-controlled transfer restriction beyond the blanket soulbound rule.
- No proxy, no upgradeability, no delegatecall. Both contracts are immutable once deployed.
- Contracts must verify cleanly on opBNBScan. Flattened sources are provided for that.

---

## Test Suite

21 tests. Run with:

```bash
npm install
npm test
```

Expected: `21 passing`.

Coverage: check-in first call, 24h revert, post-24h increment, 48h streak reset, per-wallet isolation, `timeUntilNextCheckIn` boundaries, both attestation happy paths, both attestation non-owner reverts, unset-passport revert, `setPoints` access control, `setCorToken` storage, `setPassport` access control, passport mint and event, multiple passports per wallet with incrementing ids, `transferFrom` revert, `safeTransferFrom` revert, `approve` and `setApprovalForAll` reverts, owner burn with count decrement, non-owner burn revert.

---

## Deployment Status

Nothing is deployed. There is no mainnet or testnet address to compare against. `deployment-addresses.json` is a template with null values and will be filled after the audited code is deployed.

---

## Questions

Any question about a design decision above, or about intent where the code is ambiguous, should be raised rather than assumed. We would rather answer a question than receive a finding based on a guess.
