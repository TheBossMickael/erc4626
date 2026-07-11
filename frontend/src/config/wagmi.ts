import { http, createConfig } from "wagmi";
import { sepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { keccak256, stringToBytes } from "viem";

// Injected-only on purpose (F7): MetaMask-first demo, no WalletConnect
// project id, no external dependency, and the connect button styles like
// every other control of the dashboard.
export const wagmiConfig = createConfig({
  chains: [sepolia],
  connectors: [injected()],
  transports: {
    // Falls back to the chain's public RPC when VITE_RPC_URL is unset —
    // fine for casual browsing; the event scan behind the NAV timeline is
    // chunk-retried so rate-limited public endpoints still succeed.
    // NO JSON-RPC batching: Alchemy's free tier rejects batched frames with
    // -32600 ("JSON is not a valid request object"), and wagmi already
    // aggregates contract reads into ONE eth_call via Multicall3 — HTTP
    // batching would only wrap getLogs/getBlock, which is where it broke.
    [sepolia.id]: http(import.meta.env.VITE_RPC_URL || undefined),
  },
});

/** AccessControl role ids (constants of the deployed vault). */
export const MANAGER_ROLE = keccak256(stringToBytes("MANAGER_ROLE"));
export const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
