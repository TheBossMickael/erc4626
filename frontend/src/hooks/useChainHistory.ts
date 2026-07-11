import { useQuery } from "@tanstack/react-query";
import { loadChainHistory } from "../lib/navHistory";

/** Event-replayed history (NAV curve, fulfillment markers, epoch table).
 * Runs on its own public-RPC scan client (see navHistory.ts) — one scan on
 * load, then refreshed every minute; the live head of the curve comes from
 * useFundState between refreshes. */
export function useChainHistory() {
  return useQuery({
    queryKey: ["chainHistory"],
    queryFn: async () => {
      try {
        return await loadChainHistory();
      } catch (err) {
        console.error("[chainHistory] event replay failed:", err);
        throw err;
      }
    },
    staleTime: 30_000,
    refetchInterval: 60_000,
    retry: 2,
  });
}
