// Demo keeper — turns the settlement cycle when investors are waiting.
//
// Holds MANAGER_ROLE on the vault (granted via grantRole, no redeploy) and
// runs every ~30 real minutes from GitHub Actions. With the oracle's demo
// time scale (1 min ≈ 1 day), that models a fund settling roughly monthly.
//
// One run = at most ONE settlement, mirroring the manual transfer-agent
// sequence exactly:
//   1. if an epoch awaits settlement: divest if cash can't cover the
//      payout (like a real fund selling T-Bills), then fulfillEpoch()
//   2. else, if the open epoch has pending requests: closeEpoch(), then
//      settle it via the same path
//   3. never closes an empty epoch — no churn on quiet days
//   4. after settling, re-invests idle cash above a 5% float (policy
//      toggle below)
//
// Trust scope: MANAGER_ROLE can grief the cycle and rebalance cash<->T-Bill
// at the oracle price — it cannot choose prices or take custody of funds.
// The key lives in GitHub Actions secrets, is dedicated to this bot, and
// holds nothing but gas.

import { createPublicClient, createWalletClient, formatUnits, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

const VAULT = "0x925B7c0cbfd74E7CBAE348541C629EC1ff33aa9C";
const USDC = "0x098837194e00Ce31B6fB3b8879af576FB50D9A5f";
const TBILL = "0x38705BD52F94db088bF537c1A811EE4a03a0E70A";
const ORACLE = "0x200832A82DC75FdAe22191E1563d72667542Fbe3";
const PRICE_SCALE = 10n ** 18n;

// Portfolio policy: after settling, invest idle cash down to a 5% float of
// AUM (a real fund keeps a redemption buffer). Set to false for a keeper
// that ONLY turns the cycle and leaves allocation to the human manager.
const AUTO_INVEST = true;
const FLOAT_BPS = 500n; // 5% of totalAssets kept as cash
const MIN_TRADE = 10_000_000n; // 10 USDC — don't bother below this

const vaultAbi = parseAbi([
  "function currentEpochId() view returns (uint256)",
  "function epochs(uint256) view returns (uint256 totalDepositAssets, uint256 totalRedeemShares, uint256 sharesMinted, uint256 assetsSetAside, uint64 cutoffAt, uint64 fulfilledAt)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function totalAssets() view returns (uint256)",
  "function closeEpoch() returns (uint256)",
  "function fulfillEpoch() returns (uint256)",
  "function divest(uint256 tbillAmount) returns (uint256)",
  "function invest(uint256 assets) returns (uint256)",
]);
const erc20Abi = parseAbi(["function balanceOf(address account) view returns (uint256)"]);
const oracleAbi = parseAbi(["function price() view returns (uint256)"]);

const rpcUrl = process.env.RPC_URL;
const pk = process.env.KEEPER_PRIVATE_KEY;
if (!rpcUrl || !pk) {
  console.error("Missing RPC_URL or KEEPER_PRIVATE_KEY");
  process.exit(1);
}

const account = privateKeyToAccount(pk);
const publicClient = createPublicClient({ chain: sepolia, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account, chain: sepolia, transport: http(rpcUrl) });

const fmt = (v) => formatUnits(v, 6);

/** simulate → send → wait. Simulation surfaces revert reasons up front. */
async function send(functionName, args = []) {
  const { request } = await publicClient.simulateContract({
    account,
    address: VAULT,
    abi: vaultAbi,
    functionName,
    args,
  });
  const hash = await walletClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  ${functionName}(${args.map(String).join(", ")}) → ${receipt.status} (${hash})`);
  if (receipt.status !== "success") throw new Error(`${functionName} reverted`);
  return receipt;
}

const readVault = (functionName, args = []) =>
  publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName, args });

/** Divest just enough (plus 0.5% accrual buffer) for the payout, then fulfill. */
async function settle(epochId, totalDepositAssets, totalRedeemShares) {
  const [estAside, cash, price] = await Promise.all([
    readVault("convertToAssets", [totalRedeemShares]),
    publicClient.readContract({ address: USDC, abi: erc20Abi, functionName: "balanceOf", args: [VAULT] }),
    publicClient.readContract({ address: ORACLE, abi: oracleAbi, functionName: "price" }),
  ]);
  const available = cash + totalDepositAssets;
  console.log(`  payout ≈ ${fmt(estAside)} USDC vs available ${fmt(available)} USDC`);

  // 0.2% headroom on the WHOLE payout, not the shortfall: the NAV keeps
  // accruing between this read and the fulfill tx landing (time runs ×1440),
  // so the payout at execution is slightly higher than estimated here.
  const needed = estAside + estAside / 500n;
  if (needed > available) {
    const shortfall = needed - available;
    let tbillAmount = (shortfall * PRICE_SCALE) / price;
    const tbillBal = await publicClient.readContract({
      address: TBILL,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [VAULT],
    });
    if (tbillAmount > tbillBal) tbillAmount = tbillBal; // solvency invariant makes this cover it
    console.log(`  shortfall ${fmt(shortfall)} USDC — divesting ${fmt(tbillAmount)} TBILL`);
    await send("divest", [tbillAmount]);
  }

  await send("fulfillEpoch");
  console.log(`  epoch #${epochId} settled`);
}

async function investIdleCash() {
  if (!AUTO_INVEST) return;
  const [cash, totalAssets] = await Promise.all([
    publicClient.readContract({ address: USDC, abi: erc20Abi, functionName: "balanceOf", args: [VAULT] }),
    readVault("totalAssets"),
  ]);
  const float = (totalAssets * FLOAT_BPS) / 10_000n;
  if (cash > float && cash - float >= MIN_TRADE) {
    const amount = cash - float;
    console.log(`  idle cash ${fmt(cash)} > ${fmt(float)} float — investing ${fmt(amount)} USDC`);
    await send("invest", [amount]);
  }
}

async function main() {
  const gas = await publicClient.getBalance({ address: account.address });
  console.log(`keeper ${account.address} · gas ${formatUnits(gas, 18)} ETH`);
  if (gas < 5n * 10n ** 15n) console.warn("⚠ gas below 0.005 ETH — top up soon");

  const currentId = await readVault("currentEpochId");
  const [open, prev] = await Promise.all([
    readVault("epochs", [currentId]),
    readVault("epochs", [currentId - 1n]),
  ]);

  // 1. an already-closed epoch always settles first (I9: at most one).
  if (prev[4] !== 0n && prev[5] === 0n) {
    console.log(`epoch #${currentId - 1n} closed, awaiting settlement`);
    await settle(currentId - 1n, prev[0], prev[1]);
    await investIdleCash();
    return;
  }

  // 2. close + settle the open epoch only if someone is actually waiting.
  const [deposits, redemptions] = [open[0], open[1]];
  if (deposits === 0n && redemptions === 0n) {
    console.log(`epoch #${currentId} open and empty — nothing to do`);
    return;
  }
  console.log(`epoch #${currentId} open: ${fmt(deposits)} USDC deposits, ${fmt(redemptions)} fTBILL redemptions`);
  await send("closeEpoch");
  await settle(currentId, deposits, redemptions);
  await investIdleCash();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
