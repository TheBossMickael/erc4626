# Threat Model

Scope: the on-chain system (`RWAVault`, `Escrow`, `NAVOracle`, mocks). The
frontend and deployment keys are out of scope except where noted. This is a
**simulator**: some trust assumptions are deliberate simplifications of
production infrastructure and are labeled as such.

## Actors & trust assumptions

| Actor | Trust level | Powers | Notes |
|---|---|---|---|
| Investor | untrusted | request, cancel (pre-cut-off), claim, delegate to 7540 operators | the adversary of interest |
| 7540 operator | trusted *by their controller only* | act on behalf of one user | scoped by `setOperator` |
| Fund manager (`MANAGER_ROLE`) | trusted for **liveness and timing**, not pricing | `closeEpoch`, `fulfillEpoch`, `invest`, `divest` | cannot set prices: NAV = oracle + accounting. Mirrors a real transfer agent |
| Oracle admin | trusted | rate, time scale, mark-to-market shocks | simulator stand-in for the fund accountant / custodian NAV feed |
| Deployer / admin | trusted | role management | demo-grade key handling |

## Threats & mitigations

### T1 — Intra-epoch timing advantage (the core threat)
*A user requests late in the epoch, after observing NAV drift, to get a
better rate than earlier requesters of the same cycle.*
**Mitigation — structural:** one price per epoch, struck at fulfillment,
applied pro-rata to the whole batch (D4/D6). There is no code path that can
price two same-epoch requests differently. Fuzzed as invariant I1.

### T2 — Pending cash inflating the NAV (self-dealing dilution)
*Deposit requests sit in the vault's balance and count in `totalAssets()`,
inflating the price the same depositors will pay — or diluting others.*
**Mitigation — structural:** pending funds live in `Escrow`, a separate
contract; `totalAssets()` cannot see them (D9). Verified by invariant I6
(requests/cancels never move the share price).

### T3 — Rounding leakage
*Accumulated rounding across batch → per-user splits mints more than the
batch or pays out more than set aside.*
**Mitigation:** all divisions floor in the vault's favor; per-user
entitlements are pro-rata against the *recorded batch result*, so
`Σ user claims ≤ batch` holds term by term (invariant I2). Dust is
unclaimable and bounded by 1 wei per user per epoch.

### T4 — Cancellation timing (loss dodging)
*NAV drops between request and settlement; the user cancels to dodge a loss
that committed investors absorb.*
**Mitigation:** cut-off (D5/D7). Cancels revert once the epoch is CLOSED;
oracle shocks landing between cut-off and fulfillment hit binding orders —
the same rule that protects real funds. Residual: shocks during the OPEN
phase can be dodged by cancelling; true in real funds too (pre-cut-off
orders are free to cancel). Accepted.

### T5 — Manager discretion
*The manager times `closeEpoch`/`fulfillEpoch` while observing flows and
NAV, or simply stops turning the cycle (funds stuck in CLOSED).*
**Accepted trust assumption** — this *is* the institutional model: the
transfer agent controls the cycle but not the price. Production hardening
(out of scope V1): scheduled cut-offs, permissionless fulfillment after a
timeout, manager under multisig/timelock.

### T6 — First-depositor / inflation attack
*Classic 4626 grief: donate to skew the initial exchange rate.*
**Mitigation:** OZ's virtual-shares decimal offset (inherited, D1); batch
pricing further blunts it (an attacker cannot sandwich an individual victim
— the whole epoch shares one rate). Unit-tested on the first epoch.

### T7 — Direct donations to the vault (USDC or TBILL)
*Transfer tokens straight to the vault to move `totalAssets()`.*
Moves the NAV for *everyone, between epochs* — economically a gift to
current holders, no intra-epoch discrimination possible (T1 mitigation
covers it). Accepted and documented; escrow balances are unaffected.

### T8 — Reentrancy
Demo tokens (MockUSDC, TBILL, the share) have no transfer hooks, so there is
no reentrant path in-model. Defense in depth anyway: checks-effects-
interactions ordering everywhere; `nonReentrant` on external functions that
move funds (requests, cancels, claims, fulfillment) — the vault must stay
safe if someone wires a hooked ERC-20 (e.g. ERC-777-style) into a fork.

### T9 — Denial of service
No unbounded loops exist: fulfillment is O(1) regardless of request count
(D4), settlement is lazy per-user. Spamming tiny requests costs only the
spammer. The single-pending-slot rule bounds per-user storage to O(1).

### T10 — Oracle manipulation
In the simulator the oracle admin is trusted (T5-like assumption). In
production this surface is the critical one for any RWA fund: signed NAV
feeds from the fund accountant, staleness checks, deviation bounds between
consecutive NAVs, and a dispute window would replace the admin-set price.
Listed as the #1 production-hardening item.

### T11 — Escrow custody
Escrow funds move only on `RWAVault`'s instruction (`onlyVault`); the escrow
has no other external surface. Access-control tested (I8). The escrow holds
exactly the sum of outstanding pendings and unclaimed claimables (I4) — any
drift is a red flag caught by the solvency invariant.

## Residual risks (accepted, V1)

1. Manager liveness: CLOSED epoch never fulfilled → pendings locked until
   fulfillment (T5). Demo-acceptable; hardening listed.
2. Pre-cut-off cancel freedom mirrors real funds (T4 residual).
3. Simulated oracle: no staleness/deviation guards (T10).
4. Demo key management: single EOA may hold several roles.
