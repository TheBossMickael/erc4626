# Invariants

The properties the system must uphold at all times, each mapped to how it is
enforced (structurally, by construction) and how it is tested (Foundry
invariant/fuzz campaigns in `test/invariant/`, unit fuzz in `test/unit/`).
Structural enforcement is preferred: an invariant that *cannot* be violated
by any code path beats one that is merely checked.

## I1 — Epoch price uniqueness (the core invariant)

> Every request fulfilled in epoch N converts at exactly the same
> assets/shares rate, regardless of when in the epoch it was submitted.

For all users u, v with deposit pendings in epoch N:
`claim(u) / pending(u) == claim(v) / pending(v)` (up to 1 wei of floor
rounding). Same for redeem pendings. This is ERC-7540's fungible-requestId
requirement, satisfied structurally: one fulfillment transaction, one price,
pro-rata splits against the recorded batch result.
**Test:** invariant campaign with randomized actors/amounts/timing inside an
epoch; assert pairwise rate equality on claims after fulfillment.

## I2 — No value leakage across users (conservation per epoch)

> The sum of individual entitlements never exceeds what the batch produced.

For every fulfilled epoch N:
- `Σ_u depositClaim_u(N) ≤ epochs[N].sharesMinted`
- `Σ_u redeemClaim_u(N) ≤ epochs[N].assetsSetAside`
- dust `= batch − Σ claims` is unclaimable and `< number of requesters` (wei).

**Enforcement:** pro-rata floor division against batch totals.
**Test:** invariant campaign summing all claims per epoch vs recorded batch.

## I3 — NAV-per-share continuity across fulfillment

> Fulfilling an epoch neither dilutes nor enriches existing holders.

`pricePerShare` immediately after `fulfillEpoch()` equals the price struck in
step 1, within rounding dust — and the dust direction always favors remaining
holders (never the exiting/entering batch).
**Test:** unit fuzz over random epoch compositions (deposit-heavy,
redeem-heavy, netted, one-sided, empty); compare price before/after.

## I4 — Escrow solvency & exactness

> The escrow holds exactly what is owed, at all times.

- `USDC.balanceOf(escrow) == Σ open/closed pending deposit assets
  + Σ unclaimed claimableAssets`
- `vault.balanceOf(escrow) == Σ open/closed pending redeem shares
  + Σ unclaimed claimableShares` (+ accumulated dust)

Equality, not `≥`: any drift in either direction signals a bug (leak or
double-count).
**Test:** ghost-variable accounting in the invariant handler; checked after
every action.

## I5 — Supply discipline

> `totalSupply()` of the share changes only inside `fulfillEpoch()`.

Requests move existing shares to escrow; cancels move them back; claims move
them out of escrow — only fulfillment mints (deposit batch) or burns (redeem
batch).
**Test:** invariant — record supply before/after every non-fulfill action.

## I6 — Pending isolation

> Submitting or cancelling requests never moves the share price.

`pricePerShare` is unchanged by `requestDeposit`, `requestRedeem`,
`cancelDepositRequest`, `cancelRedeemRequest`. This is the observable proof
that pending funds sit outside `totalAssets()` (escrow architecture, T2).
**Test:** invariant — price recorded before/after every request/cancel.

## I7 — No double-claim

> A controller can never extract more than their fulfilled entitlement,
> across any interleaving of lazy rolls, claims, and new requests.

Lifetime `claimed_u ≤ Σ` over fulfilled epochs of `entitlement_u`. The lazy
roll frees the pending slot atomically with crediting claimables; claims
decrement claimables before transfer.
**Test:** invariant campaign with aggressive interleaving (request → fulfill
→ partial claim → new request → fulfill → claim rest), ghost accounting of
entitlements.

## I8 — Access control

> Privileged surfaces are unreachable without the role.

- `closeEpoch`, `fulfillEpoch`, `invest`, `divest`: `MANAGER_ROLE` only.
- Escrow movements: vault only.
- Oracle rate/scale/shocks: oracle admin only.
- Requests/claims on behalf of a user: that user's 7540 operator only
  (spec caller rules, including the ERC-20 allowance path of
  `requestRedeem`).

**Test:** unit tests, exhaustive unauthorized-caller matrix.

## I9 — State-machine sanity

> Epoch transitions are monotonic and unique.

Exactly one OPEN epoch at all times; at most one CLOSED epoch;
`closeEpoch(N+1)` impossible before `fulfillEpoch(N)`; a FULFILLED epoch is
immutable (its recorded batch results never change).
**Test:** invariant — state flags checked after every action; unit tests on
illegal transitions.
