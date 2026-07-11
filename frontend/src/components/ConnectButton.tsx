import { useAccount, useConnect, useDisconnect } from "wagmi";
import { shortAddr } from "../lib/format";

/** Injected-only (MetaMask-first) connect control — design decision F7:
 * no WalletConnect modal, no external dependency, dashboard-native styling. */
export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();

  if (isConnected && address) {
    return (
      <button className="btn btn-sm addr" title="Disconnect" onClick={() => disconnect()}>
        {shortAddr(address)}
      </button>
    );
  }
  return (
    <button
      className="btn btn-primary btn-sm"
      disabled={isPending}
      title={error ? "No injected wallet found — install MetaMask" : "Connect an injected wallet (MetaMask)"}
      onClick={() => connect({ connector: connectors[0] })}
    >
      {isPending ? "Connecting…" : "Connect wallet"}
    </button>
  );
}
