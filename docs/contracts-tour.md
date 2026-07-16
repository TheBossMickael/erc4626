# Contracts Tour

A guided walk through the five contracts in `contracts/src/`, function by
function where it matters. The *why* behind each structural choice lives in
[design-decisions.md](design-decisions.md) (referenced as D1–D10); the spec
context lives in [rwa-funds-and-standards.md](rwa-funds-and-standards.md).

```
RWAVault.sol        OZ ERC4626 + ERC-7540/7575 surface + epoch machine
Escrow.sol          vault-only custody of pending & claimable funds
NAVOracle.sol       simulated T-Bill price feed (rate, time scale, shocks)
mocks/TBillToken.sol  the security, with its own primary market
mocks/MockUSDC.sol    6-decimals asset, open faucet
```

## RWAVault — what is OpenZeppelin's, what is mine

The vault inherits OZ `ERC4626` and never reimplements it (D1). The exact
split:

| Concern | Source | Notes |
|---|---|---|
| Share token (ERC20 `fTBILL`), decimals | OZ `ERC4626` | untouched; share decimals = asset decimals = 6, offset 0 |
| `convertToShares` / `convertToAssets` | OZ `ERC4626` | untouched — used verbatim to strike the epoch price |
| Inflation-attack mitigation | OZ `ERC4626` | virtual +1 asset / +1 share; batch pricing blunts the attack further (threat T6) |
| `totalAssets()` | **override** | `cash + tbillBalance × oraclePrice` (D3) |
| `deposit`/`mint`/`withdraw`/`redeem` | **override** | become claim functions (spec-mandated for async flows) |
| `preview*` (all four) | **override** | revert with `PreviewNotSupported` (spec-mandated) |
| `max*` (all four) | **override** | the controller's claimable amounts |
| `requestDeposit`/`requestRedeem`, pending/claimable views, `setOperator` | **new** | the ERC-7540 surface |
| `closeEpoch`/`fulfillEpoch`/`invest`/`divest`, cancels | **new** | vault-level policy, outside the standard |
| `share()` (ERC-7575) | **new**, trivial | `address(this)` — single-token vault, allowed by the EIP |

## The epoch machine

```
            requests + cancels allowed
                     │
   ┌─────────┐  closeEpoch()   ┌────────┐  fulfillEpoch()  ┌───────────┐
   │  OPEN   │ ──────────────► │ CLOSED │ ───────────────► │ FULFILLED │
   └─────────┘   (cut-off:     └────────┘  (NAV struck     └───────────┘
        ▲         binding,       no cancels,  here, batch        claims
        │         epoch N+1      "settling"   settled O(1))      forever
        │         opens)         in the UI)
        └── at most one CLOSED epoch at a time:
            closeEpoch(N+1) reverts until fulfillEpoch(N)
```

Ground rules, all enforced by construction and fuzzed (invariant I9):

- Epoch state is **derived, not stored**: OPEN ⇔ `id == currentEpochId`,
  CLOSED ⇔ `cutoffAt != 0 && fulfilledAt == 0`, FULFILLED ⇔
  `fulfilledAt != 0`.
- `requestId == epochId`. ERC-7540 requires that all requests sharing a
  `requestId` become claimable at the same time and rate — one fulfillment
  transaction at one price satisfies it structurally (D9).
- Requests always join the currently OPEN epoch; during epoch N's CLOSED
  window, new requests land in N+1 (already open).
- Closing an **empty** epoch is allowed — the manager may turn the cycle on
  a quiet day; fulfilling it is a cheap no-op batch.

## Requests

Both request functions pull funds into escrow immediately and record a
pending amount in the controller's slot:

- `requestDeposit(assets, controller, owner)` — assets move `owner → escrow`.
  Caller rule (spec): `owner` must be `msg.sender` or have approved it as an
  operator.
- `requestRedeem(shares, controller, owner)` — shares move `owner → escrow`
  **un-burned**: they stay in `totalSupply()` until fulfillment, so the
  strike price still counts them as outstanding — exactly the economics of a
  not-yet-settled redemption order. Caller rule (spec): ERC-20 allowance
  over the shares *or* operator approval (operators skip the allowance;
  third parties spend it).

Each controller has **one pending slot per direction** (D4): a
`(uint128 amount, uint64 epochId)` pair. New requests aggregate into the
slot while its epoch is OPEN; if the slot sits in the CLOSED-unfulfilled
epoch, the request reverts (`PendingRequestUnfulfilled`) — a narrow window
by design, since at most one epoch awaits settlement. If the slot's epoch is
already fulfilled, the request first **auto-rolls** it into the claimable
ledger (see lazy settlement), then joins the open epoch. Bounded storage,
no epoch enumeration, O(1) everything.

## Cancellation (extension, D7)

`cancelDepositRequest(controller)` / `cancelRedeemRequest(controller)`:
callable by the controller or its operator, **only while the slot's epoch is
OPEN**. Full refund, paid to the controller — per spec the controller owns
the request; the original funds source is deliberately not stored. After the
cut-off the order is binding (`RequestNotCancelable`), like a real fund.
Cancellation is out of ERC-7540's scope; this synchronous pre-cut-off form
is a documented divergence (see the table at the end).

