# RWA Funds & the Vault Standards

Why this project is asynchronous, where ERC-7540 comes from, and how the
choices here compare to the tokenized T-Bill funds actually in production.
The mechanics of *this* implementation live in
[contracts-tour.md](contracts-tour.md); this document is about the design
space.

## How an institutional fund settles

A money-market or T-Bill fund does not trade like a DEX pool. Orders are
collected until a **cut-off**; the fund's **NAV per share is computed after
the cut-off** by the fund accountant; orders then execute at that price and
cash/shares move **T+1 or T+2**, handled by a transfer agent. The key rule is
**forward pricing**: nobody — not even the fund — knows the execution price
when an order is placed. In US mutual funds this is literally regulation
(SEC Rule 22c-1); its purpose is anti-dilution: you cannot trade against a
price you observed in advance.

Four distinct actors run this pipeline, and each has an on-chain counterpart
in this project:

| Real-world actor | Responsibility | Here |
|---|---|---|
| Portfolio manager | invests subscriptions, sells assets to fund redemptions | `MANAGER_ROLE`: `invest`/`divest` against the mock T-Bill primary market |
| Transfer agent | runs the order book: cut-offs, settlement, registrar | `MANAGER_ROLE`: `closeEpoch`/`fulfillEpoch` (a CI keeper holds the role too) |
| Fund accountant | computes and publishes the NAV | `NAVOracle` + the vault's own accounting (`totalAssets()`) |
| Custodian | holds assets segregated from the manager | `Escrow` for investor-side funds; the vault holds the portfolio |

The separation that matters most on-chain: **the party that turns the
settlement cycle never chooses the price**. The manager decides *when*;
the oracle plus the vault's accounting decide *at what*.

## Why synchronous ERC-4626 can't model this

ERC-4626 prices every deposit and withdrawal instantly against
`totalAssets()`, and its `preview*` functions promise a quote good in the
same block. That contract is only honest when the underlying is liquid and
continuously priced. A portfolio of T-Bills is neither:

- The NAV is **discretely repriced** (a feed, not an AMM). Instant entry/exit
  between repricings executes at a stale value — whoever times the update
  extracts the difference from everyone else.
- Redemptions need **cash the fund doesn't hold idle**. Selling a T-Bill
  settles in days; an instant `withdraw` is either unbackable or forces the
  fund to run a large cash drag.
- `preview*` cannot be implemented truthfully: the execution price of an
  order that settles tomorrow **does not exist yet**. Returning today's
  price is exactly the dilution bug forward pricing exists to prevent.

None of this makes 4626 the wrong base — it makes it the wrong *interaction
surface*. The share token, the conversion math, the ecosystem integrations
and OpenZeppelin's hardened implementation (virtual-share offset against
inflation attacks) are precisely what you want at the accounting core. The
question is what to put in front of it.

## ERC-7540: requests as first-class state

[ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) is the standard answer
(finalized in 2024), an effort led by engineers at
[Centrifuge](https://centrifuge.io) — the RWA protocol whose pools had run
asynchronous, epoch-based investment flows for years before the spec —
with co-authors from across the ecosystem. It extends 4626 with a request
lifecycle: **Pending → Claimable → Claimed**.

What the spec pins down (and this vault implements in full):

- `requestDeposit`/`requestRedeem` lock funds immediately; a later
  fulfillment prices them; the classic 4626 entry points
  (`deposit`/`mint`/`withdraw`/`redeem`) are **reinterpreted as claim
  functions** that only release already-priced value.
- All four `preview*` **MUST revert** for asynchronous flows — the spec
  encodes "the price doesn't exist yet" instead of letting vaults lie.
  `max*` become the controller's claimable amounts.
- A **controller/owner split** plus per-user **operators**: the `owner`
  funds a request, the `controller` owns it (cancels, claims), and a
  controller can delegate to operators — the hooks custody and compliance
  setups need.
- **Request fungibility**: all requests sharing a `requestId` must become
  claimable together *at the same exchange rate*. This single sentence is
  why an epoch design fits the standard so naturally — see below.
- Mandatory [ERC-7575](https://eips.ethereum.org/EIPS/eip-7575) support:
  share/vault separation for multi-asset pools. For a single-token vault
  like this one it reduces to `share()` returning the vault itself —
  explicitly allowed by the EIP.

Just as important is what the spec **leaves open**, because that's where the
engineering happens:

| Left open by ERC-7540 | What this project chose |
|---|---|
| *How and when* requests are fulfilled | Two-phase epochs: cut-off (`closeEpoch`) then settlement (`fulfillEpoch`), batch-priced in O(1) — [design-decisions.md](design-decisions.md) D4/D5 |
| Cancellation (explicitly out of scope; [ERC-7887](https://eips.ethereum.org/EIPS/eip-7887) drafts async cancels) | Synchronous cancel, only before the cut-off — settlement is atomic on one chain, so there is no in-flight state to unwind |
| Partial fulfillment, fees, KYC | Out of V1, listed as evolutions |
| Who may fulfill | `MANAGER_ROLE` — the transfer-agent model, trust assumption documented in the [threat model](threat-model.md) |

Our epoch design makes the fungibility rule structural: `requestId ==
epochId`, one fulfillment transaction, one price, pro-rata splits. The
invariant the spec asks for is satisfied by construction rather than by
bookkeeping — this is the single most load-bearing design decision in the
repo.

## How the industry ships it today

The tokenized T-Bill market is real money in production, and it's worth
seeing how differently the same problem gets solved:

- **BlackRock BUIDL** (with [Securitize](https://securitize.io) as transfer
  agent) — a permissioned ERC-20 restricted to whitelisted **qualified
  purchasers**. NAV and daily dividend accrual are computed off-chain by
  the traditional fund machinery; the token is the registrar, not the
  pricing engine. A
  [Circle-operated USDC contract](https://www.circle.com/pressroom/circle-announces-usdc-smart-contract-for-transfers-by-blackrocks-buidl-fund-investors)
  provides a 24/7 instant-exit rail at $1.
- **Franklin Templeton BENJI**
  ([Benji platform](https://digitalassets.franklintempleton.com/benji/)) —
  the token of FOBXX, the first US-registered mutual fund to use a public
  blockchain as the official record of share ownership (1 share = 1 BENJI).
  Franklin acts as its own transfer agent; pricing and order handling stay
  off-chain.
- **Ondo OUSG** ([ondo.finance/ousg](https://ondo.finance/ousg)) —
  KYC-gated (qualified purchasers) exposure to short-term Treasuries with
  24/7 instant mint/redeem in USDC, BUIDL being its largest holding.
  Instant UX — but bounded by the liquidity buffers backing it.
- **Centrifuge** — the 7540 lead authors, running it in production: their
  legacy pools pioneered epoch-based request aggregation (investments and
  redemptions only processed at epoch close), and their current
  [vaults](https://github.com/centrifuge/liquidity-pools) expose ERC-7540 —
  the closest living relative of this project's mechanics.

The pattern across all of them: **permissioned access, an authoritative
off-chain NAV, and a transfer agent who controls settlement timing**. The
on-chain part is the register and the settlement rail; the pricing authority
stays institutional.

## Where this project sits

I kept the institutional skeleton and removed the permissioning, because the
goal is to expose the settlement mechanics, not to run a regulated fund:

- **Both directions asynchronous** (stricter than many production funds,
  which offer instant or same-day entry rails): forward pricing in both
  directions is
  the anti-dilution mechanism, and a sync-deposit/async-redeem hybrid
  reintroduces deposit-timing games against discrete NAV moves — see
  [design-decisions.md](design-decisions.md) D2.
- **Open access, no KYC** — anyone with Sepolia gas can be an investor;
  the back-office console is publicly *visible* and role-gated on-chain.
- **The NAV feed is an admin-set simulation** standing in for the fund
  accountant. The threat model treats the oracle as the #1 surface a
  production deployment would have to harden (signed feeds, staleness and
  deviation bounds).
- **Custody is structural**: pending investor money lives in a separate
  `Escrow` contract that the vault's NAV computation physically cannot see —
  the on-chain analogue of segregated accounts.

## Further reading

- [EIP-4626](https://eips.ethereum.org/EIPS/eip-4626) ·
  [OpenZeppelin ERC4626 guide](https://docs.openzeppelin.com/contracts/5.x/erc4626)
  (including the inflation-attack analysis behind the virtual-share offset)
- [EIP-7540](https://eips.ethereum.org/EIPS/eip-7540) ·
  [EIP-7575](https://eips.ethereum.org/EIPS/eip-7575) ·
  [EIP-7887](https://eips.ethereum.org/EIPS/eip-7887)
- [Centrifuge](https://centrifuge.io) — the reference ERC-7540 deployment
  ([contracts](https://github.com/centrifuge/liquidity-pools))
- [SEC Rule 22c-1](https://www.ici.org/faqs/faq/mfs/faqs_navs) (forward
  pricing) — the TradFi rule this vault's epoch pricing mirrors
