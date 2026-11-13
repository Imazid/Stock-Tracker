// Only these read-only market-data paths may use the project's Alpaca credentials.
const stock = /^[A-Z0-9]{1,12}(?:[.\-][A-Z0-9]{1,6}){0,2}$/;
const cryptoPair = /^[A-Z0-9]{1,15}\/USD$/;
const stockPath = /^\/v2\/stocks\/([^/]+)\/(bars|snapshot|quotes\/latest)$/;
const stockBatch = "/v2/stocks/snapshots";
const cryptoRoot = "/v1beta3/crypto/us/";
const checks: Record<string, (value: string) => boolean> = {
  timeframe: (v) => /^(?:[1-9][0-9]?)(Min|Hour|Day|Week|Month)$/.test(v),
  start: (v) => isoDate(v),
  end: (v) => isoDate(v),
  limit: (v) => /^\d{1,5}$/.test(v) && Number(v) >= 1 && Number(v) <= 10_000,
  adjustment: (v) => v === "all",
  sort: (v) => v === "asc" || v === "desc",
  page_token: (v) => /^[\w+=/-]{1,1024}$/.test(v),
};

function isoDate(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(value) && Number.isFinite(Date.parse(value));
}

export function alpacaRequest(input: URL, now = Date.now()): URL | undefined {
  const { searchParams } = input;
  const path = searchParams.get("path") ?? "";
  const single = stockPath.exec(path);
  const isCrypto = path === cryptoRoot + "bars" || path === cryptoRoot + "snapshots";
  const isBars = single?.[2] === "bars" || path === cryptoRoot + "bars";
  if ((!single && !isCrypto && path !== stockBatch) || (single && !stock.test(single[1]))) return;

  const target = new URL(path, "https://data.alpaca.markets");
  const seen = new Set<string>();
  for (const [name, value] of searchParams) {
    if (seen.has(name)) return;
    seen.add(name);
    if (name === "path") continue;
    if (name === "symbols" && !single) {
      const symbols = value.split(",");
      const pattern = isCrypto ? cryptoPair : stock;
      if (symbols.length > (isCrypto ? 30 : 100) || symbols.some((symbol) => !pattern.test(symbol))) return;
      target.searchParams.set(name, [...new Set(symbols)].sort().join(","));
    } else if (name === "feed" && !isCrypto) {
      const end = Date.parse(searchParams.get("end") ?? "");
      if (value !== "iex" && !(value === "sip" && isBars && end <= now - 15 * 60_000)) return;
      target.searchParams.set(name, value);
    } else if (isBars && Object.hasOwn(checks, name) && checks[name](value)) {
      target.searchParams.set(name, value);
    } else {
      return;
    }
  }
  if (!single && !seen.has("symbols")) return;
  if (isBars && (!seen.has("start") || !seen.has("timeframe") || !seen.has("limit"))) return;
  if (!isCrypto && !seen.has("feed")) target.searchParams.set("feed", "iex");
  target.searchParams.sort();
  return target;
}
