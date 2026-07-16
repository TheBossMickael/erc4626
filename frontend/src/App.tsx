import { useState } from "react";
import { useAccount, useSwitchChain } from "wagmi";
import { sepolia } from "wagmi/chains";
import { CHAIN_ID, ADDRESSES, ETHERSCAN } from "./config/addresses";
import { ConnectButton } from "./components/ConnectButton";
import { OverviewView } from "./views/OverviewView";
import { InvestView } from "./views/InvestView";
import { OperateView } from "./views/OperateView";
import { shortAddr } from "./lib/format";

type Tab = "overview" | "invest" | "operate";

const TABS: { id: Tab; label: string }[] = [
  { id: "overview", label: "Overview" },
  { id: "invest", label: "Invest" },
  { id: "operate", label: "Operate" },
];

export default function App() {
  const [tab, setTab] = useState<Tab>("overview");
  const { address, chainId } = useAccount();
  const { switchChain, isPending: switching } = useSwitchChain();
  const wrongNetwork = !!address && chainId !== CHAIN_ID;

  return (
    <>
      <header className="app-header">
        <div className="wordmark">
          <span className="tick">▲</span> fTBILL <small>Tokenized T-Bill Fund</small>
        </div>
        <nav className="nav-tabs">
          {TABS.map((t) => (
            <button key={t.id} className={tab === t.id ? "active" : ""} onClick={() => setTab(t.id)}>
              {t.label}
            </button>
          ))}
        </nav>
        <span className={wrongNetwork ? "net-badge wrong" : "net-badge"}>
          {wrongNetwork ? "Wrong network" : "Sepolia"}
        </span>
        <ConnectButton />
      </header>

      <main className="container">
        {wrongNetwork && (
          <div className="callout crit" style={{ marginBottom: 16 }}>
            Your wallet is on another network — this demo lives on Sepolia.{" "}
            <button
              className="btn btn-sm"
              disabled={switching}
              onClick={() => switchChain({ chainId: sepolia.id })}
              style={{ marginLeft: 8 }}
            >
              {switching ? "Switching…" : "Switch to Sepolia"}
            </button>
          </div>
        )}

        {tab === "overview" && <OverviewView />}
        {tab === "invest" && <InvestView />}
        {tab === "operate" && <OperateView />}

        <footer className="footer">
          <span>Sepolia testnet simulation — every number on this page is read from the chain.</span>
          <a href={`${ETHERSCAN}/address/${ADDRESSES.vault}`} target="_blank" rel="noreferrer">
            Vault {shortAddr(ADDRESSES.vault)} ↗
          </a>
          <a href="https://github.com/TheBossMickael/tbill-fund" target="_blank" rel="noreferrer">
            Source ↗
          </a>
          <a href="https://eips.ethereum.org/EIPS/eip-7540" target="_blank" rel="noreferrer">
            ERC-7540 ↗
          </a>
        </footer>
      </main>
    </>
  );
}
