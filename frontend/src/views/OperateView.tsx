import { useState } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { ADDRESSES, PRICE_SCALE } from "../config/addresses";
import { vaultAbi, oracleAbi } from "../config/abis";
import { useFundState } from "../hooks/useFundState";
import { useRoles } from "../hooks/useRoles";
import { AmountInput } from "../components/AmountInput";
import { TxButton } from "../components/TxButton";
import { fmtAmount, fmtBps, fmtNav, fmtPrice18, fmtTime, parseAmount } from "../lib/format";

const vault = { address: ADDRESSES.vault, abi: vaultAbi } as const;
const oracle = { address: ADDRESSES.oracle, abi: oracleAbi } as const;

/** Transfer-agent console: turn the epoch cycle, manage the portfolio, drive
 * the oracle. Fully visible to everyone (that's the demo); write actions
 * activate only for the on-chain MANAGER_ROLE / oracle owner. */
export function OperateView() {
  const { address } = useAccount();
  const fund = useFundState();
  const roles = useRoles(address);

  const [investIn, setInvestIn] = useState("");
  const [divestIn, setDivestIn] = useState("");
  const [rateIn, setRateIn] = useState("");
  const [shockIn, setShockIn] = useState("");

  const awaiting = fund.awaitingEpoch;

  // Settlement preview — live conversion of the closed epoch's batch. The
  // exact strike happens inside fulfillEpoch(); this is the same math read a
  // few seconds earlier.
  const preview = useReadContracts({
    contracts: [
      { ...vault, functionName: "convertToShares", args: [awaiting?.totalDepositAssets ?? 0n] },
      { ...vault, functionName: "convertToAssets", args: [awaiting?.totalRedeemShares ?? 0n] },
    ],
    allowFailure: false,
    query: { enabled: !!awaiting, refetchInterval: 12_000 },
  });
  const estSharesMinted = awaiting ? preview.data?.[0] : undefined;
  const estAssetsSetAside = awaiting ? preview.data?.[1] : undefined;

  // Cash check replicating fulfillEpoch's revert condition: payout must be
  // covered by vault cash after netting the incoming deposit cash.
  const available =
    fund.cash !== undefined && awaiting ? fund.cash + awaiting.totalDepositAssets : undefined;
  const shortfall =
    estAssetsSetAside !== undefined && available !== undefined && estAssetsSetAside > available
      ? estAssetsSetAside - available
      : 0n;
  // Suggested divest: shortfall at current price, +0.5% for accrual drift
  // between this read and the manager's transaction landing.
  const suggestedDivest =
    shortfall > 0n && fund.price !== undefined ? (shortfall * PRICE_SCALE * 1005n) / (fund.price * 1000n) : 0n;

  const investAmt = parseAmount(investIn);
  const divestAmt = parseAmount(divestIn);
  const investPreview =
    investAmt !== null && fund.price !== undefined && fund.price > 0n ? (investAmt * PRICE_SCALE) / fund.price : null;
  const divestPreview = divestAmt !== null && fund.price !== undefined ? (divestAmt * fund.price) / PRICE_SCALE : null;

  const rateVal = /^\d+$/.test(rateIn.trim()) ? BigInt(rateIn.trim()) : null;
  const shockVal = /^[+-]?\d+$/.test(shockIn.trim()) ? BigInt(shockIn.trim().replace("+", "")) : null;

  const notManager = !roles.isManager;
  const managerReason = address
    ? "Connected address does not hold MANAGER_ROLE"
    : "Connect the manager wallet to operate";
  const notOwner = !roles.isOracleOwner;
  const ownerReason = address ? "Connected address is not the oracle owner" : "Connect the oracle owner wallet";

  return (
    <div className="stack">
      <div className="callout info">
        This console is deliberately public — watching the transfer agent work IS the demo. Buttons activate only for
        the on-chain roles:{" "}
        {address ? (
          <>
            connected as{" "}
            <strong>
              {[roles.isManager && "Manager", roles.isAdmin && "Admin", roles.isOracleOwner && "Oracle owner"]
                .filter(Boolean)
                .join(" · ") || "no role (read-only)"}
            </strong>
            . A keeper bot also holds MANAGER_ROLE and turns the cycle every ~30 min when requests are pending.
          </>
        ) : (
          <>no wallet connected (read-only). A keeper bot turns the cycle every ~30 min when requests are pending.</>
        )}
      </div>

      <div className="grid cols-2">
        {/* ------------------------------------------------ epoch machine */}
        <div className="stack">
          <div className="card">
            <h3 className="card-title">Epoch #{fund.openEpoch?.id.toString() ?? "—"} — open</h3>
            <p className="card-sub">Requests are accumulating; cut-off makes them binding and opens the next epoch.</p>
            <dl className="kv">
              <dt>Pending deposits</dt>
              <dd className="strong">{fmtAmount(fund.openEpoch?.totalDepositAssets)} USDC</dd>
              <dt>Pending redemptions</dt>
              <dd className="strong">{fmtAmount(fund.openEpoch?.totalRedeemShares)} fTBILL</dd>
            </dl>
            <div className="actions">
              <TxButton
                label="Close epoch (cut-off)"
                disabled={notManager || !!awaiting}
                disabledReason={
                  notManager ? managerReason : "Previous epoch must be fulfilled first — at most one epoch settles at a time"
                }
                params={{ ...vault, functionName: "closeEpoch" }}
              />
            </div>
          </div>

          <div className="card">
            <h3 className="card-title">
              {awaiting ? `Epoch #${awaiting.id.toString()} — closed, awaiting settlement` : "Settlement"}
            </h3>
            {!awaiting && <p className="card-sub">No epoch awaits settlement. Close the open epoch first.</p>}
            {awaiting && (
              <>
                <p className="card-sub">
                  Cut-off at {fmtTime(awaiting.cutoffAt)}. Fulfilling strikes ONE NAV and settles the whole batch at
                  it.
                </p>
                <dl className="kv">
                  <dt>Binding deposits</dt>
                  <dd className="strong">{fmtAmount(awaiting.totalDepositAssets)} USDC</dd>
                  <dt>Binding redemptions</dt>
                  <dd className="strong">{fmtAmount(awaiting.totalRedeemShares)} fTBILL</dd>
                  <dt>Strike NAV (live estimate)</dt>
                  <dd>{fmtNav(fund.navPerShare)}</dd>
                  <dt>≈ shares to mint</dt>
                  <dd>{fmtAmount(estSharesMinted)} fTBILL</dd>
                  <dt>≈ cash to set aside</dt>
                  <dd>{fmtAmount(estAssetsSetAside)} USDC</dd>
                </dl>
                {shortfall > 0n && (
                  <div className="callout crit">
                    <strong>Insufficient cash:</strong> payout exceeds vault cash + incoming deposits by{" "}
                    {fmtAmount(shortfall)} USDC. Sell T-Bills first — like a real fund funding redemptions.
                    <div className="actions">
                      <TxButton
                        label={`Divest ${fmtAmount(suggestedDivest)} TBILL`}
                        variant="danger"
                        disabled={notManager}
                        disabledReason={managerReason}
                        params={{ ...vault, functionName: "divest", args: [suggestedDivest] }}
                      />
                    </div>
                  </div>
                )}
                <div className="actions">
                  <TxButton
                    label="Fulfill epoch (strike NAV & settle)"
                    disabled={notManager || shortfall > 0n}
                    disabledReason={notManager ? managerReason : "Divest first — vault cash cannot cover the payout"}
                    params={{ ...vault, functionName: "fulfillEpoch" }}
                  />
                </div>
              </>
            )}
          </div>
        </div>

        {/* --------------------------------------------------- portfolio */}
        <div className="stack">
          <div className="card">
            <h3 className="card-title">Portfolio management</h3>
            <p className="card-sub">
              Idle cash {fmtAmount(fund.cash)} USDC · T-Bills {fmtAmount(fund.tbillBalance)} TBILL. Both legs trade at
              the oracle price — NAV-neutral by construction.
            </p>
            <div className="field">
              <label>Invest idle cash</label>
              <AmountInput value={investIn} onChange={setInvestIn} unit="USDC" max={fund.cash} />
            </div>
            <div className="actions">
              <TxButton
                label={investPreview !== null ? `Invest → ≈ ${fmtAmount(investPreview)} TBILL` : "Invest"}
                disabled={notManager || investAmt === null || investAmt === 0n}
                disabledReason={notManager ? managerReason : "Enter an amount"}
                params={{ ...vault, functionName: "invest", args: [investAmt ?? 0n] }}
                onConfirmed={() => setInvestIn("")}
              />
            </div>
            <div className="field" style={{ marginTop: 14 }}>
              <label>Divest T-Bills</label>
              <AmountInput value={divestIn} onChange={setDivestIn} unit="TBILL" max={fund.tbillBalance} />
            </div>
            <div className="actions">
              <TxButton
                label={divestPreview !== null ? `Divest → ≈ ${fmtAmount(divestPreview)} USDC` : "Divest"}
                disabled={notManager || divestAmt === null || divestAmt === 0n}
                disabledReason={notManager ? managerReason : "Enter an amount"}
                params={{ ...vault, functionName: "divest", args: [divestAmt ?? 0n] }}
                onConfirmed={() => setDivestIn("")}
              />
            </div>
          </div>

          <div className="card">
            <h3 className="card-title">NAV oracle</h3>
            <p className="card-sub">
              Price {fmtPrice18(fund.price)} USDC · rate {fmtBps(fund.rateBps)} · time ×
              {fund.timeScale?.toString() ?? "—"}. Stands in for the fund accountant's NAV feed — owner-only.
            </p>
            <div className="field">
              <label>Annualized rate (bps, max 2000)</label>
              <AmountInput value={rateIn} onChange={setRateIn} unit="bps" placeholder="450" />
            </div>
            <div className="actions">
              <TxButton
                label="Set rate"
                variant="default"
                disabled={notOwner || rateVal === null || rateVal > 2000n}
                disabledReason={notOwner ? ownerReason : "Whole bps, 0–2000"}
                params={{ ...oracle, functionName: "setRateBps", args: [rateVal ?? 0n] }}
                onConfirmed={() => setRateIn("")}
              />
            </div>
            <div className="field" style={{ marginTop: 14 }}>
              <label>Mark-to-market shock (bps, ±5000)</label>
              <AmountInput value={shockIn} onChange={setShockIn} unit="bps" placeholder="-50" />
            </div>
            <div className="actions">
              <button className="btn btn-sm" onClick={() => setShockIn("-50")}>
                −50 bps
              </button>
              <button className="btn btn-sm" onClick={() => setShockIn("-200")}>
                −200 bps
              </button>
              <button className="btn btn-sm" onClick={() => setShockIn("100")}>
                +100 bps
              </button>
              <TxButton
                label="Apply shock"
                variant="danger"
                disabled={notOwner || shockVal === null || shockVal === 0n || shockVal <= -5000n || shockVal > 5000n}
                disabledReason={notOwner ? ownerReason : "Signed bps within ±5000"}
                params={{ ...oracle, functionName: "applyShock", args: [shockVal ?? 0n] }}
                onConfirmed={() => setShockIn("")}
              />
            </div>
            <div className="callout warn" style={{ marginTop: 12 }}>
              A shock landing between cut-off and settlement hits already-binding orders — deliberate: that is exactly
              how real funds work, and the demo's best talking point.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
