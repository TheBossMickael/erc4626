import { useReadContracts } from "wagmi";
import { zeroAddress, type Address } from "viem";
import { ADDRESSES } from "../config/addresses";
import { vaultAbi, usdcAbi } from "../config/abis";

const vault = { address: ADDRESSES.vault, abi: vaultAbi } as const;
const usdc = { address: ADDRESSES.usdc, abi: usdcAbi } as const;

export type PendingPhase =
  | "none" // empty slot, or already rolled into claimable
  | "open" // queued in the OPEN epoch — still cancelable
  | "settling"; // epoch closed, order binding, awaiting fulfillEpoch()

/** Where a non-empty pending slot stands. Complete without extra reads
 * thanks to invariant I9 (the only possibly-CLOSED-unfulfilled epoch is the
 * one awaiting settlement): anything older HAS been fulfilled, and the
 * claimable getters already view-simulate the roll. */
export function pendingPhase(
  slot: { pendingAmount: bigint; epochId: bigint } | undefined,
  currentEpochId: bigint | undefined,
  awaitingEpochId: bigint | undefined,
): PendingPhase {
  if (!slot || slot.pendingAmount === 0n || currentEpochId === undefined) return "none";
  if (slot.epochId === currentEpochId) return "open";
  if (awaitingEpochId !== undefined && slot.epochId === awaitingEpochId) return "settling";
  return "none";
}

/** Everything the Invest view needs about the connected controller. */
export function useUserPosition(address: Address | undefined) {
  const a = address ?? zeroAddress;
  const reads = useReadContracts({
    contracts: [
      { ...usdc, functionName: "balanceOf", args: [a] },
      { ...usdc, functionName: "allowance", args: [a, ADDRESSES.vault] },
      { ...vault, functionName: "balanceOf", args: [a] },
      { ...vault, functionName: "depositSlot", args: [a] },
      { ...vault, functionName: "redeemSlot", args: [a] },
      { ...vault, functionName: "maxDeposit", args: [a] },
      { ...vault, functionName: "maxMint", args: [a] },
      { ...vault, functionName: "maxWithdraw", args: [a] },
      { ...vault, functionName: "maxRedeem", args: [a] },
    ],
    allowFailure: false,
    query: { enabled: !!address, refetchInterval: 12_000 },
  });

  const slotOf = (s: readonly [bigint, bigint] | undefined) =>
    s ? { pendingAmount: s[0], epochId: s[1] } : undefined;

  return {
    isLoading: reads.isLoading,
    error: reads.error,
    usdcBalance: reads.data?.[0],
    usdcAllowance: reads.data?.[1],
    shareBalance: reads.data?.[2],
    depositSlot: slotOf(reads.data?.[3]),
    redeemSlot: slotOf(reads.data?.[4]),
    /** deposit side: fulfilled assets whose shares are claimable */
    claimableDepositAssets: reads.data?.[5],
    /** …and the shares those assets earned */
    claimableDepositShares: reads.data?.[6],
    /** redeem side: payout assets claimable */
    claimableRedeemAssets: reads.data?.[7],
    /** …for that many fulfilled shares */
    claimableRedeemShares: reads.data?.[8],
  };
}
