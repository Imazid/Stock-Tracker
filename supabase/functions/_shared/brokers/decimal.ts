// Exact decimal-string arithmetic for the few sums and checks the adapters need (a balance's
// total = available + hold, a cash reserve = cash − available). BigInt underneath, so no
// value is ever rounded through a JS float. Money never becomes a `number` in this layer.

const DECIMAL = /^-?\d+(\.\d+)?$/;

export function isDecimal(value: unknown): value is string {
  return typeof value === "string" && DECIMAL.test(value);
}

/** A decimal string strictly greater than zero. */
export function isPositiveDecimal(value: unknown): value is string {
  return isDecimal(value) && !value.startsWith("-") && compare(value, "0") > 0;
}

/** True when the string has a non-zero fractional part ("1.50" yes, "2.000" no). */
export function isFractional(value: string): boolean {
  const dot = value.indexOf(".");
  return dot >= 0 && /[1-9]/.test(value.slice(dot + 1));
}

interface Scaled {
  units: bigint;
  scale: number;
}

function parse(value: string): Scaled {
  if (!isDecimal(value)) throw new RangeError(`not a decimal string: ${JSON.stringify(value)}`);
  const negative = value.startsWith("-");
  const body = negative ? value.slice(1) : value;
  const [whole, fraction = ""] = body.split(".");
  const units = BigInt(whole + fraction);
  return { units: negative ? -units : units, scale: fraction.length };
}

function align(a: Scaled, b: Scaled): [bigint, bigint, number] {
  const scale = Math.max(a.scale, b.scale);
  return [a.units * 10n ** BigInt(scale - a.scale), b.units * 10n ** BigInt(scale - b.scale), scale];
}

function format(units: bigint, scale: number): string {
  const negative = units < 0n;
  let digits = (negative ? -units : units).toString();
  if (scale > 0) {
    digits = digits.padStart(scale + 1, "0");
    const whole = digits.slice(0, digits.length - scale) || "0";
    const fraction = digits.slice(digits.length - scale).replace(/0+$/, "");
    digits = fraction ? `${whole}.${fraction}` : whole;
  }
  return negative && digits !== "0" ? `-${digits}` : digits;
}

export function add(a: string, b: string): string {
  const [x, y, scale] = align(parse(a), parse(b));
  return format(x + y, scale);
}

export function subtract(a: string, b: string): string {
  const [x, y, scale] = align(parse(a), parse(b));
  return format(x - y, scale);
}

export function compare(a: string, b: string): -1 | 0 | 1 {
  const [x, y] = align(parse(a), parse(b));
  return x < y ? -1 : x > y ? 1 : 0;
}

export function max(a: string, b: string): string {
  return compare(a, b) >= 0 ? a : b;
}

/** a ÷ b to `scale` places, truncated toward zero. Throws on division by zero. */
export function divide(a: string, b: string, scale = 18): string {
  const x = parse(a);
  const y = parse(b);
  if (y.units === 0n) throw new RangeError("division by zero");
  // (x.units / 10^x.scale) / (y.units / 10^y.scale) * 10^scale
  const numerator = x.units * 10n ** BigInt(scale + y.scale);
  const denominator = y.units * 10n ** BigInt(x.scale);
  return format(numerator / denominator, scale);
}

/** Canonical form: no trailing fractional zeros, "-0" → "0". */
export function normalise(value: string): string {
  const p = parse(value);
  return format(p.units, p.scale);
}
