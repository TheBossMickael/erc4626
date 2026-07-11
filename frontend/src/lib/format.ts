import { formatUnits } from "viem";
import { ASSET_DECIMALS } from "../config/addresses";

/** "1,234.56" — token amounts (USDC / fTBILL / TBILL, 6 decimals). */
export function fmtAmount(value: bigint | undefined, maxFrac = 2, decimals = ASSET_DECIMALS): string {
  if (value === undefined) return "—";
  const n = Number(formatUnits(value, decimals));
  return n.toLocaleString("en-US", { maximumFractionDigits: maxFrac, minimumFractionDigits: Math.min(2, maxFrac) });
}

/** "1.002345" — NAV per share in assets, full 6-decimal precision. */
export function fmtNav(value: bigint | number | undefined): string {
  if (value === undefined) return "—";
  const n = typeof value === "bigint" ? Number(formatUnits(value, ASSET_DECIMALS)) : value;
  return n.toLocaleString("en-US", { minimumFractionDigits: 6, maximumFractionDigits: 6 });
}

/** "1.023456" — oracle price, 1e18 fixed-point. */
export function fmtPrice18(value: bigint | undefined): string {
  if (value === undefined) return "—";
  return Number(formatUnits(value, 18)).toLocaleString("en-US", {
    minimumFractionDigits: 6,
    maximumFractionDigits: 6,
  });
}

/** 450n → "4.50%" */
export function fmtBps(bps: bigint | number | undefined): string {
  if (bps === undefined) return "—";
  return (Number(bps) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + "%";
}

export function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/** Unix seconds → "Jul 10, 14:32" (viewer's locale timezone). */
export function fmtTime(tsSec: number | bigint | undefined): string {
  if (tsSec === undefined || tsSec === 0n || tsSec === 0) return "—";
  return new Date(Number(tsSec) * 1000).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/** Unix seconds → "Jul 10" (axis ticks). */
export function fmtDay(tsSec: number): string {
  return new Date(tsSec * 1000).toLocaleString("en-US", { month: "short", day: "numeric" });
}

/** Parse a user-typed decimal amount into 6-decimals bigint; null if invalid. */
export function parseAmount(input: string, decimals = ASSET_DECIMALS): bigint | null {
  const s = input.trim().replace(/,/g, "");
  if (!/^\d+(\.\d*)?$/.test(s) || s === "") return null;
  const [int, frac = ""] = s.split(".");
  if (frac.length > decimals) return null;
  try {
    return BigInt(int) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, "0") || "0");
  } catch {
    return null;
  }
}
