// Number-to-text rules. The engine writes explanations (evidence, risk details, audit
// details) and the phone and the server must write the same words, so these reproduce
// what Swift's `String(format:)` and `String(Double)` print — not what JavaScript's
// `toFixed` and `String` print, which differ on exact halves and on whole numbers.
// Pinned by TradingCore/Tests/Vectors/text.json.

const f64 = new Float64Array(1);
const u64 = new BigUint64Array(f64.buffer);

/** The exact value of a positive finite double as `mantissa × 2^exponent`. */
function decompose(a: number): { mantissa: bigint; exponent: number } {
  f64[0] = a;
  const bits = u64[0];
  const exponentBits = Number((bits >> 52n) & 0x7ffn);
  const fraction = bits & 0xfffffffffffffn;
  if (exponentBits === 0) return { mantissa: fraction, exponent: -1074 };
  return { mantissa: fraction | (1n << 52n), exponent: exponentBits - 1075 };
}

/**
 * C's `%.Nf`: the exact binary value rounded to N places, exact halves to even.
 * (`(0.125).toFixed(2)` is "0.13"; C and Swift print "0.12".)
 */
export function cFixed(x: number, places: number): string {
  if (Number.isNaN(x)) return "nan";
  if (!Number.isFinite(x)) return x < 0 ? "-inf" : "inf";
  const negative = x < 0 || Object.is(x, -0);
  const a = Math.abs(x);
  let n = 0n;
  if (a !== 0) {
    const { mantissa, exponent } = decompose(a);
    const scaled = mantissa * 10n ** BigInt(places);
    if (exponent >= 0) {
      n = scaled << BigInt(exponent);
    } else {
      const denominator = 1n << BigInt(-exponent);
      const quotient = scaled / denominator;
      const twice = (scaled % denominator) * 2n;
      if (twice > denominator) n = quotient + 1n;
      else if (twice < denominator) n = quotient;
      else n = quotient % 2n === 0n ? quotient : quotient + 1n;
    }
  }
  let digits = n.toString();
  if (places > 0) {
    digits = digits.padStart(places + 1, "0");
    digits = `${digits.slice(0, -places)}.${digits.slice(-places)}`;
  }
  return (negative ? "-" : "") + digits;
}

/**
 * Swift's `String(Double)` / `"\(double)"`: the shortest digits that read back as the
 * same number, always with a decimal point ("5000.0"), and exponent form ("1e-05",
 * "1e+16") below 0.0001 and above 2^53.
 */
export function swiftDouble(x: number): string {
  if (Number.isNaN(x)) return "nan";
  if (!Number.isFinite(x)) return x < 0 ? "-inf" : "inf";
  if (x === 0) return Object.is(x, -0) ? "-0.0" : "0.0";
  const sign = x < 0 ? "-" : "";
  const a = Math.abs(x);
  const [mantissa, exponentText] = a.toExponential().split("e");
  const digits = mantissa.replace(".", "");
  const exponent = Number(exponentText);
  if (exponent < -4 || a > 9_007_199_254_740_992) {
    const body = digits.length > 1 ? `${digits[0]}.${digits.slice(1)}` : digits;
    const magnitude = Math.abs(exponent);
    return `${sign}${body}e${exponent < 0 ? "-" : "+"}${magnitude < 10 ? "0" : ""}${magnitude}`;
  }
  if (exponent < 0) return `${sign}0.${"0".repeat(-exponent - 1)}${digits}`;
  if (digits.length <= exponent + 1) return `${sign}${digits}${"0".repeat(exponent + 1 - digits.length)}.0`;
  return `${sign}${digits.slice(0, exponent + 1)}.${digits.slice(exponent + 1)}`;
}

/** Swift's `capitalized` for the single lowercase words the engine uses ("buy" → "Buy"). */
export function capitalized(word: string): string {
  return word.length === 0 ? word : word[0].toUpperCase() + word.slice(1).toLowerCase();
}

/** Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function swiftTrim(text: string): string {
  // Unicode separators, tab through carriage return, and NEL — Foundation's set.
  // deno-lint-ignore no-control-regex
  return text.replace(/^[\p{Z}\u0009-\u000D\u0085]+|[\p{Z}\u0009-\u000D\u0085]+$/gu, "");
}

/** Characters as Swift counts them closely enough for length limits (code points). */
export function characterCount(text: string): number {
  let count = 0;
  for (const _ of text) count += 1;
  return count;
}

/** Ordering Swift's `sorted()` gives strings: by Unicode scalar, not by UTF-16 unit. */
export function compareStrings(a: string, b: string): number {
  const x = Array.from(a), y = Array.from(b);
  const length = Math.min(x.length, y.length);
  for (let i = 0; i < length; i++) {
    const d = x[i].codePointAt(0)! - y[i].codePointAt(0)!;
    if (d !== 0) return d;
  }
  return x.length - y.length;
}

export function sortedStrings(values: Iterable<string>): string[] {
  return Array.from(values).sort(compareStrings);
}

/** "0.97", "50" — a number with no trailing ".00". */
export function trimNumber(x: number): string {
  return x === roundAwayInt(x) ? cFixed(x, 0) : cFixed(x, 2);
}

function roundAwayInt(x: number): number {
  if (!Number.isFinite(x)) return x;
  const whole = Math.trunc(x);
  return Math.abs(x - whole) >= 0.5 ? whole + (x < 0 ? -1 : 1) : whole;
}

/**
 * Number formatting for evidence text. Display code in the app formats money itself;
 * this is only for the explanations the core writes.
 */
export const NumberText = {
  price(x: number): string {
    return Math.abs(x) >= 1 ? cFixed(x, 2) : cFixed(x, 4);
  },
  number(x: number): string {
    if (Math.abs(x) >= 1_000_000) return cFixed(x, 0);
    if (Math.abs(x) >= 1) return cFixed(x, 2);
    return cFixed(x, 4);
  },
  signedPercent(x: number): string {
    const text = cFixed(x, 1);
    return `${text.startsWith("-") ? "" : "+"}${text}%`;
  },
  money(x: number, currency = "USD"): string {
    const symbol = currency === "AUD" ? "A$" : currency === "USD" ? "$" : `${currency} `;
    return symbol + cFixed(x, 2);
  },
};

export function percentText(x: number): string {
  return `${cFixed(x, 1)}%`;
}

export function durationText(seconds: number): string {
  const s = roundAwayInt(seconds);
  if (s < 90) return `${s}s`;
  if (s < 5_400) return `${roundAwayInt(s / 60)} min`;
  if (s < 172_800) return `${roundAwayInt(s / 3_600)} h`;
  return `${roundAwayInt(s / 86_400)} days`;
}

export function compactText(x: number): string {
  if (x >= 1_000_000_000) return `${cFixed(x / 1_000_000_000, 1)}B`;
  if (x >= 1_000_000) return `${cFixed(x / 1_000_000, 1)}M`;
  if (x >= 1_000) return `${cFixed(x / 1_000, 0)}K`;
  return cFixed(x, 0);
}
