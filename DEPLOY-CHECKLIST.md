# Cortis On-Chain — Deploy Checklist (opBNB, chainId 204)

The engagement + passport contracts are **built, tested, and NOT deployed**.
Follow this to deploy them to opBNB mainnet and wire the frontend.

> Cortis is separate from any other product. These are a fresh, standalone
> contract set. No external contracts/addresses are reused.

---

## 0. What gets deployed

| Contract | Purpose |
|----------|---------|
| `CortisPassport` | Soulbound ERC721. One passport per agent, bound to the minting wallet. Minting = "deploy the agent". |
| `CortisEngagement` | Daily check-in (DAU driver) + per-agent Map/Workflow attestations. Points/streak on-chain. |

Deploy order: **Passport first**, then **Engagement**, then `engagement.setPassport(passportAddr)` (the deploy script does all three).

---

## 1. Prerequisites

- A deployer wallet **funded with a small amount of opBNB BNB** for gas (bridge BNB from BSC to opBNB via the official opBNB bridge). A few dollars of BNB is plenty; opBNB gas is tiny.
- The deployer's **private key** (never commit it).
- Node + the local toolchain already installed in `contracts/` (`npm install` has been run).

---

## 2. Environment variables

Create `contracts/.env` (git-ignored):

```
DEPLOYER_PRIVATE_KEY=0xYOUR_FUNDED_DEPLOYER_KEY
OPBNB_RPC=https://opbnb-mainnet.nodereal.io/v1/YOUR_NODEREAL_KEY
# public fallback if the NodeReal key is rate-limited:
# OPBNB_RPC=https://opbnb-mainnet-rpc.bnbchain.org
OPBNBSCAN_API_KEY=your_bscscan_opbnb_key   # only needed for verification
```

- `DEPLOYER_PRIVATE_KEY` — funded opBNB account. **Required.** Never hardcoded anywhere.
- `OPBNB_RPC` — defaults to the public `https://opbnb-mainnet-rpc.bnbchain.org` if unset.
- `OPBNBSCAN_API_KEY` — a BscScan/opBNBScan API key, only for the verify step.

---

## 3. Sanity check locally (no mainnet, free)

```
cd contracts
npx hardhat compile      # clean
npx hardhat test         # 21 passing
npx hardhat run scripts/deploy.js   # deploys to in-memory hardhat net, prints addresses
```

---

## 4. Deploy to opBNB mainnet

```
cd contracts
npx hardhat run scripts/deploy.js --network opbnb
```

The script:
1. Deploys `CortisPassport(deployer)`.
2. Deploys `CortisEngagement(deployer)`.
3. Calls `engagement.setPassport(passportAddr)`.
4. Writes addresses to `contracts/deployments/opbnb.json` and prints the paste block.

Copy the two printed addresses.

---

## 5. Verify on opbnbscan (optional but recommended)

```
npx hardhat verify --network opbnb <PASSPORT_ADDR> "<DEPLOYER_ADDR>"
npx hardhat verify --network opbnb <ENGAGEMENT_ADDR> "<DEPLOYER_ADDR>"
```

Both constructors take a single `initialOwner` address argument (the deployer).
Browse the verified contracts at `https://opbnb.bscscan.com/address/<ADDR>`.

If `hardhat verify` fails, verify manually on the explorer using the single-file
sources in `flattened/`. Compiler `0.8.24`, optimizer enabled, 200 runs.

---

## 6. Transfer ownership to the multisig (REQUIRED)

The deploy script leaves the deployer EOA as owner of both contracts. Do not
leave it there. Transfer both to the multisig, then discard the deployer key.

```
passport.transferOwnership(<OWNER_SAFE>)
engagement.transferOwnership(<OWNER_SAFE>)
```

Confirm `owner()` on both returns the Safe before announcing anything.

The owner key cannot mint, move or burn a passport, cannot reduce a points
balance, and cannot withdraw anything (the contracts never hold value). It can
set point values and repoint `setPassport`. That is why it belongs behind a Safe.

Note: `renounceOwnership` is **not** disabled. Do not call it.

Record the final addresses, deployer, owner and timestamp in
`deployment-addresses.json`.

---

## 7. Wire the frontend

Edit `app/public/js/contracts.js` → `window.CORTIS_ADDRESSES`:

```js
window.CORTIS_ADDRESSES = {
  passport:   "0x...PASSPORT_ADDR...",
  engagement: "0x...ENGAGEMENT_ADDR...",
};
```

That's the only change. As soon as both are real (non-zero), the frontend
stops showing "contracts not yet deployed" and the four actions fire real
MetaMask transactions on opBNB:

- **Check In** → `engagement.checkIn()`
- **Deploy Agent** → `passport.mintPassport(agentId, uri)` (soulbound mint)
- **Map me → Attest map** → `engagement.attestMap(passportId, keccak256(mapJSON))`
- **Generate workflow / Deploy Workflow** → `engagement.attestWorkflow(passportId, keccak256(workflowDef))`

Restart `node app/server.js` (port 3880) — nothing else to change server-side;
it already stores the real `{ txHash, passportId, chainId:204 }` posted by the UI.

---

## 8. Post-deploy tuning (optional, owner-only)

From the deployer wallet you can adjust point values without redeploying:

```
engagement.setPoints(checkInPoints, streakBonus, attestMapPoints, attestWorkflowPoints)
```

Defaults: `checkIn=10`, `streakBonus=2`, `attestMap=5`, `attestWorkflow=5`.

---

## 9. TGE note (later, do NOT do now)

`CortisEngagement.corToken` defaults to `address(0)`. Post-TGE, the $COR token
(on BSC) address can be set via `setCorToken(...)` and fee/stake/reward hooks
attach around the existing actions **without redeploying** the core contracts.
No token logic exists pre-TGE — this is gas-only.

---

## Sybil / security notes

- Pre-TGE sybil resistance = **gas cost + bound on-chain identity** (soulbound passport) only. No token gate.
- Passports are non-transferable: transfers, `approve`, and `setApprovalForAll` all revert. Owner may `burnPassport` their own token.
- `attestMap` / `attestWorkflow` require the caller to own the referenced `passportId` (checked via `CortisPassport.ownerOf`).
- Check-in is wallet-scoped and rate-limited to one per rolling 24h on-chain; the streak resets after a >48h gap.
