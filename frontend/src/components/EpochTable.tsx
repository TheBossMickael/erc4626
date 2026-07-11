import type { EpochRow } from "../lib/navHistory";
import type { EpochInfo } from "../hooks/useFundState";
import { ETHERSCAN } from "../config/addresses";
import { fmtAmount, fmtNav, fmtTime } from "../lib/format";

/** Settlement history — the on-chain proof of the core invariant: one strike
 * NAV per epoch, applied to every request of that epoch. The OPEN epoch is
 * injected live on top (it has no events yet); closed-awaiting rows come from
 * their EpochClosed event. */
export function EpochTable({ history, open }: { history: EpochRow[]; open?: EpochInfo }) {
  if (!open && history.length === 0) {
    return <div className="empty">No epochs yet.</div>;
  }
  return (
    <div className="table-wrap">
      <table className="data">
        <thead>
          <tr>
            <th>Epoch</th>
            <th>Status</th>
            <th>Deposits (USDC)</th>
            <th>Redemptions (fTBILL)</th>
            <th>Strike NAV</th>
            <th>Settled</th>
            <th>Tx</th>
          </tr>
        </thead>
        <tbody>
          {open && (
            <tr>
              <td className="strong">#{open.id.toString()}</td>
              <td>
                <span className="badge open">Open</span>
              </td>
              <td>{fmtAmount(open.totalDepositAssets)}</td>
              <td>{fmtAmount(open.totalRedeemShares)}</td>
              <td>—</td>
              <td>accepting requests</td>
              <td>—</td>
            </tr>
          )}
          {history.map((e) => (
            <tr key={e.id}>
              <td className="strong">#{e.id}</td>
              <td>
                <span className={e.fulfilledAt ? "badge fulfilled" : "badge closed"}>
                  {e.fulfilledAt ? "Fulfilled" : "Closed"}
                </span>
              </td>
              <td>{fmtAmount(e.totalDepositAssets)}</td>
              <td>{fmtAmount(e.totalRedeemShares)}</td>
              <td>{e.navPerShare !== undefined ? fmtNav(e.navPerShare) : "—"}</td>
              <td>{e.fulfilledAt ? fmtTime(e.fulfilledAt) : "awaiting settlement"}</td>
              <td>
                {e.fulfillTx ? (
                  <a href={`${ETHERSCAN}/tx/${e.fulfillTx}`} target="_blank" rel="noreferrer">
                    ↗
                  </a>
                ) : (
                  "—"
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
