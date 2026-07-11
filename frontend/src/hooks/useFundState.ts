import { useReadContracts } from "wagmi";
import { ADDRESSES, ONE_SHARE } from "../config/addresses";
import { vaultAbi, oracleAbi, usdcAbi, tbillAbi } from "../config/abis";

const vault = { address: ADDRESSES.vault, abi: vaultAbi } as const;
const oracle = { address: ADDRESSES.oracle, abi: oracleAbi } as const;

export interface EpochInfo {
  id: bigint;
  totalDepositAssets: bigint;
  totalRedeemShares: bigint;
  sharesMinted: bigint;
  assetsSetAside: bigint;
  cutoffAt: bigint;
  fulfilledAt: bigint;
}

/** Live fund state, refreshed every block-ish (12s). Two stages: the second
 * reads the epoch structs once currentEpochId is known. */
export function useFundState() {
  const base = useReadContracts({
    contracts: [
      { ...vault, functionName: "totalAssets" },
      { ...vault, functionName: "totalSupply" },
      { ...vault, functionName: "convertToAssets", args: [ONE_SHARE] },
      { ...vault, functionName: "currentEpochId" },
      { address: ADDRESSES.usdc, abi: usdcAbi, functionName: "balanceOf", args: [ADDRESSES.vault] },
      { address: ADDRESSES.tbill, abi: tbillAbi, functionName: "balanceOf", args: [ADDRESSES.vault] },
      { address: ADDRESSES.usdc, abi: usdcAbi, functionName: "balanceOf", args: [ADDRESSES.escrow] },
      { ...vault, functionName: "balanceOf", args: [ADDRESSES.escrow] },
      { ...oracle, functionName: "price" },
      { ...oracle, functionName: "rateBps" },
      { ...oracle, functionName: "timeScale" },
    ],
    allowFailure: false,
    query: { refetchInterval: 12_000 },
  });

  const currentEpochId = base.data?.[3];

  const epochReads = useReadContracts({
    contracts: [
      { ...vault, functionName: "epochs", args: [currentEpochId ?? 0n] },
      // epochs(0) is the zero sentinel when current == 1 — harmless read
      { ...vault, functionName: "epochs", args: [currentEpochId ? currentEpochId - 1n : 0n] },
    ],
    allowFailure: false,
    query: { enabled: currentEpochId !== undefined, refetchInterval: 12_000 },
  });

  const toEpoch = (id: bigint, e: readonly [bigint, bigint, bigint, bigint, bigint, bigint]): EpochInfo => ({
    id,
    totalDepositAssets: e[0],
    totalRedeemShares: e[1],
    sharesMinted: e[2],
    assetsSetAside: e[3],
    cutoffAt: e[4],
    fulfilledAt: e[5],
  });

  const openEpoch =
    currentEpochId !== undefined && epochReads.data ? toEpoch(currentEpochId, epochReads.data[0]) : undefined;
  const prevEpoch =
    currentEpochId !== undefined && currentEpochId > 1n && epochReads.data
      ? toEpoch(currentEpochId - 1n, epochReads.data[1])
      : undefined;
  // I9: at most one epoch awaits settlement — it can only be current - 1.
  const awaitingEpoch = prevEpoch && prevEpoch.cutoffAt !== 0n && prevEpoch.fulfilledAt === 0n ? prevEpoch : undefined;

  return {
    isLoading: base.isLoading || epochReads.isLoading,
    error: base.error ?? epochReads.error,
    totalAssets: base.data?.[0],
    totalSupply: base.data?.[1],
    navPerShare: base.data?.[2],
    currentEpochId,
    cash: base.data?.[4],
    tbillBalance: base.data?.[5],
    escrowCash: base.data?.[6],
    escrowShares: base.data?.[7],
    price: base.data?.[8],
    rateBps: base.data?.[9],
    timeScale: base.data?.[10],
    openEpoch,
    awaitingEpoch,
  };
}
