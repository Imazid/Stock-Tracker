"use client";

import { useQuery } from "@tanstack/react-query";
import { cryptoFactsRefreshMs, cryptoFactsStaleMs, type CryptoFacts } from "@market/crypto_facts_types.ts";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { ApiError, getJSON } from "@/lib/api";
import { compact, currencySymbol, dateTime, money } from "@/lib/format";
import { useNow } from "@/hooks/useNow";

function compactUSD(value: number | undefined) {
  return value === undefined ? "Unavailable" : `${currencySymbol("USD")}${compact(value)}`;
}

export function CryptoResearch({ id }: { id: string }) {
  const now = useNow(60_000);
  const query = useQuery({
    queryKey: ["crypto-facts", id],
    queryFn: ({ signal }) => getJSON<CryptoFacts>(`/api/markets/instruments/${encodeURIComponent(id)}/crypto`, signal),
    staleTime: cryptoFactsRefreshMs,
    refetchInterval: cryptoFactsRefreshMs,
    retry: false,
  });
  const facts = query.data;
  const unsupported = query.error instanceof ApiError && query.error.code === "unsupported_crypto";
  return (
    <Card id="crypto-research" className="mt-5">
      <CardHeader title="Token research" />
      {!facts ? (
        <div className="space-y-2 border-t border-border p-4 text-sm text-text-2">
          <p role="status">{query.isPending ? "Loading token research…" : unsupported
            ? "Research is unavailable for this token." : "CoinGecko token research is temporarily unavailable."}</p>
          {query.isError && !unsupported ? <Button size="sm" onClick={() => void query.refetch()} disabled={query.isFetching}>Retry token research</Button> : null}
        </div>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-t border-border px-4 py-3 text-xs text-text-2">
            <a href={facts.sourceURL} target="_blank" rel="noreferrer" className="text-primary-fg underline">Data powered by CoinGecko</a>
            <span>{facts.observedAt ? `Market data as of ${dateTime(facts.observedAt)}` : "Market timestamp unavailable"}</span>
            {facts.observedAt && now - Date.parse(facts.observedAt) > cryptoFactsStaleMs ? <Badge tone="warn">Stale</Badge> : null}
          </div>
          {query.isError && <div className="flex flex-wrap items-center gap-2 px-4 py-2 text-sm text-text-2">
            <p role="status">Refresh failed. Showing the last available research.</p>
            <Button size="sm" onClick={() => void query.refetch()} disabled={query.isFetching}>Retry token research</Button>
          </div>}
          {facts.about && <div className="border-t border-border px-4 py-3">
            <h3 className="text-sm font-semibold text-text">About {facts.name}</h3>
            <p className="mt-2 max-w-3xl text-sm leading-relaxed text-text-2">{facts.about}</p>
          </div>}
          <div className="grid gap-6 border-t border-border p-4 lg:grid-cols-[1.3fr_1fr]">
            <div>
              <h3 className="text-sm font-semibold text-text">Market and supply</h3>
              <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-3">
                <Fact label="Market cap" value={compactUSD(facts.marketCap)} />
                <Fact label="Market cap rank" value={facts.rank ? `#${facts.rank}` : "Unavailable"} />
                <Fact label="Fully diluted valuation" value={compactUSD(facts.fullyDilutedValuation)} />
                <Fact label="24h traded value" value={compactUSD(facts.volume24h)} />
                <Fact label="Circulating supply" value={units(facts.circulatingSupply, facts.symbol)} />
                <Fact label="Total supply" value={units(facts.totalSupply, facts.symbol)} />
                <Fact label="Max supply" value={facts.unlimitedSupply ? "No fixed limit" : units(facts.maxSupply, facts.symbol)} />
                <Fact label="All-time high" value={facts.allTimeHigh ? money(facts.allTimeHigh, "USD") : "Unavailable"} />
                {facts.allTimeHighDate && <Fact label="All-time high date (UTC)" value={facts.allTimeHighDate} />}
              </dl>
              <p className="mt-3 text-xs text-text-2">Traded value covers exchanges tracked by CoinGecko. Execution liquidity depends on the venue and order size.</p>
            </div>
            <div className="min-w-0">
              <h3 className="text-sm font-semibold text-text">Network information</h3>
              <div className="mt-3 space-y-3 text-sm text-text-2">
                {facts.launchedOn ? <p>Launch date <time dateTime={facts.launchedOn}>{facts.launchedOn}</time></p> : null}
                {facts.platforms.length > 0 ? <details>
                  <summary className="min-h-8 cursor-pointer text-text">Token contracts by network ({facts.platforms.length})</summary>
                  <dl className="space-y-2">
                    {facts.platforms.map((platform) => <div key={platform.id}>
                      <dt className="font-medium text-text">{platform.name}</dt>
                      <dd className="break-all font-mono text-xs">{platform.contract}</dd>
                    </div>)}
                  </dl>
                </details> : null}
                {facts.explorers.length > 0 ? <ul className="space-y-1">
                  {facts.explorers.map((url) => <li key={url}>
                    <a href={url} target="_blank" rel="noreferrer" className="break-all text-primary-fg underline">
                      Explorer on {new URL(url).hostname}
                    </a>
                  </li>)}
                </ul> : null}
                {facts.homepage ? <a href={facts.homepage} target="_blank" rel="noreferrer" className="break-all text-primary-fg underline">Project website on {new URL(facts.homepage).hostname}</a> : null}
                {!facts.launchedOn && facts.platforms.length === 0 && facts.explorers.length === 0 && <p>Network details are unavailable.</p>}
              </div>
            </div>
          </div>
        </>
      )}
    </Card>
  );
}

function units(value: number | undefined, symbol: string) {
  return value === undefined ? "Unavailable" : `${compact(value)} ${symbol}`;
}

function Fact({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-xs text-text-2">{label}</dt><dd className="tabular mt-0.5 text-sm font-medium text-text">{value}</dd></div>;
}
