# Operations — How the Live Demo Runs

The operated layer around the contracts: a hosted frontend, a CI keeper
that settles epochs unattended, and the Sepolia record behind both.
Nothing in this layer changes on-chain semantics — the contracts remain the
security boundary. The trust analysis of this layer lives in the
[threat model](threat-model.md) (§ *The operational layer*).

Live site: **https://tokenized-tbill.onrender.com**

## Three views = the three actors of an institutional fund

| View | Real-world equivalent | Write access |
|---|---|---|
| **Overview** | The fund's public factsheet: NAV timeline, AUM, settlement history | none (no wallet needed) |
| **Invest** | The client portal: faucet, request deposit/redeem, cancel pre-cut-off, claim | any wallet — every wallet is a prospective client |
| **Operate** | The back office: transfer agent (epoch cycle), portfolio manager (invest/divest), fund accountant (NAV oracle) | `MANAGER_ROLE` for the cycle & portfolio; oracle `owner()` for rate/shocks |

Role separation is the point: the back office is deliberately public —
watching the transfer agent work *is* the demo. An investor sees everything
but can touch nothing; the UI reads roles live from the chain (never from
hardcoded addresses) and disables what the connected wallet cannot do. UI
gating prevents honest mistakes only — bypassing it lands on the contracts'
access control, which is the tested boundary (invariant I8).

## The NAV timeline is an event replay

The site runs with **no backend and no indexer** — every number is
re-derived from Sepolia on page load. That works because the NAV per share
is a deterministic function of on-chain events: the oracle emits its
checkpoint price on every admin action, and the vault's
`{cash, tbill, supply}` triple only moves on evented operations. The
frontend replays those events with the same formulas as `totalAssets()`
and OZ's `convertToAssets`, so the timeline *is* the chain's accounting —
and each settlement marker is the `navPerShare` recorded in its
`EpochFulfilled` event, not an interpolation.

Replaying history on every page load is also the one part that does not
scale — that constraint is *why indexers exist*; at this demo's volume it
is the right trade against running infrastructure.

## The demo keeper

Turning the cycle is a human gesture by design: the transfer agent clicks
**Close epoch** then **Fulfill epoch** on the Operate view — in this demo,
me, connected with the `MANAGER_ROLE` account. The keeper
(`keeper/keeper.mjs`) exists so a visitor who requests a deposit never has
to wait for me to be online: GitHub Actions runs it on a ~30-minute cron
with its own `MANAGER_ROLE` key, and it performs exactly the sequence I
would click, nothing more:

1. if an epoch is closed and awaiting settlement, settle it — divesting
   TBILL first when vault cash cannot cover the redemption payout, like a
   real fund selling assets to honor redemptions;
2. otherwise, close and settle the open epoch — but only if requests are
   actually pending; quiet days cost zero transactions;
3. after settling, re-invest idle cash above a 5% float of the fund — a
   published, NAV-neutral allocation policy (both legs trade at the oracle
   price).

Trust scope: the keeper EOA holds `MANAGER_ROLE` and nothing else — it can
grief liveness and churn NAV-neutral allocation; it cannot touch prices or
custody. At the oracle's ×1440 time scale, this 30-minute cadence models a
fund settling roughly monthly.

## Deployment record (Sepolia, 2026-07-10)

All five contracts are Etherscan-verified.

| Contract | Address |
|---|---|
| RWAVault (`fTBILL`) | [`0x925B7c0cbfd74E7CBAE348541C629EC1ff33aa9C`](https://sepolia.etherscan.io/address/0x925B7c0cbfd74E7CBAE348541C629EC1ff33aa9C) |
| Escrow | [`0x2d3efE14E06c82F4F470648eb71194870Bf9D8fb`](https://sepolia.etherscan.io/address/0x2d3efE14E06c82F4F470648eb71194870Bf9D8fb) |
| NAVOracle (450 bps, time scale 1440) | [`0x200832A82DC75FdAe22191E1563d72667542Fbe3`](https://sepolia.etherscan.io/address/0x200832A82DC75FdAe22191E1563d72667542Fbe3) |
| TBillToken | [`0x38705BD52F94db088bF537c1A811EE4a03a0E70A`](https://sepolia.etherscan.io/address/0x38705BD52F94db088bF537c1A811EE4a03a0E70A) |
| MockUSDC | [`0x098837194e00Ce31B6fB3b8879af576FB50D9A5f`](https://sepolia.etherscan.io/address/0x098837194e00Ce31B6fB3b8879af576FB50D9A5f) |

| Account | Role |
|---|---|
| `0x517431C6b86d781a5644e7b0a4f2fDCf7B8e97D4` | deployer: admin + manager + oracle owner — single demo operator key, an accepted residual |
| `0xF8a7b6B81075B42802cBCE7351a69F5003D92295` | keeper: `MANAGER_ROLE` only, granted 2026-07-11 via `grantRole` (no redeploy); holds gas only |

## Hosting & keys

The frontend is a static site on Render, redeployed on every push to
`main`. Its RPC key ships in the public bundle by design — read-only on a
testnet, analyzed in the threat model — while the keeper signs with its
own key from GitHub Actions secrets and uses a separate RPC key, so the
public key and the settlement path can never break each other.
