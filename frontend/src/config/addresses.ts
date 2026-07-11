// Sepolia deployment of 2026-07-10 (see contracts/broadcast/…/run-latest.json).
// The contracts are immutable and Etherscan-verified; addresses are public
// constants, so they live in code rather than in environment variables.

export const CHAIN_ID = 11155111; // Sepolia

export const ADDRESSES = {
  usdc: "0x098837194e00Ce31B6fB3b8879af576FB50D9A5f",
  oracle: "0x200832A82DC75FdAe22191E1563d72667542Fbe3",
  tbill: "0x38705BD52F94db088bF537c1A811EE4a03a0E70A",
  vault: "0x925B7c0cbfd74E7CBAE348541C629EC1ff33aa9C",
  escrow: "0x2d3efE14E06c82F4F470648eb71194870Bf9D8fb",
} as const;

/** Block in which all five contracts were deployed — lower bound of every
 * event scan (the NAV timeline replays history from here). */
export const DEPLOY_BLOCK = 11245452n; // 0xab978c

export const ETHERSCAN = "https://sepolia.etherscan.io";

/** Both tokens use 6 decimals (USDC-style), and the vault share inherits
 * them (OZ ERC4626, decimals offset 0). The oracle prices in 1e18. */
export const ASSET_DECIMALS = 6;
export const SHARE_DECIMALS = 6;
export const PRICE_SCALE = 10n ** 18n;

/** One whole share, the unit NAV-per-share is quoted against. */
export const ONE_SHARE = 10n ** BigInt(SHARE_DECIMALS);
