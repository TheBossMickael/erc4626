# Invariants & Testing

The properties the system must uphold at all times, and how the 77-test
Foundry suite actually proves them. The guiding principle: **structural
enforcement beats checked enforcement** — an invariant that *cannot* be
violated by any code path (one price per epoch, escrowed pending funds) is
worth more than one that is merely asserted. The tests then verify that the
structure delivers what it promises.

## The nine invariants

### I1 — Epoch price uniqueness (the core invariant)

> Every request fulfilled in epoch N converts at exactly the same
> assets/shares rate, regardless of when in the epoch it was submitted.

For all users u, v with deposit pendings in epoch N:
`entitlement(u) / pending(u) == entitlement(v) / pending(v)` up to the 1-wei
pro-rata floor. Same on the redeem side. This is ERC-7540's
fungible-requestId requirement, satisfied structurally: one fulfillment
transaction, one price, pro-rata splits against the recorded batch result.
**Tested:** at every fulfillment inside the invariant campaign, the handler
measures each actor's entitlement as the **delta of the `maxMint`/
`maxWithdraw` views across `fulfillEpoch()`** and asserts pairwise rate
equality with a cross-product bound
(`|e_i·p_j − e_j·p_i| < max(p_i, p_j)` ⇔ identical rate up to 1 wei of
floor, whatever the amounts).

### I2 — No value leakage across users (conservation per epoch)

> The sum of individual entitlements never exceeds what the batch produced.

For every fulfilled epoch N: `Σ depositEntitlements ≤ sharesMinted`,
`Σ redeemEntitlements ≤ assetsSetAside`, and the dust
(`batch − Σ entitlements`) is unclaimable and strictly less than one wei
per requester.
**Enforced** by pro-rata floor division against batch totals.
**Tested:** summed at every fulfillment and re-checked against per-epoch
ghost snapshots by the global invariant function.

### I3 — NAV-per-share continuity across fulfillment

> Fulfilling an epoch neither dilutes nor enriches existing holders.

Price per share immediately after `fulfillEpoch()` equals the struck price
within rounding dust, and the dust direction always favors remaining
holders (never the exiting/entering batch).
**Tested twice:** asserted around every fulfillment in the campaign
(`p_after ≥ p_before`, drift bounded by a dust term), and unit-fuzzed over
random epoch compositions — deposit-heavy, redeem-heavy, netted, one-sided,
empty (`testFuzz_fulfillEpoch_priceContinuity`).

### I4 — Escrow solvency & exactness

> The escrow holds exactly what is owed, at all times.

- escrow USDC `==` Σ pending deposit assets + Σ unclaimed redeem payouts
  + accumulated payout dust
- escrow shares `==` Σ pending redeem shares + Σ unclaimed deposit shares
  + accumulated share dust

**Equality, not `≥`** — drift in either direction signals a bug (leak or
double-count). Dust accrues on *both* sides and the ghost accounting tracks
it explicitly so the equality stays exact.
**Tested:** `invariant_I4_escrowSolvencyExact`, re-checked after every
campaign action.

### I5 — Supply discipline

> `totalSupply()` of the share changes only inside `fulfillEpoch()`.

Requests move existing shares to escrow; cancels move them back; claims
move them out — only fulfillment mints (deposit batch) or burns (redeem
batch).
**Tested:** supply is snapshotted around **every** non-fulfill action
(strict equality), and the settlement delta is asserted to be exactly
`sharesMinted − totalRedeemShares`.

### I6 — Pending isolation

> Submitting or cancelling requests never moves the share price.

The observable proof that pending funds sit outside `totalAssets()` — the
escrow architecture (D9) at work, and the mitigation of threat T2.
**Tested:** price per share snapshotted around every request/cancel/claim
(strict equality — same-timestamp calls, the oracle cannot move).

### I7 — No double-claim

> A controller can never extract more than their fulfilled entitlement,
> across any interleaving of lazy rolls, claims, and new requests.

The lazy roll frees the pending slot atomically with crediting the
claimable ledger; claims decrement before transfer.
**Tested:** lifetime per-controller ghost ledgers (entitled vs paid, both
denominations), asserted globally after every action.