## `fulfillEpoch()` — the exact order of operations

Settlement of the CLOSED epoch, `MANAGER_ROLE` only, one transaction. The
price snapshot **precedes** any movement of epoch funds — that ordering is
what makes the price honest:

1. **Strike the NAV.** Both batch conversions read the same pre-settlement
   state: `totalAssets()` excludes escrowed pending cash (D9), while
   `totalSupply()` still includes escrowed pending-redeem shares
   (economically outstanding until burned in step 3).
2. **Size the batch** with OZ's own floor math:
   `sharesMinted = convertToShares(totalDepositAssets)`,
   `assetsSetAside = convertToAssets(totalRedeemShares)`.
3. **Settle, in this order:** mint `sharesMinted` to escrow (the
   depositors' claimables); burn the escrowed `totalRedeemShares`; pull
   `totalDepositAssets` (USDC) from escrow into the vault — subscription
   cash now belongs to the fund; push `assetsSetAside` from vault to escrow
   — reserved for redeemers, out of `totalAssets()`.
4. **Record** `sharesMinted`/`assetsSetAside`/`fulfilledAt` on the epoch —
   the immutable pro-rata basis every later per-user roll prices against —
   and emit `EpochFulfilled` including the struck `navPerShare` (the
   frontend's settlement markers come verbatim from this event).

Two properties fall out of this ordering:

- **Netting (D6):** the portfolio impact is
  `totalDepositAssets − assetsSetAside` — subscriptions fund redemptions,
  only the net moves the portfolio. If vault cash plus the incoming deposit
  cash cannot cover the payout, **the final push reverts**: the manager must
  `divest` first, exactly like a real fund selling T-Bills to fund a
  redemption-heavy cycle (unit-tested; the keeper automates this check).
- **NAV continuity (invariant I3):** the price per share is unchanged
  across a fulfillment up to rounding dust, and the dust always favors
  remaining holders — entries and exits at the current price neither dilute
  nor enrich anyone.

This is also the **only place shares are ever minted or burned**
(invariant I5).

## Lazy settlement — the pending → claimable roll

Fulfillment never iterates users (no unbounded loops, threat T9). A
controller's entitlement is materialized at their next touchpoint — a
request, a cancel, a claim, or any view:

- slot's epoch **fulfilled** → convert pro-rata, credit the claimable
  ledger, free the slot (atomic with the credit — no double-claim window,
  invariant I7);
- slot's epoch **open** → aggregate / cancel as usual;
- slot's epoch **closed, not fulfilled** → binding, slot busy.

Entitlements are **pro-rata against the recorded batch result**, not a
stored price: `userShares = userAssets × sharesMinted / totalDepositAssets`
(floor). Two reasons: no rounding error can compound through a stored
price, and `Σ user claims ≤ batch result` holds term by term (invariant
I2). Dust — fractions lost to the floor — stays in escrow, unclaimable,
strictly less than 1 wei per requester per epoch.

The claimable ledger tracks **both denominations** per direction
(`{assets, shares}` pairs). This is forced by the claim surface itself: the
spec mandates claims in either unit (`deposit(assets)` AND `mint(shares)`;
`withdraw(assets)` AND `redeem(shares)`), partial claims are allowed, and
the roll merges entitlements from epochs settled at *different* rates —
once merged, one denomination can only be recovered from the other pro-rata
against the stored pair.

### Worked example

Epoch 7 is open. Alice `requestDeposit(1_000e6)` at 10:00; Bob
`requestDeposit(500e6)` at 10:04, seconds before the cut-off. Epoch 7
closes (both binding), epoch 8 opens. NAV accrues. At 10:06 the manager
fulfills epoch 7 at a struck price of 1.05 USDC/share →
`sharesMinted = floor(1_500e6 / 1.05) = 1_428.571428e6`, minted to escrow.
Alice's roll: `1_000e6 × sharesMinted / 1_500e6 = 952.380952e6` shares.
Bob: `476.190476e6`. **Identical rate — Bob's four-minutes-later request
bought him nothing.** That is invariant I1, and it is structural.

## Claims

Per spec, the 4626 entry points *are* the claim functions (plus the
controller-overloaded forms). No pricing happens here — assets moved at
request time, shares were minted at fulfillment; claims only release
escrowed value against the controller's ledger.

| Function | Pays out | Consumes | Rounding |
|---|---|---|---|
| `deposit(assets, receiver[, controller])` | shares | assets (exact input) | shares out **floor** |
| `mint(shares, receiver[, controller])` | shares (exact input) | assets | assets consumed **ceil** |
| `withdraw(assets, receiver, controller)` | assets (exact input) | shares | shares consumed **ceil** |
| `redeem(shares, receiver, controller)` | assets | shares (exact input) | assets out **floor** |

Outputs floor, consumption ceils — always in the vault's favor (threat T3
applied to the claim layer). A **full claim takes the exact remaining
pair**, so repeated partial claims strand nothing (unit-fuzzed).

Spec caller rules: `msg.sender` must be the controller or its operator. The
ERC-20 share-allowance path of plain 4626 `withdraw`/`redeem` does **not**
apply — shares were escrowed at request time. At claim time the `Deposit`
event's first parameter is the **controller** (spec-mandated), not
`msg.sender`, which may be a mere operator.

## Views

- `pendingDepositRequest`/`pendingRedeemRequest(requestId, controller)`
  match `requestId` **exactly** — a pending sits in one known epoch — and
  read as zero the moment that epoch is fulfilled.
- `claimableDepositRequest`/`claimableRedeemRequest` **ignore** their
  `requestId`: after the roll, entitlements from different epochs merge
  into one fungible ledger and per-epoch attribution no longer exists (the
  fungible-request model the spec explicitly allows). `max*` are the
  canonical claimable amounts.
- All views **simulate the lazy roll** (same math as the state-changing
  roll), so on-chain readers and the frontend see settled state the moment
  `fulfillEpoch()` lands, before any touchpoint.

## ERC-165 surface

| Interface id | Meaning |
|---|---|
| `0xe3bc4e65` | ERC-7540 operator methods |
| `0xce3bbe50` | ERC-7540 asynchronous deposit |
| `0x620ee8e4` | ERC-7540 asynchronous redemption |
| `0x2f0a18c5` | ERC-7575 vault |
| via `super` | ERC-165 itself + `IAccessControl` (OZ AccessControl) |

Reporting *both* async ids declares the vault fully asynchronous. The four
EIP ids are hardcoded on purpose: computing `type(X).interfaceId` over the
partial local interfaces would not reproduce them (e.g. our `IERC7575` only
declares `share()`, while `0x2f0a18c5` covers the full 7575 vault surface).

## NAVOracle

Prices the T-Bill in USDC terms, 1e18 fixed-point, starting at par.
Accrual is **piecewise-linear simple interest between checkpoints**;
compounding happens only when a checkpoint occurs — and *every admin action
checkpoints first*, so parameter changes never apply retroactively to
already-elapsed time. Three knobs, all `onlyOwner` (the simulated fund
accountant, threat T10):

| Function | Effect | Demo-safety cap |
|---|---|---|
| `setRateBps` | annualized simple rate (450 = 4.5%) | ≤ 20% APR |
| `setTimeScale` | simulated seconds per real second (1440 ⇒ 1 min ≈ 1 day) | ≤ 1e6 |
| `applyShock` | one-off multiplicative mark-to-market move | ±50% per shock |

The caps bound fat-finger damage; they are not economic parameters. Every
checkpoint **emits the checkpoint price**, which makes the whole trajectory
reconstructible from events — the frontend's NAV timeline replays
`price()` verbatim client-side from those checkpoints
([operations.md](operations.md)). Shocks landing between a cut-off and its
fulfillment hit already-binding orders — deliberate; that is how real funds
work (D5/D7/D8).

## Escrow

Deliberately dumb: one `transferTo(token, to, amount)` guarded by
`msg.sender == vault`, bound once in the constructor (the vault deploys its
own escrow), no owner, no setter, no upgrade path. Inbound transfers need no
function — the vault transfers directly to the address.

Why a separate contract instead of exclusion accounting inside the vault
(D9): `totalAssets()` is then *physically unable* to count pending money.
The bug class where depositors' own pending cash inflates the NAV they will
pay (threat T2) is eliminated by construction — there is no subtraction to
forget. The observable consequence is invariant I6: requests and cancels
never move the share price.

## Mocks

**TBillToken** — the security (D3), with its own primary market at the
oracle price: `subscribe(usdcAmount)` mints TBILL against USDC,
`redeem(tbillAmount)` pays principal *plus accrued interest*, the way a
maturing T-Bill does. The treasury only ever collected principal, so the
interest shortfall is minted as fresh USDC — **the simulation's yield
source, made explicit** rather than appearing from nowhere in an accrual
index. 6 decimals deliberately matching USDC: every value conversion is one
1e18-scaled multiplication, with no decimals-bridging term to get wrong.

**MockUSDC** — 6 decimals like the real thing, with an open `mint`: the
demo faucet *and* the issuer's interest-payment mechanism. Obviously never
deployable as-is outside a simulation (threat T14 covers the open faucet).

## Deliberate divergences & extensions vs ERC-7540

| Point | Standard | Here | Why |
|---|---|---|---|
| Cancellation | out of scope; ERC-7887 (Draft) defines *async* cancels | synchronous, pre-cut-off only | settlement is atomic on one chain — no in-flight state to unwind; post-cut-off orders are binding like a real fund |
| Epoch machine, cut-off | not specified (implementation freedom) | two-phase Open/Closed/Fulfilled | forward pricing + binding orders (D5) |
| Requests per user | unlimited (spec silent) | one pending slot per direction, auto-roll (D4) | O(1) everything, no epoch enumeration; the revert window is the CLOSED phase only |
| Request transferability | non-transferable by default | non-transferable | default kept |
| `claimable*Request(requestId, …)` | per-requestId amounts (fungible model allowed) | aggregate, `requestId` ignored | the lazy roll merges epochs into one fungible ledger; `max*` are canonical |
