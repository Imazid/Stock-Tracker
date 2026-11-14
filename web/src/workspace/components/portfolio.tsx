"use client";

import { useEffect, useId, useState, type FormEvent } from "react";
import Link from "next/link";
import { AlertTriangle, ArrowUpRight, Bell, PieChart, Plus, Star, Trash2, Wallet } from "lucide-react";
import { mainPortfolioId, usePortfolioGroups } from "@/hooks/portfolio-groups";
import { backend, service } from "../lib/backend";
import { dateText, fromHolding, fromWatch, instrumentID, message, money, qty, storedExchange, storedKind, storedTicker, type Holding, type Instrument, type Journal, type Quotes } from "../lib/models";
import { AssetText, Change, Empty } from "./ui";
import { PortfolioHistory } from "./portfolio-history";

export function Portfolio({ userId, journal, onAsset, onAdd, onEdit }: { userId: string; journal: Journal; onAsset: (asset: Instrument) => void; onAdd: () => void; onEdit: (holding: Holding) => void }) {
  const [values, setValues] = useState<Record<string, number>>({});
  const [rates, setRates] = useState<Record<string, number>>({ USD: 1 });
  const [error, setError] = useState("");
  const assetsKey = JSON.stringify([...new Map(journal.holdings.filter(row => row.shares > 0).map(row => {
    const asset = fromHolding(row);
    return [instrumentID(asset), asset];
  })).values()]);

  useEffect(() => {
    let active = true;
    const assets = JSON.parse(assetsKey) as Instrument[];
    if (!assets.length) return;
    const batches = Array.from({ length: Math.ceil(assets.length / 24) }, (_, index) => assets.slice(index * 24, (index + 1) * 24));
    Promise.allSettled([
      Promise.allSettled(batches.map(batch => service<Quotes>("market", { action: "quotes", assets: batch }))),
      assets.some(asset => asset.currency !== "USD") ? service<Record<string, number>>("market", { action: "fx" }) : Promise.resolve<Record<string, number>>({ USD: 1 }),
    ]).then(([quotes, fx]) => {
      if (!active) return;
      const prices: Record<string, number> = {};
      if (quotes.status === "fulfilled") for (const batch of quotes.value) if (batch.status === "fulfilled") {
        for (const asset of assets) {
          const key = instrumentID(asset);
          const last = batch.value.quotes[key]?.last ?? batch.value.series[key]?.bars.at(-1)?.close;
          if (last !== undefined) prices[key] = last;
        }
      }
      setValues(prices);
      setRates(fx.status === "fulfilled" ? fx.value : { USD: 1 });
      setError(assets.some(asset => !prices[instrumentID(asset)] || !(fx.status === "fulfilled" && fx.value[asset.currency])) ? "Some positions are awaiting quotes or exchange rates." : "");
    });
    return () => { active = false; };
  }, [assetsKey]);

  const rows = journal.holdings.map(row => {
    const asset = fromHolding(row), price = values[instrumentID(asset)], rate = rates[asset.currency];
    return { row, asset, usd: price && rate ? price / rate : undefined };
  });
  const open = rows.filter(item => item.row.shares > 0);
  const priced = open.filter(item => item.usd !== undefined);
  const total = priced.reduce((sum, item) => sum + item.row.shares * item.usd!, 0);
  const basis = priced.reduce((sum, item) => sum + item.row.shares * item.row.avg_cost, 0);
  const allocations = ["equity", "etf", "crypto"].map(type => priced.filter(item => item.asset.assetClass === type).reduce((sum, item) => sum + item.usd! * item.row.shares, 0));
  const partial = priced.length < open.length;

  return <>
    <div className="metric-grid">
      <div className="panel metric"><span><Wallet size={16}/> {partial ? "Priced positions" : "Portfolio value"}</span><strong>{open.length && !priced.length ? "—" : money(total)}</strong><small>USD · {priced.length} of {open.length} positions priced</small></div>
      <div className="panel metric"><span><ArrowUpRight size={16}/> Unrealised P&amp;L</span><strong>{priced.length ? money(total - basis) : "—"}</strong><small>{basis > 0 ? <Change value={(total / basis - 1) * 100}/> : "Based on priced holdings"}</small></div>
      <div className="panel metric"><span><PieChart size={16}/> Asset allocation</span><div className="allocation">{allocations.map((amount, index) => <span key={index} style={{ width: `${total ? amount / total * 100 : 0}%` }}/>)}</div><small>Stock · ETF · Crypto</small></div>
    </div>
    {error && <div className="notice"><AlertTriangle size={16}/>{error}</div>}
    <PortfolioHistory userId={userId} />
    <section className="panel table-panel"><div className="panel-heading"><h2>Holdings</h2>
      <div className="inline-actions flex-wrap">
        {open.length > 0 && <Link className="button secondary small" href="/portfolio#holdings">Compare holdings</Link>}
        <button className="button primary small" onClick={onAdd}><Plus size={15}/> Add holding</button>
      </div>
    </div>
      {rows.length ? <div className="table-scroll"><table><thead><tr><th>Asset</th><th>Units</th><th>Average cost</th><th>Value</th><th>Unrealised</th><th><span className="sr-only">Actions</span></th></tr></thead><tbody>
        {rows.map(({row, asset, usd}) => <tr key={row.id}><td><button className="plain" onClick={() => onAsset(asset)}><AssetText asset={asset}/></button></td><td>{qty(row.shares)}</td><td>{money(row.avg_cost)}</td><td>{row.shares === 0 ? money(0) : usd === undefined ? "—" : money(usd * row.shares)}</td><td><Change value={row.shares > 0 && row.avg_cost > 0 && usd !== undefined ? (usd / row.avg_cost - 1) * 100 : null}/></td><td><button className="button small secondary" onClick={() => onEdit(row)}>Edit</button></td></tr>)}
      </tbody></table></div> : <Empty icon={<Wallet size={20}/>} title="No holdings yet" text="Holdings saved in Stock Tracker will appear here."/>}
    </section>
    <section className="panel table-panel"><div className="panel-heading"><h2>Transaction history</h2></div>
      {journal.transactions.length ? <div className="table-scroll"><table><thead><tr><th>Date</th><th>Asset</th><th>Side</th><th>Units</th><th>Price per unit</th></tr></thead><tbody>{journal.transactions.slice(0,100).map(row => <tr key={row.id}><td>{dateText(row.transaction_date,true)}</td><td>{journal.holdings.find(holding => holding.id === row.holding_id)?.asset_symbol ?? "Archived holding"}</td><td>{row.type}</td><td>{qty(row.shares)}</td><td>{money(row.price_per_share)}</td></tr>)}</tbody></table></div> : <Empty title="No synced transactions"/>}
    </section>
  </>;
}