### I8 — Access control

> Privileged surfaces are unreachable without the role.

`closeEpoch`/`fulfillEpoch`/`invest`/`divest`: `MANAGER_ROLE` only. Escrow
movements: vault only. Oracle knobs: owner only. Acting on someone else's
requests/claims: that controller's ERC-7540 operator only — including the
subtleties: the ERC-20 allowance path of `requestRedeem` (spent for third
parties, skipped for operators, infinite allowance not consumed) and claim
events keyed on the controller.
**Tested:** a dedicated unit matrix (14 tests) covering stranger *and*
admin-without-manager-role callers — proving the D10 role separation, not
just "some access control exists".

### I9 — State-machine sanity

> Epoch transitions are monotonic and unique.

Exactly one OPEN epoch; at most one CLOSED epoch; `closeEpoch(N+1)`
impossible before `fulfillEpoch(N)`; a FULFILLED epoch's recorded batch
results are immutable.
**Tested:** `invariant_I9_epochStateMachine` walks every epoch after every
action and compares fulfilled epochs against snapshots taken at
fulfillment time (immutability), re-asserting I2 on the stored sums. Unit
tests cover each illegal transition explicitly.

## How the invariant campaign works

`test/invariant/Handler.sol` + `RWAVault.invariants.t.sol`, run at 64
campaign runs × 128 calls deep, over 14 fuzzed actions: both requests, both
cancels, all four claim functions, `closeEpoch`, `fulfillEpoch`, time warps
(up to 6 h ≈ 360 simulated days at scale 1440), ±20% NAV shocks, `invest`,
`divest`. Three design choices make the campaign meaningful rather than
decorative:

- **`fail-on-revert = true`.** The handler guards each action's
  preconditions and no-ops when an action is illegal, so *any* revert
  reaching the runner is a finding in itself — the suite cannot silently
  spin on reverting calls.
- **Black-box ghost accounting.** Entitlements are measured as the deltas
  of the vault's own `max*` views across `fulfillEpoch()` — never
  recomputed from the vault's formulas. The invariants compare the
  implementation against itself across time; a copy-pasted formula would
  just verify that the bug is reproducible.
- **Eager ghost roll vs lazy contract roll.** The ghosts roll entitlements
  at fulfillment while the contract rolls lazily — legitimate, because the
  escrow-level identity checked by I4 (pendings + unclaimed + dust) is
  invariant to *when* the roll happens. This is itself a statement about
  the design: lazy settlement changes gas timing, not accounting.

## Test suite map

74 unit tests + 3 global invariant properties = **77 green**.

| File | Focus |
|---|---|
| `unit/RequestLifecycle.t.sol` (21) | request/aggregate/cancel in every epoch state, the CLOSED-window busy slot, auto-roll on new requests, exact-`requestId` pending views, price isolation |
| `unit/EpochLifecycle.t.sol` (14) | legal & illegal transitions, empty epochs, first-epoch par pricing, netting, the insufficient-cash revert until `divest`, invest/divest NAV-neutrality, fuzzed price continuity (I3) |
| `unit/Claims.t.sol` (18) | full-claim exactness, partial-claim rounding per function (floor out / ceil consumed), multi-epoch aggregation at different rates, third-party receivers, fuzzed partial-claim splits |
| `unit/AccessControlMatrix.t.sol` (14) | I8 exhaustively — roles, escrow, oracle, operator vs allowance paths, controller-keyed events |
| `unit/InflationAttack.t.sol` (3) | first-depositor grief under OZ's offset + batch pricing (T6), donation effects |
| `unit/ERC165.t.sol` (4) | the four EIP interface ids, inherited surface (ERC-165 + AccessControl), negatives, `share() == vault` |
| `invariant/RWAVault.invariants.t.sol` (3) | I4 exact escrow solvency, I7 lifetime no-double-claim, I9 state machine + I2 re-checks — with I1/I3/I5/I6 asserted inside the handler at every step |

```bash
cd contracts && forge test        # runs everything, ~seconds
```
