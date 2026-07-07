# RWA Vault — Design Decisions

Status: **validated 2026-07-07**. Every decision below was discussed with its
alternatives before any code was written. This file is the single source of
truth for *what* was decided and *why*; `erc7540-architecture.md` covers *how*
the mechanics work in detail.

## Context

Institutional funds (money-market funds, tokenized T-Bill products) do not
settle instantly: subscriptions and redemptions are collected until a cut-off,
priced at a NAV computed after the cut-off (*forward pricing*), and settled
T+1/T+2 by a transfer agent. This simulator reproduces that lifecycle on-chain
with one vault that is ERC-4626 at its accounting core and ERC-7540 at its
interaction surface.

### Goals
- Faithful institutional settlement model: epochs, cut-off, manual fulfillment.
- Strict fairness: one NAV per epoch, zero timing advantage within an epoch.
- Standards-first: OZ ERC-4626 inherited, ERC-7540/7575 implemented per spec.

### Non-goals (V1)
- Partial/pro-rata fulfillment, fees, KYC/transfer restrictions, multi-asset
  ERC-7575 pools, permissionless fulfillment. Listed in [Evolutions](#evolutions).

## Decision log

### D1 — Single vault, OZ ERC-4626 base, minimal overrides
One contract inherits OpenZeppelin `ERC4626` and adds the 7540 layer. OZ's
share/asset accounting, ERC20 share token, decimal-offset inflation-attack
mitigation and `convertTo*` math are **never reimplemented**. Entry points are
overridden only where ERC-7540 mandates it: since both flows are async (D2),
`deposit`/`mint`/`withdraw`/`redeem` become claim functions and all four
`preview*` revert. `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem` reflect the
controller's claimable amounts.
*Rejected:* two separate vaults (sync + async) — splits liquidity and
accounting for no benefit; custom 4626 — reimplementing an audited standard
adds risk and proves nothing.

### D2 — Fully asynchronous: deposits AND redemptions
Both directions go through request → fulfill → claim.
*Why:* forward pricing in both directions is the anti-dilution mechanism of
real funds — nobody transacts at a price they could observe in advance.
*Rejected:* sync deposit + async redeem (common in some T-Bill tokens) —
better entry UX but exposes deposit-timing games against discrete NAV moves,
and halves the pedagogical surface of the project.

### D3 — Portfolio model: cash + mock T-Bill priced by the NAV oracle
The vault holds the asset (`MockUSDC`, 6 decimals) and a mock security
(`TBillToken`) whose USDC price comes from `NAVOracle`.
`totalAssets() = cash + tbillBalance × price`. The manager invests idle cash
into T-Bills and divests to fund redemptions (mock primary market at oracle
price; the mock issuer pays principal + accrued interest at divestment, the
way a maturing T-Bill does).
*Why:* this is how a real fund is structured (securities in portfolio, an
oracle/accountant pricing them), it makes solvency invariants exact, and it
*narratively justifies* async redemptions: selling T-Bills settles T+1.
*Rejected:* virtual accrual index over principal (yield "appears from
nowhere", vault balance no longer the source of truth); direct
price-per-share oracle (bypasses OZ accounting, contradicts D1).

### D4 — Epoch batch queue, O(1) fulfillment, lazy per-user settlement
Requests aggregate per epoch: `totalDepositAssets` / `totalRedeemShares` plus
a per-user amount. Fulfillment prices and settles **the whole batch in O(1)**;
individual entitlements are computed lazily (pending → claimable roll) at each
user's next touchpoint, using the recorded epoch rate.
*Why:* one price per epoch is guaranteed *by construction*; no unbounded
loops, no spam-DoS on fulfillment.
*Rejected:* individual FIFO queue — O(n) fulfillment, and same-price-per-epoch
stops being structural the moment fulfillment spans several transactions.
*Consequence (single pending slot):* each user has one pending slot per
direction. A new request auto-rolls a fulfilled previous pending into
claimable; it **reverts** if the previous pending sits in a closed-but-not-yet
-fulfilled epoch (narrow window between cut-off and settlement). Bounded
storage, no epoch enumeration. A two-slot variant is a possible evolution.

### D5 — Two-phase epoch lifecycle: Open → Closed → Fulfilled
`closeEpoch()` is the cut-off: requests of epoch N become **binding** and
epoch N+1 opens immediately for new requests. `fulfillEpoch()` settles epoch N
at the NAV struck at that moment (forward pricing: real funds compute NAV
after the cut-off). `closeEpoch()` for N+1 reverts until N is fulfilled — at
most one epoch awaits settlement at any time.
*Why:* reproduces the real cut-off/settlement split, gives the frontend a
visible "settlement in progress" state, and neutralizes cancellation-timing
games (D7).
*Rejected:* single-phase (close = fulfill) — simpler but leaves cancellation
open until the last second, unsafe combined with downward NAV shocks (D8);
time-based automatic cut-offs — contradicts the manual transfer-agent model.

### D6 — One NAV snapshot per epoch, atomic two-sided fulfillment
A single `fulfillEpoch()` call prices deposits and redemptions of the epoch
with **one** price read, and nets flows at the portfolio level (subscription
cash funds redemption payouts; only the net moves the portfolio).
*Why:* real funds execute both sides of the same cut-off at the same NAV; two
separate fulfillment transactions would read two different NAVs (accrual is
time-based) and leak value between the two sides of the same epoch.
*Rejected:* separate deposit/redeem prices — an anti-pattern here; differing
*claim availability* delays (subscriptions T+1 vs redemptions T+3) would be
modeled as same price + different claim delays, deferred as an evolution.

### D7 — Cancellation: synchronous, only while the epoch is Open
`cancelDepositRequest()` / `cancelRedeemRequest()` refund the full pending
amount instantly while the user's epoch is Open; after cut-off the order is
binding, as in a real fund. Cancellation is full (no partial cancel in V1).
*Standard status:* core ERC-7540 leaves cancellation explicitly out of scope.
[ERC-7887](https://eips.ethereum.org/EIPS/eip-7887) (Draft) standardizes
*asynchronous* cancellation for cases where settlement is in flight
(cross-chain, long-dated RWAs). Our settlement is atomic on one chain, so
synchronous pre-cut-off cancellation is safe; the divergence is deliberate
and documented in `erc7540-architecture.md`.

### D8 — Demo cadence and NAV oracle behavior
No on-chain minimum epoch duration: the cycle is purely manager-driven
(realistic values — daily cut-off, T+1/T+2 — are documented here, not
enforced). `NAVOracle` provides: configurable annualized rate; a **time-scale
factor** (e.g. 1 real minute = 1 simulated day) so accrual is visible in a
live demo — 4.5% APR over 5 real minutes is otherwise a flat line; optional
manual mark-to-market shocks (rate moves) injected by the oracle admin.
Shocks between cut-off and fulfillment hit committed investors — exactly like
a real fund, and safe because of D5/D7.

### D9 — requestId = epochId, custody in a separate Escrow
ERC-7540 allows fungible requests: *"all Requests with the same `requestId`
MUST transition from Pending to Claimable at the same time and receive the
same exchange rate"* — our epoch design satisfies this by construction, so
`requestId = epochId`. All pending funds (deposit assets, redeem shares) and
all claimable funds (minted shares, payout assets) are held by a dumb
`Escrow` contract only the vault can move.
*Why escrow:* the vault's `totalAssets()` is then *physically* unable to
count pending money — eliminating by construction the bug class where
depositors' own pending cash inflates the NAV they will pay.
*Rejected:* in-vault custody with exclusion accounting — every NAV
computation must remember to subtract; one miss is a value leak.

### D10 — Roles
| Role | Holder | Powers |
|---|---|---|
| `MANAGER_ROLE` | fund manager / transfer agent | `closeEpoch`, `fulfillEpoch`, `invest`, `divest` |
| `DEFAULT_ADMIN_ROLE` | deployer (demo) | grant/revoke roles |
| Oracle admin | separate concern (same EOA in demo) | rate, time scale, shocks |
| ERC-7540 operator | any user-approved address | request/claim *on behalf of that user* |

The manager is **not** named "operator": ERC-7540 reserves that word for
user-level delegation (`setOperator`/`isOperator`, mandatory for compliance).
The manager cannot choose prices — the NAV comes from oracle + accounting;
the manager only chooses *when* the cycle turns (trust assumption documented
in `threat-model.md`).

## Components & file layout

```
contracts/              # Foundry project
  src/
    RWAVault.sol        # OZ ERC4626 + 7540 layer + epoch machine
    NAVOracle.sol       # simulated T-Bill accrual (rate, time scale, shocks)
    Escrow.sol          # vault-only custody of pending + claimable funds
    interfaces/
      IERC7540.sol      # IERC7540Operator / Deposit / Redeem (per EIP)
      IERC7575.sol
    mocks/
      MockUSDC.sol      # 6-decimals asset, faucet mint for demo
      TBillToken.sol    # mock security, primary market at oracle price
  test/
    unit/               # lifecycle, cancellation, access control, ERC-165
    invariant/          # epoch fairness, solvency (see docs/invariants.md)
    helpers/
  script/
    Deploy.s.sol
frontend/               # React/wagmi (separate phase)
docs/                   # design docs (repo root — not forge doc output)
```

## Demo parameters (indicative)

| Parameter | Demo | Real-world equivalent |
|---|---|---|
| Epoch cadence | 2–3 min per cycle, manager-clicked | daily cut-off |
| Closed → Fulfilled gap | ~30 s (visible "settling" state) | T+1 / T+2 |
| Oracle rate | ~4.5% annualized | T-Bill yield |
| Time scale | 1 real min ≈ 1 simulated day | — |

## Evolutions

Pro-rata partial fulfillment (liquidity-constrained epochs); asynchronous
cancellation per ERC-7887; permissionless fulfillment after a timeout
(manager-liveness mitigation); differing claim-availability delays per side;
management/performance fees; KYC & transfer restrictions; multi-asset
ERC-7575 share; two pending slots per user.
