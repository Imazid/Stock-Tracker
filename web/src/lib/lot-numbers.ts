export const UNIT_DECIMALS = 18;
export const UNIT_SCALE = 10n ** BigInt(UNIT_DECIMALS);

export function lotUnits(value: number | string | null | undefined) {
  if (value == null) return undefined;
  if (typeof value === "number" && (!Number.isFinite(value) || value < 0 || value >= 1e15)) return undefined;
  if (typeof value === "string" && !/^(?:0|[1-9]\d{0,14})(?:\.\d{1,18})?$/.test(value)) return undefined;
  const [significand, exponent = "0"] = String(value).split("e");
  const [whole, fraction = ""] = significand.split(".");
  const units = BigInt(whole + fraction);
  const scale = UNIT_DECIMALS + Number(exponent) - fraction.length;
  if (scale >= 0) return units * 10n ** BigInt(scale);
  const divisor = 10n ** BigInt(-scale);
  return (units + divisor / 2n) / divisor;
}
