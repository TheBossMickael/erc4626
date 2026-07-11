import { useState } from "react";
import { useAccount } from "wagmi";
import { ADDRESSES } from "../config/addresses";
import { vaultAbi, usdcAbi } from "../config/abis";
import { useFundState } from "../hooks/useFundState";
import { useUserPosition, pendingPhase } from "../hooks/useUserPosition";
import { Stat } from "../components/Stat";
import { AmountInput } from "../components/AmountInput";
import { TxButton } from "../components/TxButton";
import { fmtAmount, fmtNav, parseAmount } from "../lib/format";

const vault = { address: ADDRESSES.vault, abi: vaultAbi } as const;
const usdc = { address: ADDRESSES.usdc, abi: usdcAbi } as const;

/** Self-service investor flow: faucet → request deposit → claim shares →
 * request redeem → claim cash. Fully visible without a wallet; actions
 * activate on connection. */
export function InvestView() {
  const { address } = useAccount();
  const fund = useFundState();
  const pos = useUserPosition(address);

  const [faucetIn, setFaucetIn] = useState("10000");
  const [depositIn, setDepositIn] = useState("");
  const [redeemIn, setRedeemIn] = useState("");

  const faucetAmt = parseAmount(faucetIn);
  const depositAmt = parseAmount(depositIn);
  const redeemAmt = parseAmount(redeemIn);

  const depPhase = pendingPhase(pos.depositSlot, fund.currentEpochId, fund.awaitingEpoch?.id);
  const redPhase = pendingPhase(pos.redeemSlot, fund.currentEpochId, fund.awaitingEpoch?.id);

  const needsApproval =
    depositAmt !== null && pos.usdcAllowance !== undefined && pos.usdcAllowance < depositAmt;

  const shareValue =
    pos.shareBalance !== undefined && fund.navPerShare !== undefined
      ? (pos.shareBalance * fund.navPerShare) / 10n ** 6n
      : undefined;

  const noWallet = !address;
  const walletReason = "Connect a wallet first";

  return (
    <div className="stack">
      {noWallet && (
        <div className="callout info">
          <strong>Read-only.</strong> Connect MetaMask (top right) on Sepolia to try the full cycle yourself — mint
          test USDC below, request a deposit, watch it settle at the next epoch (~30 min), claim your shares, and
          redeem with yield.
        </div>
      )}

      <div className="grid cols-3">
        <Stat label="Your USDC" value={fmtAmount(pos.usdcBalance)} sub="settlement asset — mint more below" />
        <Stat
          label="Your fTBILL shares"
          value={fmtAmount(pos.shareBalance)}
          sub={`≈ ${fmtAmount(shareValue)} USDC at current NAV`}
        />
        <Stat label="Fund NAV per share" value={fmtNav(fund.navPerShare)} sub="your requests settle at a FUTURE strike" />
      </div>

      <div className="grid cols-2">
        {/* ------------------------------------------------ deposit side */}
        <div className="stack">
          <div className="card">
            <h3 className="card-title">1 · Get test USDC</h3>
            <p className="card-sub">
              MockUSDC has an open faucet. You also need Sepolia ETH for gas —{" "}
              <a href="https://cloud.google.com/application/web3/faucet/ethereum/sepolia" target="_blank" rel="noreferrer">
                Google faucet
              </a>{" "}
              ·{" "}
              <a href="https://www.alchemy.com/faucets/ethereum-sepolia" target="_blank" rel="noreferrer">
                Alchemy faucet
              </a>
              .
            </p>
            <div className="field">
              <label>Amount</label>
              <AmountInput value={faucetIn} onChange={setFaucetIn} unit="USDC" />
            </div>
            <TxButton
              label="Mint test USDC"
              variant="default"
              disabled={noWallet || faucetAmt === null || faucetAmt === 0n}
              disabledReason={noWallet ? walletReason : "Enter an amount"}
              params={{ ...usdc, functionName: "mint", args: [address ?? ADDRESSES.vault, faucetAmt ?? 0n] }}
            />
          </div>

          <div className="card">
            <h3 className="card-title">2 · Request a deposit</h3>
            <p className="card-sub">
              USDC moves to escrow now; shares are minted at the next settlement's strike NAV — the price does not
              exist yet, by design.
            </p>
            <div className="field">
              <label>Amount</label>
              <AmountInput value={depositIn} onChange={setDepositIn} unit="USDC" max={pos.usdcBalance} />
            </div>
            <div className="actions">
              {needsApproval ? (
                <TxButton
                  label={`Approve ${fmtAmount(depositAmt ?? 0n)} USDC`}
                  disabled={noWallet || depositAmt === null || depositAmt === 0n}
                  disabledReason={noWallet ? walletReason : "Enter a valid amount"}
                  params={{ ...usdc, functionName: "approve", args: [ADDRESSES.vault, depositAmt ?? 0n] }}
                />
              ) : (
                <TxButton
                  label="Request deposit"
                  disabled={
                    noWallet ||
                    depositAmt === null ||
                    depositAmt === 0n ||
                    depPhase === "settling" ||
                    (pos.usdcBalance !== undefined && depositAmt !== null && depositAmt > pos.usdcBalance)
                  }
                  disabledReason={
                    noWallet
                      ? walletReason
                      : depPhase === "settling"
                        ? "Your previous request is binding in the closed epoch — wait for settlement"
                        : "Enter a valid amount within your balance"
                  }
                  params={{
                    ...vault,
                    functionName: "requestDeposit",
                    args: [depositAmt ?? 0n, address ?? ADDRESSES.vault, address ?? ADDRESSES.vault],
                  }}
                  onConfirmed={() => setDepositIn("")}
                />
              )}
            </div>
            {depPhase === "open" && pos.depositSlot && (
              <div className="callout warn">
                <strong>{fmtAmount(pos.depositSlot.pendingAmount)} USDC queued</strong> in open epoch #
                {pos.depositSlot.epochId.toString()} — cancelable until cut-off.
                <div className="actions">
                  <TxButton
                    label="Cancel request"
                    variant="danger"
                    params={{ ...vault, functionName: "cancelDepositRequest", args: [address ?? ADDRESSES.vault] }}
                  />
                </div>
              </div>
            )}
            {depPhase === "settling" && pos.depositSlot && (
              <div className="callout info">
                <strong>{fmtAmount(pos.depositSlot.pendingAmount)} USDC binding</strong> in closed epoch #
                {pos.depositSlot.epochId.toString()} — awaiting settlement (~30 min cycle). No longer cancelable, like
                a real fund order after cut-off.
              </div>
            )}
          </div>

          {pos.claimableDepositAssets !== undefined && pos.claimableDepositAssets > 0n && (
            <div className="card">
              <h3 className="card-title">3 · Claim your shares</h3>
              <p className="card-sub">Your deposit settled. Claiming just releases what fulfillment already priced.</p>
              <div className="callout good">
                {fmtAmount(pos.claimableDepositAssets)} USDC settled →{" "}
                <strong>{fmtAmount(pos.claimableDepositShares)} fTBILL</strong> claimable
              </div>
              <TxButton
                label="Claim shares"
                params={{
                  ...vault,
                  functionName: "deposit",
                  args: [pos.claimableDepositAssets, address ?? ADDRESSES.vault, address ?? ADDRESSES.vault],
                }}
              />
            </div>
          )}
        </div>

        {/* ------------------------------------------------- redeem side */}
        <div className="stack">
          <div className="card">
            <h3 className="card-title">4 · Request a redemption</h3>
            <p className="card-sub">
              Shares move to escrow now (still outstanding until settlement); cash is set aside at the next strike
              NAV.
            </p>
            <div className="field">
              <label>Shares</label>
              <AmountInput value={redeemIn} onChange={setRedeemIn} unit="fTBILL" max={pos.shareBalance} />
            </div>
            <TxButton
              label="Request redemption"
              disabled={
                noWallet ||
                redeemAmt === null ||
                redeemAmt === 0n ||
                redPhase === "settling" ||
                (pos.shareBalance !== undefined && redeemAmt !== null && redeemAmt > pos.shareBalance)
              }
              disabledReason={
                noWallet
                  ? walletReason
                  : redPhase === "settling"
                    ? "Your previous request is binding in the closed epoch — wait for settlement"
                    : "Enter a valid amount within your share balance"
              }
              params={{
                ...vault,
                functionName: "requestRedeem",
                args: [redeemAmt ?? 0n, address ?? ADDRESSES.vault, address ?? ADDRESSES.vault],
              }}
              onConfirmed={() => setRedeemIn("")}
            />
            {redPhase === "open" && pos.redeemSlot && (
              <div className="callout warn">
                <strong>{fmtAmount(pos.redeemSlot.pendingAmount)} fTBILL queued</strong> in open epoch #
                {pos.redeemSlot.epochId.toString()} — cancelable until cut-off.
                <div className="actions">
                  <TxButton
                    label="Cancel request"
                    variant="danger"
                    params={{ ...vault, functionName: "cancelRedeemRequest", args: [address ?? ADDRESSES.vault] }}
                  />
                </div>
              </div>
            )}
            {redPhase === "settling" && pos.redeemSlot && (
              <div className="callout info">
                <strong>{fmtAmount(pos.redeemSlot.pendingAmount)} fTBILL binding</strong> in closed epoch #
                {pos.redeemSlot.epochId.toString()} — awaiting settlement.
              </div>
            )}
          </div>

          {pos.claimableRedeemShares !== undefined && pos.claimableRedeemShares > 0n && (
            <div className="card">
              <h3 className="card-title">5 · Claim your cash</h3>
              <p className="card-sub">Your redemption settled at its epoch's strike NAV.</p>
              <div className="callout good">
                {fmtAmount(pos.claimableRedeemShares)} fTBILL settled →{" "}
                <strong>{fmtAmount(pos.claimableRedeemAssets)} USDC</strong> claimable
              </div>
              <TxButton
                label="Claim USDC"
                params={{
                  ...vault,
                  functionName: "redeem",
                  args: [pos.claimableRedeemShares, address ?? ADDRESSES.vault, address ?? ADDRESSES.vault],
                }}
              />
            </div>
          )}

          <div className="card">
            <h3 className="card-title">Why the wait?</h3>
            <p className="card-sub">
              This models an institutional fund: T-Bills settle T+1 on market hours, so the fund batches orders into
              epochs and settles each batch at one forward-struck NAV. Everyone in an epoch gets the same price —
              timing inside an epoch buys nothing. With accelerated demo time, one settlement cycle (~30 min) spans a
              simulated month, and yield is visible within the hour: deposit, wait one cycle, claim, redeem — you
              come out with more USDC than you put in.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
