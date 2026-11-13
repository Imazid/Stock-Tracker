// Exact decimal arithmetic for non-negative monetary values and quantities.
//
// Providers send prices and sizes as decimal strings ("0.00012345"); we keep them as strings
// end to end and only do arithmetic here, on BigInt-scaled integers, so a value is never
// rounded by binary floating point. Non-negative values only: this path is long-only and a
// negative quantity or price is always a bug.

const PATTERN = /^(0|[1-9]\d*)(\.\d+)?$/;
const MAX_SCALE = 18;

export interface Dec {
  /** value = units / 10^scale */
  units: bigint;
  scale: number;
}

export class DecimalError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DecimalError";
  }
}

/** True for a plain non-negative decimal string ("12", "0.5", "1.250"). No sign, exponent or spaces. */
export function isDecimal(text: unknown): text is string {
  if (typeof text !== "string" || !PATTERN.test(text)) return false;
  const dot = text.indexOf(".");
  return dot < 0 || text.length - dot - 1 <= MAX_SCALE;
}

export function parse(text: string): Dec {
  // Accept leading zeros from providers ("007.50") by normalising first.
  const cleaned = /^0+\d/.test(text) ? text.replace(/^0+(?=\d)/, "") : text;
  if (!isDecimal(cleaned)) throw new DecimalError(`"${text}" isn't a plain decimal number.`);
  const [whole, fraction = ""] = cleaned.split(".");
  return { units: BigInt(whole + fraction), scale: fraction.length };
}

/** Canonical text: no trailing fractional zeros, no trailing dot, "0" for zero. "1.500" → "1.5". */
export function normalise(text: string): string {
  return format(parse(text));
}

export function format(d: Dec): string {
  const negative = d.units < 0n;
  let digits = (negative ? -d.units : d.units).toString();
  if (d.scale > 0) {
    digits = digits.padStart(d.scale + 1, "0");
    let whole = digits.slice(0, digits.length - d.scale);
    const fraction = digits.slice(digits.length - d.scale).replace(/0+$/, "");
    if (whole === "") whole = "0";
    digits = fraction ? `${whole}.${fraction}` : whole;
  }
  return negative ? `-${digits}` : digits;
}

function align(a: Dec, b: Dec): [bigint, bigint, number] {
  const scale = Math.max(a.scale, b.scale);
  return [a.units * 10n ** BigInt(scale - a.scale), b.units * 10n ** BigInt(scale - b.scale), scale];
}

export function compare(a: string, b: string): -1 | 0 | 1 {
  const [x, y] = align(parse(a), parse(b));
  return x < y ? -1 : x > y ? 1 : 0;
}

export function isZero(a: string): boolean {
  return parse(a).units === 0n;
}

export function add(a: string, b: string): string {
  const [x, y, scale] = align(parse(a), parse(b));
  return format({ units: x + y, scale });
}

/** a − b; refuses to go negative (callers check `compare` first when that's possible). */
export function sub(a: string, b: string): string {
  const [x, y, scale] = align(parse(a), parse(b));
  if (y > x) throw new DecimalError(`${a} − ${b} would be negative.`);
  return format({ units: x - y, scale });
}

export function mul(a: string, b: string): string {
  const x = parse(a);
  const y = parse(b);
  return format({ units: x.units * y.units, scale: x.scale + y.scale });
}

/** a ÷ b, truncated (rounded toward zero) to `scale` places. */
export function div(a: string, b: string, scale: number): string {
  const x = parse(a);
  const y = parse(b);
  if (y.units === 0n) throw new DecimalError("Division by zero.");
  // a/b = (x.units / 10^xs) / (y.units / 10^ys) ; scale result to 10^scale
  const numerator = x.units * 10n ** BigInt(scale + y.scale);
  const denominator = y.units * 10n ** BigInt(x.scale);
  return format({ units: numerator / denominator, scale });
}

/** Round to `scale` places: "down" truncates (sizes, so we never exceed a limit), "halfUp" for display money. */
export function round(a: string, scale: number, mode: "down" | "halfUp" = "halfUp"): string {
  const d = parse(a);
  if (d.scale <= scale) return format(d);
  const drop = 10n ** BigInt(d.scale - scale);
  let units = d.units / drop;
  if (mode === "halfUp" && (d.units % drop) * 2n >= drop) units += 1n;
  return format({ units, scale });
}

/** True if `a` is a whole multiple of `increment` (e.g. a quantity on a lot size or a price on a tick). */
export function isMultipleOf(a: string, increment: string): boolean {
  const [x, y] = align(parse(a), parse(increment));
  if (y === 0n) return true;
  return x % y === 0n;
}

/** For display and for risk checks that work in doubles. Never for storage or arithmetic. */
export function toNumber(a: string): number {
  return Number(normalise(a));
}

/** From a double the engine produced (prices it already rounded). Fixed `scale` places, then normalised. */
export function fromNumber(x: number, scale = 8): string {
  if (!Number.isFinite(x) || x < 0) throw new DecimalError(`${x} can't be a quantity or price.`);
  return normalise(x.toFixed(scale));
}
