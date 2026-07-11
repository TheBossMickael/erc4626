import { ADDRESSES, ETHERSCAN } from "../config/addresses";
import { shortAddr } from "../lib/format";

const CONTRACTS: { name: string; addr: string; role: string }[] = [
  { name: "RWAVault (fTBILL)", addr: ADDRESSES.vault, role: "ERC-4626 fund + ERC-7540 async layer + epoch machine" },
  { name: "Escrow", addr: ADDRESSES.escrow, role: "Custody of pending & claimable funds — outside the fund's NAV" },
  { name: "NAVOracle", addr: ADDRESSES.oracle, role: "T-Bill price feed (accelerated time for the demo)" },
  { name: "TBillToken", addr: ADDRESSES.tbill, role: "Mock 13-week T-Bill with its own primary market" },
  { name: "MockUSDC", addr: ADDRESSES.usdc, role: "Settlement asset — open faucet, mint what you need" },
];

/** The recruiter-facing explainer: why a T-Bill fund cannot settle
 * synchronously, and how ERC-7540 models that on-chain. */
export function HowItWorks() {
  return (
    <div className="card">
      <h3 className="card-title">How it works</h3>
      <p className="card-sub">
        A tokenized T-Bill fund cannot settle deposits and redemptions instantly: real-world assets trade on market
        hours with T+1 settlement, and pricing intraday flows at a stale NAV would let fast traders dilute everyone
        else. This vault is standard <strong>ERC-4626</strong> for accounting, wrapped in{" "}
        <strong>ERC-7540 asynchronous flows</strong>: requests queue in epochs, a transfer agent settles each epoch at
        one forward-struck price, then investors claim.
      </p>

      <div className="flow">
        <div className="step">
          <span className="n">1</span>
          <h4>Request</h4>
          <p>
            <code>requestDeposit</code> / <code>requestRedeem</code> — funds move to escrow immediately, into the open
            epoch. Cancelable until cut-off.
          </p>
        </div>
        <div className="step">
          <span className="n">2</span>
          <h4>Cut-off</h4>
          <p>
            <code>closeEpoch</code> — the epoch's orders become binding, a fresh epoch opens. No price exists yet.
          </p>
        </div>
        <div className="step">
          <span className="n">3</span>
          <h4>Fulfill</h4>
          <p>
            <code>fulfillEpoch</code> — one NAV is struck and the whole batch settles at it: deposits mint shares,
            redemptions set cash aside.
          </p>
        </div>
        <div className="step">
          <span className="n">4</span>
          <h4>Claim</h4>
          <p>
            <code>deposit</code> / <code>redeem</code> release what fulfillment produced — pro-rata, at the recorded
            epoch result.
          </p>
        </div>
      </div>

      <div className="callout info">
        <strong>Core invariant:</strong> every request fulfilled in the same epoch settles at exactly the same NAV per
        share — intra-epoch timing buys nothing, by construction. The settlement history below is the on-chain proof:
        one strike NAV per epoch.
      </div>

      <div className="callout">
        <strong>Time is accelerated:</strong> the oracle simulates 1 day per real minute, so a 4.5% annualized T-Bill
        yield is actually visible — roughly +0.74% per real hour. Settlement runs on a ~30-minute cycle (one simulated
        month) when there are pending requests.
      </div>

      <h3 className="card-title" style={{ marginTop: 18 }}>
        Contracts (Sepolia)
      </h3>
      <div className="table-wrap">
        <table className="data">
          <thead>
            <tr>
              <th>Contract</th>
              <th style={{ textAlign: "left" }}>Role</th>
              <th>Address</th>
            </tr>
          </thead>
          <tbody>
            {CONTRACTS.map((c) => (
              <tr key={c.addr}>
                <td className="strong">{c.name}</td>
                <td style={{ textAlign: "left" }}>{c.role}</td>
                <td>
                  <a className="addr" href={`${ETHERSCAN}/address/${c.addr}`} target="_blank" rel="noreferrer">
                    {shortAddr(c.addr)}
                  </a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