export function PersonalList({ journal, onAsset, onWatch, onAlert, onAlertChange }: {
  journal: Journal; onAsset: (asset: Instrument) => void; onWatch: (asset: Instrument) => void; onAlert: () => void;
  onAlertChange: (id: string, patch: Record<string, unknown>) => void;
}) {
  return <div className="two-grid">
    <section className="panel table-panel"><div className="panel-heading"><h2><Star size={18}/> Saved assets</h2></div>
      {!journal.watch.length && <Empty icon={<Star size={20}/>} title="Your watchlist is empty" text="Star an asset from the market chart or search for a ticker."/>}
      {journal.watch.map(row => { const asset = fromWatch(row); return <div className="list-row" key={row.id}><button className="plain" onClick={() => onAsset(asset)}><AssetText asset={asset}/></button><button className="icon-button" aria-label={`Remove ${asset.symbol}`} onClick={() => onWatch(asset)}><Trash2 size={16}/></button></div>; })}
    </section>
    <section className="panel table-panel"><div className="panel-heading"><h2><Bell size={18}/> Price alerts</h2><button className="button secondary small" onClick={onAlert}><Plus size={15}/> New alert</button></div>
      {!journal.alerts.length && <Empty icon={<Bell size={20}/>} title="No price alerts" text="Create an alert in USD for your selected asset. Alerts sync to iOS for monitoring."/>}
      {journal.alerts.map(row => <div className="list-row" key={row.id}><span><strong>{row.symbol}</strong><small>{row.condition} {money(row.target_price)} USD {row.repeats ? "· Repeating" : ""}</small></span><div className="inline-actions"><button className="button secondary small" onClick={() => onAlertChange(row.id, { is_active: !row.is_active, ...(row.is_active ? {} : { is_armed: true }) })}>{row.is_active ? "Pause" : "Activate"}</button><button className="icon-button" aria-label={`Delete ${row.symbol} alert`} onClick={() => onAlertChange(row.id, { deleted_at: new Date().toISOString() })}><Trash2 size={16}/></button></div></div>)}
    </section>
  </div>;
}

