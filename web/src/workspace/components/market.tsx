"use client";

import { useEffect, useState } from "react";
import { ArrowDown, ArrowRight, ArrowUp, ChartCandlestick, ChartNoAxesCombined, ChevronRight, CircleHelp, Globe, Plus, RefreshCw, Star, TrendingUp } from "lucide-react";
import { service } from "../lib/backend";
import { dateText, instrumentID, message, money, popular, type Instrument, type Quotes, type Range, type Series, type Watch, fromWatch } from "../lib/models";
import Chart from "./chart";
import { AssetText, Change, Empty, Sparkline } from "./ui";

export const ranges: Range[] = ["1D", "1W", "1M", "3M", "1Y"];

export function changeFor(series?: Series) {
  const bars = series?.bars;
  return bars && bars.length >= 2 && bars.at(-2)!.close > 0 ? (bars.at(-1)!.close / bars.at(-2)!.close - 1) * 100 : null;
}

export function Market({ asset, onAsset, signedIn, watch, onWatch, onTrade, onSignIn, full = false }: {
  asset: Instrument; onAsset: (asset: Instrument) => void; signedIn: boolean; watch: Watch[];
  onWatch: (asset: Instrument) => void; onTrade: () => void; onSignIn: () => void; full?: boolean;
}) {
  const [chosenRange, setRange] = useState<Range>("1M");
  const hourly = asset.venue === "us" || asset.venue === "crypto";
  const range = chosenRange === "1D" && !hourly ? "1M" : chosenRange;
  const [mode, setMode] = useState<"line"|"candles">("line");
  const [publicData, setPublicData] = useState<Quotes & { chart: Series | null }>();
  const [detail, setDetail] = useState<Series | null>();
  const [extraData, setExtraData] = useState<Quotes>();
  const [status, setStatus] = useState("");
  const [filter, setFilter] = useState<"All"|"Stocks"|"ETFs"|"Crypto">("All");
  const [refresh, setRefresh] = useState(0);
  const [sourceDataKey, setSourceDataKey] = useState("");
  const [sort, setSort] = useState<"default"|"up"|"down">("default");
  const id = instrumentID(asset);
  const known = popular.some(item => instrumentID(item) === id);
  const publicSymbol = known ? asset.symbol : "SPY";
  const requestKey = `${id}:${range}`;
  const watched = watch.map(fromWatch);
  const watchKey = signedIn ? JSON.stringify(watched.filter(item => !popular.some(p => instrumentID(p) === instrumentID(item))).slice(0, 23)) : "[]";

  useEffect(() => {
    const timer = setInterval(() => { if (!document.hidden) setRefresh(count => count + 1); }, 90_000);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    let alive = true;
    const controller = new AbortController();
    Promise.allSettled([
      fetch(`/api/workspace-overview?symbol=${publicSymbol}&range=${range}`, { signal: controller.signal }).then(async response => {
        if (!response.ok) throw new Error("Market data could not be refreshed.");
        return response.json() as Promise<Quotes & { chart: Series | null }>;
      }),
      !known && signedIn ? service<Series>("market", { action: "chart", asset: { symbol: asset.symbol, venue: asset.venue, assetClass: asset.assetClass }, range }) : Promise.resolve(null),
      signedIn ? (() => {
        const custom = JSON.parse(watchKey) as Instrument[];
        if (!known && !custom.some(item => instrumentID(item) === id)) custom.unshift(asset);
        return custom.length ? service<Quotes>("market", { action: "quotes", assets: custom }) : Promise.resolve(undefined);
      })() : Promise.resolve(undefined),
    ]).then(([overview, specific, extras]) => {
      if (!alive) return;
      setPublicData(current => overview.status === "fulfilled" ? overview.value : current && { ...current, chart: null });
      setDetail(specific.status === "fulfilled" ? specific.value : null);
      setExtraData(extras.status === "fulfilled" ? extras.value : undefined);
      setStatus(specific.status === "rejected" ? message(specific.reason) : overview.status === "rejected" ? message(overview.reason) : "");
      setSourceDataKey(requestKey);
    });
    return () => { alive = false; controller.abort(); };
  }, [asset, id, known, publicSymbol, range, refresh, requestKey, signedIn, watchKey]);

  const quotes = { ...publicData?.quotes, ...extraData?.quotes };
  const daily = { ...publicData?.series, ...extraData?.series };
  const chart = requestKey === sourceDataKey ? (known ? publicData?.chart : detail) : null;
  const quote = quotes[id], displayed = quote?.last ?? chart?.bars.at(-1)?.close;
  const provenance = quote?.provenance ?? chart?.provenance;
  const chartSource = chart?.provenance.source && chart.provenance.source !== provenance?.source ? ` · Chart: ${chart.provenance.source}` : "";
  const inWatch = watched.some(item => instrumentID(item) === id);
  const assets = (full ? [...popular, ...watched.filter(item => !popular.some(p => instrumentID(p) === instrumentID(item)))] : popular.slice(0, 7))
    .filter(item => filter === "All" || (filter === "Stocks" && item.assetClass === "equity") || (filter === "ETFs" && item.assetClass === "etf") || (filter === "Crypto" && item.assetClass === "crypto"))
    .sort((a,b) => sort === "default" ? 0 : (sort === "up" ? -1 : 1) * ((changeFor(daily[instrumentID(a)]) ?? 0) - (changeFor(daily[instrumentID(b)]) ?? 0)));
  const highlights = [popular[0], popular[1], popular[5], popular[6]];
  return <>
    {!full && <div className="market-strip">{highlights.map(item => {
      const key = instrumentID(item);
      return <button className="panel ticker-card" key={key} onClick={() => onAsset(item)}>
        <div className="ticker-top"><AssetText asset={item}/><ArrowRight size={15} className="ticker-arrow"/></div>
        <div className="ticker-bottom"><div><strong className="ticker-price">{money(quotes[key]?.last ?? daily[key]?.bars.at(-1)?.close)}</strong><Change value={changeFor(daily[key])}/></div><Sparkline series={daily[key]}/></div>
      </button>;
    })}</div>}
    <div className="market-grid">
      <section className="panel price-panel">
        <div className="panel-heading"><div className="section-title"><span className="section-icon"><TrendingUp size={17}/></span><div><h2>Market chart</h2><p>Historical market prices</p></div></div>
          <div className="segmented chart-mode"><button aria-label="Line chart" aria-pressed={mode === "line"} onClick={() => setMode("line")}><ChartNoAxesCombined size={17}/></button><button aria-label="Candlestick chart" aria-pressed={mode === "candles"} onClick={() => setMode("candles")}><ChartCandlestick size={17}/></button></div>
        </div>
        <div className="chart-summary">
          <div><div className="asset-context"><strong>{asset.symbol}</strong><span>{asset.name}</span></div><div className="big-value">{money(displayed, asset.currency)}</div><div className="value-change"><Change value={changeFor(daily[id])}/><span>daily close change</span></div></div>
          <div className="segmented ranges" aria-label="Chart time range">{ranges.filter(value => value !== "1D" || hourly).map(value => <button key={value} aria-pressed={range === value} onClick={() => setRange(value)}>{value}</button>)}</div>
        </div>
        <Chart key={requestKey} points={chart?.bars.map(bar => ({ time: bar.time, value: bar.close })) ?? []} candles={mode === "candles" ? chart?.bars : undefined} currency={asset.currency}
          empty={sourceDataKey !== requestKey ? "Loading market history…" : status || "Price history is unavailable."}/>
        <footer className="chart-footer">
          <span title={quote ? dateText(quote.time) : undefined}><Globe size={14}/>{provenance ? `${provenance.source}${provenance.delaySeconds ? ` · ${Math.round(provenance.delaySeconds / 60)} min delayed` : ""}${quote ? ` · ${dateText(quote.time)}` : " · Historical close"}${chartSource}` : "Source shown when prices are available"}</span>
          <div className="inline-actions"><button className="icon-button" onClick={() => setRefresh(value => value + 1)} aria-label="Refresh quotes"><RefreshCw size={15}/></button>
            <button className={`icon-button ${inWatch ? "starred" : ""}`} onClick={() => signedIn ? onWatch(asset) : onSignIn()} aria-label={inWatch ? "Remove from watchlist" : "Add to watchlist"}><Star size={16} fill={inWatch ? "currentColor" : "none"}/></button>
            {signedIn && <button className="button small secondary" onClick={onTrade}>Paper order</button>}
          </div>
        </footer>
      </section>
      <section className="panel movers-panel">
        <div className="panel-heading"><div className="section-title"><span className="section-icon"><Globe size={17}/></span><div><h2>Market watch</h2><p>Stocks, funds and crypto</p></div></div><button className="icon-button" aria-label="Change daily move sort" onClick={() => setSort(value => value === "default" ? "up" : value === "up" ? "down" : "default")}>{sort === "down" ? <ArrowUp size={17}/> : <ArrowDown size={17}/>}</button></div>
        <div className="market-filter">{(["All", "Stocks", "ETFs", "Crypto"] as const).map(value => <button key={value} aria-pressed={filter === value} onClick={() => setFilter(value)}>{value}</button>)}</div>
        <div className="watch-header"><span>Asset</span><span>Price / Change</span></div>
        <div>{assets.map(item => {
          const key = instrumentID(item);
          return <button className={`watch-row ${key === id ? "selected" : ""}`} key={key} onClick={() => onAsset(item)} aria-pressed={key === id}>
            <AssetText asset={item}/><span><strong className="mono">{money(quotes[key]?.last ?? daily[key]?.bars.at(-1)?.close, item.currency)}</strong><Change value={changeFor(daily[key])}/></span><ChevronRight className="row-chevron" size={14}/>
          </button>;
        })}</div>
        {!assets.length && <Empty icon={<CircleHelp size={18}/>} title="No assets for this filter"/>}
        <button className="text-button watch-action" onClick={() => signedIn ? onWatch(asset) : onSignIn()}>{signedIn && inWatch ? <Star size={15}/> : <Plus size={15}/>} {signedIn ? inWatch ? "Remove selected from watchlist" : "Watch selected asset" : "Sign in to build a watchlist"} <ArrowRight size={14}/></button>
      </section>
    </div>
  </>;
}
