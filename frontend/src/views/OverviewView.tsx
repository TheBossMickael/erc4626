import { useFundState } from "../hooks/useFundState";
import { useChainHistory } from "../hooks/useChainHistory";
import { Stat } from "../components/Stat";
import { NavChart } from "../components/NavChart";
import { EpochTable } from "../components/EpochTable";
import { HowItWorks } from "../components/HowItWorks";
import { fmtAmount, fmtBps, fmtNav, fmtPrice18 } from "../lib/format";

/** Read-only landing: the fund at a glance — NAV, AUM, portfolio split,
 * settlement history. Everything a visitor without a wallet can explore. */
export function OverviewView() {
  const fund = useFundState();
  const history = useChainHistory();

  const tbillValue =
    fund.tbillBalance !== undefined && fund.price !== undefined
      ? (fund.tbillBalance * fund.price) / 10n ** 18n
      : undefined;
  const pct = (part: bigint | undefined) =>
    part !== undefined && fund.totalAssets !== undefined && fund.totalAssets > 0n
      ? `${((Number(part) / Number(fund.totalAssets)) * 100).toFixed(1)}%`
      : "—";

  return (
    <div className="stack">
      <div className="grid cols-4">
        <Stat
          label="NAV per share"
          value={fmtNav(fund.navPerShare)}
          sub={<span>USDC per fTBILL · struck live</span>}
        />
        <Stat label="Fund AUM" value={fmtAmount(fund.totalAssets)} sub="USDC — cash + T-Bills at oracle price" />
        <Stat
          label="T-Bill yield"
          value={fmtBps(fund.rateBps)}
          sub={`annualized · time ×${fund.timeScale?.toString() ?? "—"} (1 min ≈ 1 day)`}
        />
        <Stat
          label="Current epoch"
          value={`#${fund.currentEpochId?.toString() ?? "—"}`}
          sub={
            fund.awaitingEpoch
              ? `epoch #${fund.awaitingEpoch.id} awaiting settlement`
              : "open — accepting requests"
          }
        />
      </div>

      <div className="card">
        <h3 className="card-title">NAV timeline</h3>
        <p className="card-sub">
          Reconstructed client-side by replaying contract events — every marker is an epoch settlement at its exact
          strike NAV. The dashed benchmark is the oracle's T-Bill price; the gap is cash drag.
        </p>
        {history.isLoading && <div className="empty">Replaying on-chain history…</div>}
        {history.isError && (
          <div className="empty">
            Could not load history from the RPC — {(history.error as Error)?.message?.slice(0, 220) ?? "unknown error"}
          </div>
        )}
        {history.data && <NavChart points={history.data.navPoints} markers={history.data.markers} />}
      </div>

      <div className="grid cols-2">
        <div className="card">
          <h3 className="card-title">Portfolio</h3>
          <p className="card-sub">What the fund actually holds.</p>
          <dl className="kv">
            <dt>Idle cash</dt>
            <dd className="strong">
              {fmtAmount(fund.cash)} USDC · {pct(fund.cash)}
            </dd>
            <dt>T-Bill position</dt>
            <dd className="strong">
              {fmtAmount(fund.tbillBalance)} TBILL ≈ {fmtAmount(tbillValue)} USDC · {pct(tbillValue)}
            </dd>
            <dt>Oracle T-Bill price</dt>
            <dd>{fmtPrice18(fund.price)} USDC</dd>
            <dt>Shares outstanding</dt>
            <dd>{fmtAmount(fund.totalSupply)} fTBILL</dd>
          </dl>
        </div>
        <div className="card">
          <h3 className="card-title">Escrow (segregated)</h3>
          <p className="card-sub">
            Pending and claimable funds sit in a separate contract — physically outside the fund's NAV, so pending
            cash can never inflate the price its own depositors pay.
          </p>
          <dl className="kv">
            <dt>Escrowed cash</dt>
            <dd className="strong">{fmtAmount(fund.escrowCash)} USDC</dd>
            <dt>Escrowed shares</dt>
            <dd className="strong">{fmtAmount(fund.escrowShares)} fTBILL</dd>
            <dt>Requests processed</dt>
            <dd>
              {history.data
                ? `${history.data.depositRequestCount} deposits · ${history.data.redeemRequestCount} redemptions`
                : "—"}
            </dd>
          </dl>
        </div>
      </div>

      <div className="card">
        <h3 className="card-title">Settlement history</h3>
        <p className="card-sub">One strike NAV per epoch, applied to every request of that epoch — the core invariant.</p>
        <EpochTable history={history.data?.epochs ?? []} open={fund.openEpoch} />
      </div>

      <HowItWorks />
    </div>
  );
}
