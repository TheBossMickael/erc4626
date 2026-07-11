// NAV timeline without an indexer and without an archive node.
//
// The fund's NAV per share is a deterministic function of (a) the oracle's
// piecewise-linear price trajectory — every admin action checkpoints and
// EMITS the checkpoint price — and (b) the vault's {cash, tbill, supply}
// triple, which only moves on EpochFulfilled / Invested / Divested, all
// evented. So one eth_getLogs scan from the deployment block plus block
// timestamps is enough to REPLAY the exact on-chain accounting client-side:
// the same formulas as RWAVault.totalAssets() + OZ convertToAssets (virtual
// +1 asset / +1 share, decimals offset 0).
import { createPublicClient, fallback, getAbiItem, http } from "viem";
import { sepolia } from "viem/chains";
import { ADDRESSES, DEPLOY_BLOCK, ONE_SHARE, PRICE_SCALE } from "../config/addresses";
import { vaultAbi, oracleAbi } from "../config/abis";

// Dedicated history-scan client, SEPARATE from the app's main transport:
// Alchemy's free tier caps eth_getLogs at a 10-BLOCK range (its -32600
// "JSON is not a valid request object" hides that in `Details`), which no
// chunking strategy can absorb over a growing chain. State reads stay on
// the configured RPC; the event scan goes to public endpoints that accept
// wide ranges, with failover. This is the cost of the no-indexer
// architecture — and an availability dependency only, never a correctness
// one: everything is re-derived from the chain on every load.
const scanClient = createPublicClient({
  chain: sepolia,
  transport: fallback([
    http("https://ethereum-sepolia-rpc.publicnode.com"),
    http("https://sepolia.drpc.org"),
  ]),
});

// Constructor parameters of the 2026-07-10 deployment (no event at deploy;
// these seed the replay exactly like the constructor seeds the contracts).
const INITIAL_RATE_BPS = 450n;
const INITIAL_TIME_SCALE = 1440n; // 1 real minute = 1 simulated day
const BPS = 10_000n;
const YEAR = 31_536_000n; // 365 days, as in NAVOracle

const events = [
  getAbiItem({ abi: vaultAbi, name: "DepositRequest" }),
  getAbiItem({ abi: vaultAbi, name: "RedeemRequest" }),
  getAbiItem({ abi: vaultAbi, name: "EpochClosed" }),
  getAbiItem({ abi: vaultAbi, name: "EpochFulfilled" }),
  getAbiItem({ abi: vaultAbi, name: "Invested" }),
  getAbiItem({ abi: vaultAbi, name: "Divested" }),
  getAbiItem({ abi: oracleAbi, name: "RateSet" }),
  getAbiItem({ abi: oracleAbi, name: "TimeScaleSet" }),
  getAbiItem({ abi: oracleAbi, name: "ShockApplied" }),
];

export interface NavPoint {
  t: number; // unix seconds
  nav: number; // fund NAV per share, assets per 1.0 share
  price: number; // oracle T-Bill price — the benchmark the fund tracks
}

export interface FulfillMarker {
  t: number;
  nav: number; // exact strike NAV from the EpochFulfilled event
  epochId: number;
  txHash: string;
}

export interface EpochRow {
  id: number;
  closedAt?: number;
  fulfilledAt?: number;
  totalDepositAssets: bigint;
  totalRedeemShares: bigint;
  sharesMinted?: bigint;
  assetsSetAside?: bigint;
  navPerShare?: bigint;
  fulfillTx?: string;
}

export interface ChainHistory {
  navPoints: NavPoint[];
  markers: FulfillMarker[];
  epochs: EpochRow[]; // newest first
  depositRequestCount: number;
  redeemRequestCount: number;
}

/** getLogs with binary-split retry: try the whole span first, halve on
 * rejection until the provider accepts the range (floor ~800 blocks). */
async function getLogsResilient(
  fromBlock: bigint,
  toBlock: bigint,
): Promise<Awaited<ReturnType<typeof scan>>> {
  try {
    return await scan(fromBlock, toBlock);
  } catch (err) {
    if (toBlock - fromBlock < 800n) throw err;
    const mid = fromBlock + (toBlock - fromBlock) / 2n;
    const [left, right] = await Promise.all([
      getLogsResilient(fromBlock, mid),
      getLogsResilient(mid + 1n, toBlock),
    ]);
    return [...left, ...right];
  }
}

function scan(fromBlock: bigint, toBlock: bigint) {
  return scanClient.getLogs({
    address: [ADDRESSES.vault, ADDRESSES.oracle],
    events,
    fromBlock,
    toBlock,
  });
}

/** price(t) inside one oracle segment — NAVOracle.price() verbatim. */
function priceAt(t: bigint, cp: bigint, cpAt: bigint, rateBps: bigint, timeScale: bigint): bigint {
  const simulatedElapsed = (t - cpAt) * timeScale;
  return cp + (cp * rateBps * simulatedElapsed) / (BPS * YEAR);
}

/** OZ ERC4626 convertToAssets(ONE_SHARE) with decimals offset 0. */
function navPerShare(assets: bigint, supply: bigint): bigint {
  return (ONE_SHARE * (assets + 1n)) / (supply + 1n);
}

