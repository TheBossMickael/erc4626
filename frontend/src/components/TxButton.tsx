import { useEffect } from "react";
import { useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import type { Abi, Address, BaseError } from "viem";
import { ETHERSCAN } from "../config/addresses";

/** Loose write-call description. Extracting wagmi's own variables type
 * (`Parameters<typeof writeContract>[0]`) collapses its generics and drags
 * in a `chain?: Chain` field that conflicts with the config's literal
 * chain id — so the boundary is typed wide on purpose; `writeContract`
 * instantiates cleanly over a wide `Abi`. */
interface WriteParams {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
}

/** One transaction = one button + its own lifecycle line (wallet prompt →
 * pending → confirmed/error). On confirmation every query is invalidated:
 * simplest correct refresh, and cheap at this app's read volume. */
export function TxButton({
  label,
  params,
  disabled,
  disabledReason,
  variant = "primary",
  onConfirmed,
}: {
  label: string;
  params: WriteParams;
  disabled?: boolean;
  /** Shown as tooltip when disabled — always explain WHY an action is off. */
  disabledReason?: string;
  variant?: "primary" | "default" | "danger";
  onConfirmed?: () => void;
}) {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (receipt.isSuccess) {
      queryClient.invalidateQueries();
      onConfirmed?.();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [receipt.isSuccess]);

  const busy = isPending || (!!hash && receipt.isLoading);
  const cls = variant === "primary" ? "btn btn-primary" : variant === "danger" ? "btn btn-danger" : "btn";

  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
      <button
        className={cls}
        disabled={disabled || busy}
        title={disabled ? disabledReason : undefined}
        onClick={() => {
          reset();
          writeContract(params);
        }}
      >
        {busy && <span className="spinner" />}
        {isPending ? "Confirm in wallet…" : hash && receipt.isLoading ? "Pending…" : label}
      </button>
      {receipt.isSuccess && hash && (
        <span className="tx-note ok">
          Confirmed ·{" "}
          <a href={`${ETHERSCAN}/tx/${hash}`} target="_blank" rel="noreferrer">
            view tx
          </a>
        </span>
      )}
      {error && <span className="tx-note err">{(error as BaseError).shortMessage ?? error.message}</span>}
    </span>
  );
}