export function JournalForm({ kind, asset, holding, userID, onDone, onReload }: { kind: "holding" | "alert"; asset: Instrument; holding?: Holding; userID: string; onDone: (text: string) => void; onReload?: () => void }) {
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState("");
  const [conflict,setConflict] = useState(false);
  const canSelectPortfolio = kind === "holding" && !holding;
  const portfolioFieldId = useId();
  const { groups } = usePortfolioGroups(canSelectPortfolio ? userID : undefined);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || conflict || !backend || (canSelectPortfolio && !groups.data)) return;
    const form = new FormData(event.currentTarget);
    setBusy(true); setError("");
    try {
      if (kind === "alert") {
        const {error} = await backend.from("price_alerts").insert({ id: crypto.randomUUID(), user_id: userID, symbol: storedTicker(asset), asset_name: asset.name, asset_kind: storedKind(asset), asset_exchange: storedExchange(asset), target_price: Number(form.get("price")), condition: form.get("condition"), repeats: form.get("repeat") === "on" });
        if (error) throw error;
        onDone("Price alert saved.");
      } else {
        const values = { shares: Number(form.get("shares")), avg_cost: Number(form.get("price")) };
        const destination = form.get("portfolio");
        const group = groups.data?.find(item => item.id === destination);
        if (canSelectPortfolio && !group) throw new Error("Choose a portfolio for this holding.");
        const result = holding
          ? await backend.from("portfolio_holdings").update(values).eq("id", holding.id).eq("user_id", userID).eq("ledger_revision", holding.ledger_revision).is("deleted_at",null).select("id").maybeSingle()
          : await backend.from("portfolio_holdings").insert({ ...values, id: crypto.randomUUID(), user_id: userID, asset_symbol: storedTicker(asset), asset_name: asset.name, asset_kind: storedKind(asset), asset_exchange: storedExchange(asset),
              portfolio_group_id: group?.id === mainPortfolioId ? null : group?.id });
        if (result.error) throw result.error;
        if (holding && !result.data) {
          setConflict(true);
          throw new Error("This holding changed after you opened it. Review the current values before editing again.");
        }
        onDone("Holding saved.");
      }
    } catch (failure) { setError(message(failure)); } finally { setBusy(false); }
  }
  return <form className="form" onSubmit={submit}><AssetText asset={asset}/>
    {canSelectPortfolio && <div>
      <label htmlFor={portfolioFieldId}>Portfolio</label>
      <select id={portfolioFieldId} name="portfolio" disabled={!groups.data} required defaultValue={mainPortfolioId}>
        {groups.data ? groups.data.map(group => <option key={group.id} value={group.id}>{group.name}</option>)
          : <option>{groups.isError ? "Portfolios unavailable" : "Loading portfolios…"}</option>}
      </select>
      {groups.isError && <button type="button" className="button secondary small" onClick={() => void groups.refetch()}>Retry</button>}
    </div>}
    {kind === "holding" && <label>Units<input type="number" name="shares" min={holding ? 0 : 0.00000001} max="1000000000000" step="any" required defaultValue={holding?.shares}/></label>}
    {kind === "alert" && <label>Condition<select name="condition"><option>Above</option><option>Below</option></select></label>}
    <label>{kind === "holding" ? "Average cost per unit (USD)" : "Target price (USD)"}<input type="number" name="price" min={kind === "alert" ? 0.00000001 : 0} max="1000000000000" step="any" required defaultValue={holding?.avg_cost}/></label>
    {kind === "alert" && <label className="checkbox"><input type="checkbox" name="repeat"/> Repeat after re-arming</label>}
    {error && <p className="error" role="alert">{error}</p>}
    {conflict ? <button type="button" className="button primary" onClick={onReload}>Reload holdings</button>
      : <button disabled={busy || (canSelectPortfolio && !groups.data)} className="button primary">{busy ? "Saving…" : "Save"}</button>}
  </form>;
}
