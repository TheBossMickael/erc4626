import { fmtAmount } from "../lib/format";

/** Decimal amount input with unit tag and MAX shortcut. The parent holds the
 * raw string (parseAmount turns it into 6-decimals bigint). */
export function AmountInput({
  value,
  onChange,
  unit,
  max,
  placeholder = "0.00",
}: {
  value: string;
  onChange: (v: string) => void;
  unit: string;
  max?: bigint;
  placeholder?: string;
}) {
  return (
    <div className="input-row">
      <input
        inputMode="decimal"
        autoComplete="off"
        spellCheck={false}
        placeholder={placeholder}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
      <span className="unit">{unit}</span>
      {max !== undefined && (
        <button
          type="button"
          className="btn btn-sm max"
          title={`Balance: ${fmtAmount(max, 6)} ${unit}`}
          onClick={() => onChange((Number(max) / 1e6).toString())}
        >
          MAX
        </button>
      )}
    </div>
  );
}
