# Contract Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                          OWNER                              │
│              (one wallet, several agents)                   │
└───────────┬─────────────────────────────────────────────────┘
            │
            │ mintPassport()          checkIn()
            │                        attestMap()
            │                        attestWorkflow()
            │                                │
   ┌────────▼──────────┐         ┌───────────▼──────────────┐
   │  CortisPassport   │◄────────│   CortisEngagement       │
   │                   │ ownerOf │                          │
   │ - mintPassport()  │         │ - checkIn()              │
   │ - burnPassport()  │         │ - attestMap()            │
   │ - totalMinted()   │         │ - attestWorkflow()       │
   │ - tokenURI()      │         │ - timeUntilNextCheckIn() │
   │                   │         │                          │
   │ agentIdOf[]       │         │ points[]                 │
   │ passportsOf[]     │         │ streak[]                 │
   │                   │         │ lastCheckIn[]            │
   │ ERC-721 soulbound │         │ totalCheckIns[]          │
   │ transfers revert  │         │ corToken (reserved)      │
   └───────────────────┘         └──────────────────────────┘
            │                                │
            └────────────┬───────────────────┘
                         │
            ┌────────────▼─────────────────────────────┐
            │       opBNB Mainnet (chainId 204)        │
            │   All events indexed and public          │
            └──────────────────────────────────────────┘

            ┌──────────────────────────────────────────┐
            │  BNB Smart Chain (chainId 56)            │
            │  $COR token — NOT in this repository,    │
            │  deployed separately at TGE              │
            └──────────────────────────────────────────┘
```

Two contracts. One directional dependency. No proxy, no upgradeability, no delegatecall, no external protocol.

---

## Contract Relationships

### CortisEngagement → CortisPassport

`CortisEngagement` holds a settable `ICortisPassport` reference and calls exactly one function on it:

```solidity
interface ICortisPassport {
    function ownerOf(uint256 tokenId) external view returns (address);
}
```

That single `view` call is the entire coupling. It runs inside `_requireAgentOwner`, which both attestation functions call before touching state:

```solidity
function _requireAgentOwner(uint256 passportId) internal view {
    if (address(passport) == address(0)) revert PassportNotSet();
    if (passport.ownerOf(passportId) != msg.sender) revert NotAgentOwner();
}
```

Consequences worth stating plainly:

- `checkIn()` does **not** require a passport. A wallet can check in from day one with no agent. Check-in is the wide-funnel action.
- Attestation **does** require passport ownership. That is what binds a piece of attested work to a specific agent rather than to a wallet.
- If `passport` is never set, attestation is unreachable and check-in still works. The contracts are independently deployable and the wiring is a post-deploy step.

`CortisPassport` has no reference to `CortisEngagement`. It does not know engagement exists. Passports remain valid and mintable if engagement is never deployed.

---

## CortisPassport

Soulbound ERC-721 on OpenZeppelin v5.

**Identity model.** One passport represents one agent. Minting is the act of committing an agent on-chain. A wallet may hold many passports, one per agent. `agentIdOf[tokenId]` stores a caller-supplied off-chain identifier such as `COR-AB12CD`.

**Soulbound enforcement.** OpenZeppelin v5 routes every mint, burn and transfer through `_update`. Cortis overrides it:

```solidity
function _update(address to, uint256 tokenId, address auth)
    internal override returns (address)
{
    address from = _ownerOf(tokenId);
    if (from != address(0) && to != address(0)) revert SoulboundNonTransferable();
    address previousOwner = super._update(to, tokenId, auth);
    if (from == address(0)) passportsOf[to] += 1;        // mint
    else if (to == address(0)) passportsOf[from] -= 1;   // burn
    return previousOwner;
}
```

Mint has `from == address(0)`. Burn has `to == address(0)`. Anything else has both non-zero and reverts. Because `_update` is the single chokepoint in v5, every transfer overload is covered by one guard. `approve` and `setApprovalForAll` are additionally overridden to revert as `pure` functions, since their only purpose is enabling transfers.

**State transitions.** Only two:

```
        mintPassport()                    burnPassport()
  ∅ ──────────────────────► HELD ──────────────────────► BURNED
                              │
                              │ transferFrom / safeTransferFrom
                              └──────────► revert SoulboundNonTransferable
```

Burn is holder-only and clears `agentIdOf` and the stored URI. Ids come from `_nextId`, which starts at 1 and only increments, so burned ids are never reissued. `totalMinted()` returns `_nextId - 1`, meaning ever-minted, and does not decrease on burn.

---

## CortisEngagement

Gas-only engagement ledger. No `payable` function, no `receive`, no `fallback`. The contract cannot custody value.

### Check-in state machine

```
CHECK_IN_INTERVAL = 24 hours
STREAK_RESET_GAP  = 48 hours

first call (lastCheckIn == 0)
  └─► always allowed, streak = 1