export async function loadChainHistory(): Promise<ChainHistory> {
  const [deployBlock, latestBlock] = await Promise.all([
    scanClient.getBlock({ blockNumber: DEPLOY_BLOCK }),
    scanClient.getBlock(),
  ]);
  const t0 = deployBlock.timestamp;
  const now = latestBlock.timestamp;

  const logs = await getLogsResilient(DEPLOY_BLOCK, latestBlock.number);
  logs.sort((a, b) =>
    a.blockNumber !== b.blockNumber ? Number(a.blockNumber - b.blockNumber) : a.logIndex - b.logIndex,
  );

  // Timestamps for every block that carries an event — fetched in small
  // bursts (no HTTP batching on the transport; be gentle with free tiers).
  const blockNums = [...new Set(logs.map((l) => l.blockNumber))];
  const tsByBlock = new Map<bigint, bigint>();
  for (let i = 0; i < blockNums.length; i += 6) {
    const chunk = await Promise.all(
      blockNums.slice(i, i + 6).map((bn) => scanClient.getBlock({ blockNumber: bn })),
    );
    for (const b of chunk) tsByBlock.set(b.number, b.timestamp);
  }

  // --- replay state ------------------------------------------------------
  let cp = PRICE_SCALE; // oracle checkpoint price (1.0 at deploy)
  let cpAt = t0;
  let rate = INITIAL_RATE_BPS;
  let scale = INITIAL_TIME_SCALE;
  let cash = 0n;
  let tbill = 0n;
  let supply = 0n;

  const navPoints: NavPoint[] = [];
  const markers: FulfillMarker[] = [];
  const epochRows = new Map<number, EpochRow>();
  let depositRequestCount = 0;
  let redeemRequestCount = 0;

  const pushPoint = (t: bigint) => {
    const p = priceAt(t, cp, cpAt, rate, scale);
    const assets = cash + (tbill * p) / PRICE_SCALE;
    navPoints.push({
      t: Number(t),
      nav: Number(navPerShare(assets, supply)) / Number(ONE_SHARE),
      price: Number(p / 10n ** 12n) / 1e6, // 1e18 → 6-decimals float
    });
  };

  // Global sampling step: ~350 points across the whole life of the fund,
  // never denser than one per minute.
  const step = BigInt(Math.max(60, Math.floor(Number(now - t0) / 350)));
  let cursor = t0;

  const sampleUpTo = (t: bigint) => {
    while (cursor < t) {
      pushPoint(cursor);
      cursor += step;
    }
  };

  pushPoint(t0);
  cursor = t0 + step;

  for (const log of logs) {
    const t = tsByBlock.get(log.blockNumber)!;
    sampleUpTo(t);

    // Explicit per-event casts: TS narrowing of viem's multi-event `args`
    // union is version-fragile; runtime decoding is by topic, always exact.
    const args = log.args as Record<string, bigint>;
    switch (log.eventName) {
      case "RateSet": {
        pushPoint(t); // close the old segment exactly at the checkpoint
        cp = args.priceAtCheckpoint;
        cpAt = t;
        rate = args.rateBps;
        break;
      }
      case "TimeScaleSet": {
        pushPoint(t);
        cp = args.priceAtCheckpoint;
        cpAt = t;
        scale = args.timeScale;
        break;
      }
      case "ShockApplied": {
        pushPoint(t); // pre-shock point → the discontinuity stays vertical
        cp = args.newPrice;
        cpAt = t;
        break;
      }
      case "EpochFulfilled": {
        cash += args.totalDepositAssets - args.assetsSetAside;
        supply += args.sharesMinted - args.totalRedeemShares;
        markers.push({
          t: Number(t),
          nav: Number(args.navPerShare) / Number(ONE_SHARE),
          epochId: Number(args.epochId),
          txHash: log.transactionHash,
        });
        const row = epochRows.get(Number(args.epochId)) ?? {
          id: Number(args.epochId),
          totalDepositAssets: args.totalDepositAssets,
          totalRedeemShares: args.totalRedeemShares,
        };
        row.fulfilledAt = Number(t);
        row.sharesMinted = args.sharesMinted;
        row.assetsSetAside = args.assetsSetAside;
        row.navPerShare = args.navPerShare;
        row.fulfillTx = log.transactionHash;
        epochRows.set(row.id, row);
        pushPoint(t);
        break;
      }
      case "EpochClosed": {
        epochRows.set(Number(args.epochId), {
          id: Number(args.epochId),
          closedAt: Number(t),
          totalDepositAssets: args.totalDepositAssets,
          totalRedeemShares: args.totalRedeemShares,
        });
        break;
      }
      case "Invested": {
        cash -= args.assetsIn;
        tbill += args.tbillOut;
        break; // NAV-neutral by design — no visual step to record
      }
      case "Divested": {
        tbill -= args.tbillIn;
        cash += args.assetsOut;
        break;
      }
      case "DepositRequest":
        depositRequestCount++;
        break; // assets went to escrow — outside totalAssets, no NAV impact
      case "RedeemRequest":
        redeemRequestCount++;
        break; // shares moved to escrow — still in totalSupply, no NAV impact
    }
  }

  sampleUpTo(now);
  pushPoint(now);

  return {
    navPoints,
    markers,
    epochs: [...epochRows.values()].sort((a, b) => b.id - a.id),
    depositRequestCount,
    redeemRequestCount,
  };
}
