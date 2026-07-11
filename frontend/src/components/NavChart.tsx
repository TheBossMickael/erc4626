import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ReferenceDot,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { NavPoint, FulfillMarker } from "../lib/navHistory";
import { fmtDay, fmtTime } from "../lib/format";

// Two series, one unit (USDC), one axis. Identity is never color-alone:
// the benchmark is dashed and both series are named in the legend.
const NAV_COLOR = "var(--series-1)";
const PRICE_COLOR = "var(--series-2)";

function ChartTooltip({ active, payload, label }: any) {
  if (!active || !payload?.length) return null;
  return (
    <div className="chart-tooltip">
      <div className="when">{fmtTime(label)}</div>
      {payload.map((p: any) => (
        <div className="row" key={p.dataKey}>
          <span
            className="swatch"
            style={{ background: p.stroke, borderBottom: p.dataKey === "price" ? "1px dashed" : undefined }}
          />
          <span>{p.name}</span>
          <span style={{ marginLeft: "auto" }}>{p.value?.toFixed(6)}</span>
        </div>
      ))}
    </div>
  );
}

export function NavChart({ points, markers }: { points: NavPoint[]; markers: FulfillMarker[] }) {
  if (points.length < 2) {
    return <div className="empty">Not enough history yet — the curve appears after the first blocks.</div>;
  }
  return (
    <ResponsiveContainer width="100%" height={320}>
      <LineChart data={points} margin={{ top: 18, right: 18, bottom: 4, left: 8 }}>
        <CartesianGrid stroke="var(--grid)" vertical={false} />
        <XAxis
          dataKey="t"
          type="number"
          domain={["dataMin", "dataMax"]}
          tickFormatter={fmtDay}
          tick={{ fill: "var(--muted)", fontSize: 11 }}
          axisLine={{ stroke: "var(--baseline)" }}
          tickLine={false}
          tickMargin={8}
          minTickGap={48}
        />
        <YAxis
          domain={["auto", "auto"]}
          tickFormatter={(v: number) => v.toFixed(4)}
          tick={{ fill: "var(--muted)", fontSize: 11 }}
          axisLine={false}
          tickLine={false}
          width={64}
        />
        <Tooltip content={<ChartTooltip />} cursor={{ stroke: "var(--baseline)" }} />
        <Legend
          verticalAlign="top"
          align="right"
          height={28}
          iconType="plainline"
          formatter={(value) => <span style={{ color: "var(--ink-2)", fontSize: 12 }}>{value}</span>}
        />
        <Line
          type="linear"
          dataKey="price"
          name="T-Bill price (oracle)"
          stroke={PRICE_COLOR}
          strokeWidth={2}
          strokeDasharray="5 4"
          dot={false}
          isAnimationActive={false}
        />
        <Line
          type="linear"
          dataKey="nav"
          name="Fund NAV per share"
          stroke={NAV_COLOR}
          strokeWidth={2}
          dot={false}
          isAnimationActive={false}
        />
        {markers.map((m) => (
          <ReferenceDot
            key={m.epochId}
            x={m.t}
            y={m.nav}
            r={5}
            fill={NAV_COLOR}
            stroke="var(--surface)"
            strokeWidth={2}
            label={{ value: `E${m.epochId}`, position: "top", fill: "var(--muted)", fontSize: 11 }}
          />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );
}