subsequent call at time t, previous at time L
  ├─ t <  L + 24h  ─► revert CheckInTooSoon(L + 24h)
  ├─ t <= L + 48h  ─► streak += 1        (continuation window)
  └─ t >  L + 48h  ─► streak  = 1        (reset)
```

The valid continuation window is therefore 24h to 48h after the previous check-in. Miss it and the streak restarts. Streak has no cap.

Points on check-in:

```
gained = checkInPoints + (streak * streakBonus)
```

Defaults are `checkInPoints = 10` and `streakBonus = 2`, both owner-settable via `setPoints`. Because the bonus multiplies the current streak, a maintained streak compounds. Nothing decays and nothing is ever subtracted.

### Attestation

Two functions, identical shape, different semantic:

| Function | Argument | Meaning |
|---|---|---|
| `attestMap(passportId, mapHash)` | `keccak256` of the generated map JSON | the agent's context/knowledge map at a point in time |
| `attestWorkflow(passportId, workflowHash)` | `keccak256` of the workflow definition | a completed piece of agent work |

Both require passport ownership, add flat points, and emit the hash with a timestamp. Neither is rate-limited: a productive agent may attest many times a day, so raw `points` is an engagement signal rather than a scarce metric. Downstream scoring weights attestation content off-chain.

Only hashes reach the chain. No prompts, no outputs, no PII, no embeddings. An observer sees that a specific passport owner committed to a specific 32-byte value at a specific time, and nothing about what the value contains.

### What an attestation proves, and does not

Proves: a wallet that owned passport `N` at block time `T` committed to hash `H`, publicly and immutably.

Does not prove: that the underlying work was correct, useful, or produced by an AI agent at all. The contract has no view into the content. That guarantee lives in the off-chain signed action log whose hash is what gets attested.

---

## On-chain vs off-chain split

| Data | Location | Reason |
|---|---|---|
| Agent identity, ownership | on-chain | must be publicly verifiable and non-transferable |
| Check-in timestamps, streak, points | on-chain | the engagement record is the point |
| Map and workflow hashes | on-chain | immutable commitment with a timestamp |
| Agent prompts, outputs, action logs | off-chain | private to the owner; only the hash is published |
| Owner private data, embeddings, knowledge graph | off-chain | never leaves owner control; this is the product moat |
| Reputation score | off-chain, derived | computed from on-chain events plus content weighting |

---

## Access Control

Both contracts use OpenZeppelin `Ownable` with the owner set in the constructor.

| Function | Contract | Access | Effect |
|---|---|---|---|
| `mintPassport` | Passport | anyone | mint a passport to self |
| `burnPassport` | Passport | holder only | burn own passport |
| `checkIn` | Engagement | anyone | daily check-in |
| `attestMap` / `attestWorkflow` | Engagement | passport owner | write a hash |
| `setPoints` | Engagement | owner | change point values |
| `setPassport` | Engagement | owner | repoint the passport reference |
| `setCorToken` | Engagement | owner | store the future token address |

What the owner key **cannot** do: mint, burn or move a passport, reduce an existing points balance, withdraw anything, pause anything, or upgrade logic. There is no pause mechanism and no proxy by deliberate choice.

What the owner key **can** do: set arbitrary point values for future actions, and repoint `setPassport` at another address, which would change which contract the ownership check reads from. `setPassport` has no lock. Ownership transfer to a multisig after deploy is handled from the private repository, not enforced in code.

---

## TGE-additive design

`corToken` is a stored address, default `address(0)`, written only by `setCorToken` and read nowhere in the contract. It is inert storage today.

It exists so that post-TGE fee, stake and reward modules can attach without redeploying `CortisEngagement` and without migrating the accumulated points ledger. The pre-TGE engagement history stays continuous across TGE, which matters because that history is the input to any later reward weighting.

The pre-TGE loop never depends on the token. $COR is additive on top of the same actions, never a gate on them.

---

## Chain split

| Component | Chain | Rationale |
|---|---|---|
| `CortisPassport`, `CortisEngagement` | opBNB, 204 | near-zero gas makes a daily on-chain transaction per user viable at scale |
| `$COR` token | BSC, 56 | liquidity and listing venue; deployed separately at TGE, not in this repository |

The engagement contracts stay on opBNB permanently. The cross-chain entitlement pattern for post-TGE $COR reads is a separate design decision and is not implemented here.

---

## Deployment order

1. Deploy `CortisPassport(initialOwner)`.
2. Deploy `CortisEngagement(initialOwner)`.
3. Call `engagement.setPassport(passportAddress)`.
4. Transfer ownership of both contracts to the multisig.

Deployment wires the passport into the engagement contract via `setPassport`, then ownership is transferred to a multisig. Both steps are handled from the private repository and are outside this review.

Until step 3 runs, attestation reverts with `PassportNotSet` while check-in works normally.
