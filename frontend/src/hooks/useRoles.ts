import { useReadContracts } from "wagmi";
import { zeroAddress, type Address } from "viem";
import { ADDRESSES } from "../config/addresses";
import { vaultAbi, oracleAbi } from "../config/abis";
import { MANAGER_ROLE, DEFAULT_ADMIN_ROLE } from "../config/wagmi";

/** Role standing of the connected address — read on-chain, never inferred
 * from hardcoded addresses, so a granted keeper or a transferred ownership
 * shows up correctly. */
export function useRoles(address: Address | undefined) {
  const a = address ?? zeroAddress;
  const reads = useReadContracts({
    contracts: [
      { address: ADDRESSES.vault, abi: vaultAbi, functionName: "hasRole", args: [MANAGER_ROLE, a] },
      { address: ADDRESSES.vault, abi: vaultAbi, functionName: "hasRole", args: [DEFAULT_ADMIN_ROLE, a] },
      { address: ADDRESSES.oracle, abi: oracleAbi, functionName: "owner" },
    ],
    allowFailure: false,
    query: { enabled: !!address, refetchInterval: 60_000 },
  });

  return {
    isManager: reads.data?.[0] ?? false,
    isAdmin: reads.data?.[1] ?? false,
    isOracleOwner: !!address && reads.data?.[2]?.toLowerCase() === address.toLowerCase(),
  };
}
