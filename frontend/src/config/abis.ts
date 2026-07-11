// Hand-written minimal ABIs, transcribed from contracts/src (frozen, deployed,
// Etherscan-verified — they cannot drift). Only what the frontend calls or
// decodes is declared; `as const` gives viem full type inference.
//
// Overload note: RWAVault exposes both the ERC-4626 2-arg and the ERC-7540
// 3-arg claim entry points. Only the 3-arg forms are declared so viem never
// has to disambiguate.

export const vaultAbi = [
  // --- reads: fund accounting -------------------------------------------
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "convertToAssets",
    stateMutability: "view",
    inputs: [{ name: "shares", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "convertToShares",
    stateMutability: "view",
    inputs: [{ name: "assets", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  // --- reads: epoch machine ---------------------------------------------
  { type: "function", name: "currentEpochId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "epochs",
    stateMutability: "view",
    inputs: [{ name: "epochId", type: "uint256" }],
    outputs: [
      { name: "totalDepositAssets", type: "uint256" },
      { name: "totalRedeemShares", type: "uint256" },
      { name: "sharesMinted", type: "uint256" },
      { name: "assetsSetAside", type: "uint256" },
      { name: "cutoffAt", type: "uint64" },
      { name: "fulfilledAt", type: "uint64" },
    ],
  },
  // --- reads: per-user request state -------------------------------------
  {
    type: "function",
    name: "depositSlot",
    stateMutability: "view",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [
      { name: "pendingAmount", type: "uint128" },
      { name: "epochId", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "redeemSlot",
    stateMutability: "view",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [
      { name: "pendingAmount", type: "uint128" },
      { name: "epochId", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "maxDeposit",
    stateMutability: "view",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "maxMint",
    stateMutability: "view",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "maxWithdraw",
    stateMutability: "view",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "maxRedeem",
    stateMutability: "view",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  // --- reads: roles -------------------------------------------------------
  {
    type: "function",
    name: "hasRole",
    stateMutability: "view",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "account", type: "address" },
    ],
    outputs: [{ type: "bool" }],
  },
  // --- writes: requests & cancellation ------------------------------------
  {
    type: "function",
    name: "requestDeposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "controller", type: "address" },
      { name: "owner", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "requestRedeem",
    stateMutability: "nonpayable",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "controller", type: "address" },
      { name: "owner", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "cancelDepositRequest",
    stateMutability: "nonpayable",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "cancelRedeemRequest",
    stateMutability: "nonpayable",
    inputs: [{ name: "controller", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  // --- writes: claims (7540 3-arg forms) -----------------------------------
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "controller", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "redeem",
    stateMutability: "nonpayable",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "controller", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  // --- writes: epoch machine & portfolio (manager) -------------------------
  { type: "function", name: "closeEpoch", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "fulfillEpoch", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "invest",
    stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "divest",
    stateMutability: "nonpayable",
    inputs: [{ name: "tbillAmount", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  // --- events --------------------------------------------------------------
  {
    type: "event",
    name: "DepositRequest",
    inputs: [
      { name: "controller", type: "address", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "requestId", type: "uint256", indexed: true },
      { name: "sender", type: "address", indexed: false },
      { name: "assets", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RedeemRequest",
    inputs: [
      { name: "controller", type: "address", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "requestId", type: "uint256", indexed: true },
      { name: "sender", type: "address", indexed: false },
      { name: "shares", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "EpochClosed",
    inputs: [
      { name: "epochId", type: "uint256", indexed: true },
      { name: "totalDepositAssets", type: "uint256", indexed: false },
      { name: "totalRedeemShares", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "EpochFulfilled",
    inputs: [
      { name: "epochId", type: "uint256", indexed: true },
      { name: "totalDepositAssets", type: "uint256", indexed: false },
      { name: "totalRedeemShares", type: "uint256", indexed: false },
      { name: "sharesMinted", type: "uint256", indexed: false },
      { name: "assetsSetAside", type: "uint256", indexed: false },
      { name: "navPerShare", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Invested",
    inputs: [
      { name: "assetsIn", type: "uint256", indexed: false },
      { name: "tbillOut", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Divested",
    inputs: [
      { name: "tbillIn", type: "uint256", indexed: false },
      { name: "assetsOut", type: "uint256", indexed: false },
    ],
  },
] as const;

export const oracleAbi = [
  { type: "function", name: "price", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "rateBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "timeScale", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "setRateBps",
    stateMutability: "nonpayable",
    inputs: [{ name: "newRateBps", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setTimeScale",
    stateMutability: "nonpayable",
    inputs: [{ name: "newTimeScale", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "applyShock",
    stateMutability: "nonpayable",
    inputs: [{ name: "shockBps", type: "int256" }],
    outputs: [],
  },
  {
    type: "event",
    name: "RateSet",
    inputs: [
      { name: "rateBps", type: "uint256", indexed: false },
      { name: "priceAtCheckpoint", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "TimeScaleSet",
    inputs: [
      { name: "timeScale", type: "uint256", indexed: false },
      { name: "priceAtCheckpoint", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ShockApplied",
    inputs: [
      { name: "shockBps", type: "int256", indexed: false },
      { name: "newPrice", type: "uint256", indexed: false },
    ],
  },
] as const;

export const usdcAbi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

export const tbillAbi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;
