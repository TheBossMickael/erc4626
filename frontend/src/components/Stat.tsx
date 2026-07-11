import type { ReactNode } from "react";

/** One headline figure — label over value over optional context line. */
export function Stat({
  label,
  value,
  sub,
  small,
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  small?: boolean;
}) {
  return (
    <div className="card stat">
      <div className="label">{label}</div>
      <div className={small ? "value small" : "value"}>{value}</div>
      {sub && <div className="sub">{sub}</div>}
    </div>
  );
}
