# ERC-7540 Architecture — Epoch Queue Mechanics

How the async layer works, function by function, and how it maps to the
[ERC-7540 specification](https://eips.ethereum.org/EIPS/eip-7540). Decisions
and their rationale live in `rwa-vault-design.md` (D1–D10); this file is the
mechanical reference the implementation and the tests are written against.

## Why asynchronous at all

An ERC-4626 vault prices every deposit/withdrawal instantly against
`totalAssets()`. That works when the underlying is liquid and continuously
priced. A fund of real-world assets is neither: the portfolio is repriced
periodically (NAV calculation), and liquidating assets takes days. Instant
exits would either leak value (stale price) or be unbackable (no cash).
Real funds solve this with **forward pricing**: orders are collected until a
cut-off, priced at a NAV computed *after* the cut-off, then settled. Nobody
— not even the fund — knows the execution price when an order is placed.
ERC-7540 is the on-chain encoding of that request → fulfill → claim
lifecycle.

## Layering: what is OZ's, what is ours

| Concern | Source | Notes |
|---|---|---|
| Share token (ERC20), decimals offset | OZ `ERC4626` | untouched |
| `convertToShares` / `convertToAssets` | OZ `ERC4626` | untouched; used to strike the epoch price |
| `totalAssets()` | **override** | `cash + tbillBalance × oraclePrice` (D3) |
| `asset()`, `share()` (7575) | OZ / trivial | `share() == address(this)` (single-token vault, allowed by 7575) |
| `deposit`/`mint`/`withdraw`/`redeem` | **override** | become claim functions (spec-mandated for async flows) |
| `preview*` (all four) | **override** | revert (spec-mandated: price unknowable at request time) |
| `max*` (all four) | **override** | return the controller's claimable amounts |
| `requestDeposit`/`requestRedeem`, pending/claimable views, `setOperator`/`isOperator` | **new** | the 7540 surface |
| `closeEpoch`/`fulfillEpoch`/`invest`/`divest`, cancels | **new** | vault-level policy, outside the standard |

## Epoch state machine

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

- `requestId = epochId`. The spec requires that *"all Requests with the same
  `requestId` MUST transition from Pending to Claimable at the same time and
  receive the same exchange rate"* — satisfied by construction: an epoch is
  fulfilled in one transaction at one price.
- Requests always join the currently OPEN epoch. Requesting during the
  CLOSED window of epoch N lands in epoch N+1 (already open).

## Storage sketch

```solidity
struct Epoch {
    uint256 totalDepositAssets;   // aggregated requestDeposit amounts
    uint256 totalRedeemShares;    // aggregated requestRedeem amounts
    uint256 sharesMinted;         // set at fulfillment (deposit side result)
    uint256 assetsSetAside;       // set at fulfillment (redeem side result)
    uint64  cutoffAt;             // closeEpoch timestamp
    uint64  fulfilledAt;          // 0 = not fulfilled
}

struct UserSlot {                 // one per user per direction (D4)
    uint128 pendingAmount;        // assets (deposit) or shares (redeem)
    uint64  epochId;              // epoch the pending belongs to
}

struct ClaimBalance {             // post-roll claimable ledger, per direction
    uint256 assets;               // deposit side: fulfilled assets in
    uint256 shares;               //               shares they earned
}                                 // redeem side: mirrored (shares in, assets earned)

mapping(uint256 => Epoch)   epochs;
uint256                     currentEpochId;      // the OPEN epoch (ids start at 1; 0 = empty-slot sentinel)
mapping(address => UserSlot) depositSlot;
mapping(address => UserSlot) redeemSlot;
mapping(address => ClaimBalance) claimableDeposit;
mapping(address => ClaimBalance) claimableRedeem;
mapping(address => mapping(address => bool)) isOperator;  // 7540 operators
```

Per-user entitlements are **pro-rata against the batch result**, not against
a stored price: `userShares = userAssets × sharesMinted / totalDepositAssets`
(floor). This avoids compounding a rounding error through a stored
price and keeps `Σ user claims ≤ batch result` trivially true (invariant I2).

The claimable ledger tracks **both denominations** per direction. This is
forced by the claim surface itself: the spec mandates claims in either unit
(`deposit(assets)` AND `mint(shares)`; `withdraw(assets)` AND
`redeem(shares)`), partial claims are allowed, and the lazy roll aggregates
entitlements from epochs settled at *different* rates — once merged, one
denomination can only be recovered from the other pro-rata against this
stored pair. A single-denomination ledger cannot answer `maxDeposit`
(assets) and `maxMint` (shares) simultaneously.

## `fulfillEpoch()` — exact order of operations

The price snapshot **precedes** any movement of epoch funds; this ordering is
what makes the price honest:

1. **Strike the NAV.** `price = convertToAssets(1 share)` on the *current*
   state: `totalAssets()` physically excludes escrowed pending cash (D9), and
   `totalSupply()` still includes pending-redeem shares (transferred to
   escrow at request time but economically outstanding until burned).
2. **Size the batch.** `sharesMinted = totalDepositAssets · supply/assets`
   (floor, via OZ `convertToShares` math); `assetsSetAside =
   totalRedeemShares · assets/supply` (floor).
3. **Settle, in this order:** mint `sharesMinted` to the escrow (claimable by
   depositors); burn the `totalRedeemShares` held in escrow; pull
   `totalDepositAssets` (USDC) from escrow into the vault — the cash now
   belongs to the fund; push `assetsSetAside` (USDC) from vault to escrow —
   reserved for redeemers, out of `totalAssets()`.
4. **Record & advance.** Store `sharesMinted`/`assetsSetAside` and
   `fulfilledAt` on the epoch (the lazy-roll source of truth), emit events.

Net portfolio impact is `totalDepositAssets − assetsSetAside`: subscriptions
fund redemptions (netting, D6); the manager then `invest`s or `divest`s the
net against the mock T-Bill primary market.

**Resulting property (invariant I3):** NAV per share is unchanged across a
fulfillment, up to rounding dust that always favors remaining holders —
entries and exits at the current price neither dilute nor enrich anyone.

## Lazy settlement (pending → claimable roll)

Fulfillment never iterates users. A user's entitlement is materialized at
their next touchpoint — `requestDeposit`, `requestRedeem`, a cancel, a claim,
or any `pending*/claimable*/max*` view:

- slot empty → nothing to do;
- slot's epoch **fulfilled** → convert pro-rata, add to
  `claimableShares`/`claimableAssets`, free the slot;
- slot's epoch **open** → new request aggregates into it, cancel empties it;
- slot's epoch **closed, not fulfilled** → binding: cancel reverts, and a new
  request reverts too (the slot is busy; narrow window, see D4).

### Worked example

Epoch 7 is open. Alice `requestDeposit(1_000e6)` at 10:00; Bob
`requestDeposit(500e6)` at 10:04, seconds before the cut-off. Epoch 7 closes
(both are now binding), epoch 8 opens. NAV accrues. At 10:06 the manager
fulfills epoch 7: price struck at 1.05 USDC/share → `sharesMinted =
floor(1_500e6 / 1.05) = 1_428.571428e6` minted to escrow.
Alice's roll: `1_000e6 × sharesMinted / 1_500e6 = 952.380952e6` shares. Bob:
`476.190476e6`. **Identical rate, request timing irrelevant** — Bob's
4-minute-later request bought him nothing. Dust (fractions lost to floor)
stays in escrow, unclaimable, bounded by 1 wei per user (I2).

## Claiming

Per spec, the 4626 entry points *are* the claim functions, plus the
controller-overloaded forms:

- `deposit(assets, receiver)` / `deposit(assets, receiver, controller)` and
  `mint(shares, receiver, controller)` transfer already-minted shares from
  escrow against `claimableShares` (no new mint, no asset transfer — that
  happened at request/fulfill time). Partial claims allowed.
- `withdraw(assets, receiver, controller)` / `redeem(shares, receiver,
  controller)` transfer reserved USDC from escrow against `claimableAssets`.
- Caller rule (spec): `msg.sender` must be the `controller` or an approved
  operator of the controller. The ERC-20 share-allowance path of plain
  ERC-4626 `withdraw`/`redeem` does **not** apply to claims (spec): shares
  were escrowed at request time.
- Partial-claim rounding (T3 policy applied to the claim layer): amounts
  *paid out* round down, amounts *consumed* from the ledger round up — always
  in the vault's favor. A full claim (`amount == ledger balance`) takes the
  exact remaining pair, so repeated partial claims strand nothing.
- At claim time the `Deposit` event's first parameter is the **controller**
  (spec-mandated), not `msg.sender` (which may be a mere operator).
- `maxDeposit/maxMint(controller)` mirror deposit-side claimables;
  `maxWithdraw/maxRedeem(controller)` mirror redeem-side claimables. All four
  `preview*` revert.
- `claimableDepositRequest`/`claimableRedeemRequest` ignore their `requestId`
  argument: after the roll, entitlements from different epochs merge into one
  fungible ledger and per-epoch attribution no longer exists (fungible-
  request model, explicitly allowed by the spec). `max*` are the canonical
  claimable amounts. `pending*Request` DO match `requestId` exactly — a
  pending sits in one known epoch.

## Cancellation mechanics (extension, D7)

`cancelDepositRequest(controller)` / `cancelRedeemRequest(controller)`:
callable by the controller or its approved operator, only while the slot's
epoch is OPEN (after the roll — a fulfilled pending is claimable, not
cancelable; a CLOSED one is binding). The full pending amount is refunded
**to the controller**: the controller owns the request per spec, and the
original funds source (`owner`) is deliberately not stored.

## Request functions — caller rules (spec)

- `requestDeposit(assets, controller, owner)`: assets pulled from `owner` to
  escrow; `owner` must be `msg.sender` or have approved it as operator.
- `requestRedeem(shares, controller, owner)`: shares pulled from `owner` to
  escrow; authorized by ERC-20 allowance over the shares **or** operator
  approval.
- `controller` (not `owner`) owns the resulting request: it cancels, claims,
  and is the key of all request state. `owner` is only the source of funds.

## ERC-165 surface

`supportsInterface` returns `true` for: `0xe3bc4e65` (7540 operator methods),
`0x2f0a18c5` (ERC-7575), `0xce3bbe50` (async deposit), `0x620ee8e4` (async
redeem) — the vault is *fully* asynchronous — plus ERC-165 itself.

## Deliberate divergences & extensions

| Point | Standard | Here | Why |
|---|---|---|---|
| Cancellation | out of scope; ERC-7887 (Draft) defines *async* cancels | synchronous, pre-cut-off only | settlement is atomic on one chain — no in-flight state to unwind; post-cut-off orders are binding like a real fund |
| Epoch machine, cut-off | not specified (implementation freedom) | two-phase Open/Closed/Fulfilled | forward pricing + binding orders (D5) |
| Requests per user | unlimited (spec silent) | one pending slot per direction, auto-roll (D4) | O(1) everything, no epoch enumeration; revert window is the CLOSED phase only |
| Request transferability | non-transferable by default | non-transferable | default kept |
| `claimable*Request(requestId, …)` | per-requestId amounts (fungible model allowed) | aggregate, `requestId` ignored | the lazy roll merges epochs into one fungible ledger; `max*` are canonical |
