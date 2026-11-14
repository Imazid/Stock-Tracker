"use client";

import Link from "next/link";
import { useEffect, useState, type FormEvent } from "react";
import { ArrowUpRight, ExternalLink, Landmark, Sparkles } from "lucide-react";
import { service } from "../lib/backend";
import { dateText, message, money, qty, venues, type Instrument, type Journal, type Series } from "../lib/models";
import { AssetText, Empty } from "./ui";

type Company = {
  profile: { name: string; industry: string; exchange: string; website: string; currency: string };
  values: { marketCapMillions: number | null; pe: number | null; revenueGrowth: number | null; margin: number | null; beta: number | null; high52: number | null; low52: number | null };
  earnings: { date: string; actual: number | null; estimate: number | null; surprise: number | null }[];
  news: { title: string; url: string; source: string; time: number }[];
  asOf: number;
  source: string;
};
type Chat = { role: "user" | "assistant"; content: string };
const positionsStatusLabels = {
  pending: "Waiting for positions",
  disconnected: "Reconnect to refresh",
  closed: "Closed",
  archived: "Archived",
  unavailable: "Positions unavailable",
} as const;
type Account = { id: string; name?: string | null; institution_name?: string; number?: string;
  positions_status?: "available" | keyof typeof positionsStatusLabels };
type Position = {
  instrument: { id?: string; symbol?: string; description?: string; kind: string };
  units?: string | null; price?: string | null; currency?: string | null; cash_equivalent?: boolean;
};

export function Research({ asset, journal, enabled }: { asset: Instrument; journal: Journal; enabled: boolean }) {
  const [history,setHistory] = useState<Series>();
  const [company,setCompany] = useState<Company>();
  const [companyError,setCompanyError] = useState("");
  const hasCompanyData = asset.venue === "us" && asset.assetClass === "equity";
  const [question,setQuestion] = useState("");
  const [chat,setChat] = useState<Chat[]>([]);
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState("");
  const [aiConsent, setAiConsent] = useState(false);
  const [portfolioContext,setPortfolioContext] = useState(false);
  const [sourceError,setSourceError] = useState("");

  useEffect(() => {
    let alive = true;
    service<Series>("market",{ action:"chart", asset, range:"3M" })
      .then(data => { if (alive) setHistory(data); })
      .catch(failure => { if (alive) setSourceError(message(failure)); });
    if (hasCompanyData) service<Company>("market", { action:"company", asset })
      .then(data => { if (alive) setCompany(data); })
      .catch(error => { if (alive) setCompanyError(message(error)); });
    return () => { alive = false; };
  }, [asset, hasCompanyData]);

  const companyListing = encodeURIComponent(`${asset.venue}:${asset.symbol}`);
  const latest = history?.bars.at(-1);
  const first = history?.bars[0];
  const listing = asset.venue === "crypto" ? `${asset.symbol}-USD` : asset.symbol + (venues[asset.venue].suffix ?? "");
  const source = latest ? `${history!.provenance.source} · ${dateText(latest.time,true)}` : "";
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!enabled || !aiConsent || busy || !question.trim()) return;
    setBusy(true); setError("");
    const next: Chat[] = [...chat, {role:"user",content:question.trim()}];
    try {
      const context = [
        `Selected instrument: ${asset.symbol} (${asset.name}), ${asset.currency}.`,
        latest && first ? `Verified price data from ${source}: latest close ${latest.close}; first close in the chart ${first.close}. Cite the provider and date when using these numbers.` : "No verified price data was returned.",
        company ? `Verified ${company.source} fundamentals retrieved ${dateText(company.asOf,true)}: ${JSON.stringify(company.values)}. Recent earnings: ${JSON.stringify(company.earnings)}. Cite ${company.source} and the reported period or retrieval date when using this data.` : "",
        portfolioContext ? `User opted in to share these tracked holding quantities and USD average costs: ${JSON.stringify(journal.holdings.slice(0, 25).map(row => ({ symbol:row.asset_symbol, quantity:row.shares, averageCost:row.avg_cost })))}` : "",
        "Give factual educational analysis. Ask for missing facts. Do not recommend a specific trade or invent external source links.",
      ].filter(Boolean).join("\n");
      const result = await service<{text:string}>("research",{ purpose:"chat", consent: 1, messages:[{role:"system",content:context}, ...next.slice(-12)] });
      setChat([...next,{role:"assistant",content:result.text}]); setQuestion("");
    } catch (failure) { setError(message(failure)); } finally { setBusy(false); }
  }
  return <><div className="two-grid">
    <section className="panel table-panel"><div className="panel-heading"><h2><Landmark size={18}/> Asset research</h2></div><div className="form panel-form">
      <AssetText asset={asset}/>
      {asset.venue !== "crypto" && <Link className="text-button" href={`/markets/${companyListing}`}>Open Company Intelligence <ExternalLink size={14}/></Link>}
      {latest ? <div className="order-preview"><dl><dt>Latest close</dt><dd>{money(latest.close,asset.currency)}</dd><dt>Session high</dt><dd>{money(latest.high,asset.currency)}</dd><dt>Session low</dt><dd>{money(latest.low,asset.currency)}</dd></dl><p className="muted">{source}</p></div> : <p className="muted">{sourceError || "Loading the latest reported session…"}</p>}
      {company && <div className="order-preview"><strong>{company.profile.name || asset.name}</strong>
        <p className="muted">{[company.profile.industry, company.profile.exchange].filter(Boolean).join(" · ")}</p>
        <dl><dt>Market cap</dt><dd>{company.values.marketCapMillions === null ? "—" : `${qty(company.values.marketCapMillions / 1000)}B ${company.profile.currency}`}</dd>
          <dt>P/E</dt><dd>{company.values.pe === null ? "—" : qty(company.values.pe)}</dd>
          <dt>Revenue growth (TTM)</dt><dd>{company.values.revenueGrowth === null ? "—" : `${qty(company.values.revenueGrowth)}%`}</dd>
          <dt>Net margin (TTM)</dt><dd>{company.values.margin === null ? "—" : `${qty(company.values.margin)}%`}</dd>
          <dt>52-week range</dt><dd>{company.values.low52 === null || company.values.high52 === null ? "—" : `${money(company.values.low52,asset.currency)} – ${money(company.values.high52,asset.currency)}`}</dd>
        </dl><p className="muted">{company.source} · Retrieved {dateText(company.asOf)}</p></div>}
      {hasCompanyData && !company && <p className="muted">{companyError || "Loading company fundamentals…"}</p>}
      <div className="source-links"><a href={`https://finance.yahoo.com/quote/${encodeURIComponent(listing)}/news/`} target="_blank" rel="noreferrer">Market news <ExternalLink size={15}/></a>
        {asset.assetClass !== "crypto" && <a href={`https://finance.yahoo.com/quote/${encodeURIComponent(listing)}/financials/`} target="_blank" rel="noreferrer">Company financials <ExternalLink size={15}/></a>}
        {asset.venue === "us" && <a href={`https://www.sec.gov/edgar/search/#/q=${encodeURIComponent(asset.symbol)}`} target="_blank" rel="noreferrer">Search SEC filings <ExternalLink size={15}/></a>}
      </div>
    </div></section>
    <section className="panel table-panel"><div className="panel-heading"><h2><Sparkles size={18}/> AI research</h2></div>
      {enabled ? <form className="form panel-form" onSubmit={submit}>
        {chat.map((entry,index) => <div className="chat-message" key={index}><strong>{entry.role === "user" ? "You" : "Stock Tracker"}</strong><p>{entry.content}</p></div>)}
        <label>Question<textarea maxLength={2400} rows={3} placeholder={`Summarise the recent price action for ${asset.symbol}`} value={question} onChange={e => setQuestion(e.target.value)} required/></label>
        <label className="checkbox"><input type="checkbox" checked={aiConsent} onChange={e => {
          setAiConsent(e.target.checked);
          if (!e.target.checked) setPortfolioContext(false);
        }}/> Allow the AI provider to receive my question and the selected asset’s research data</label>
        <label className="checkbox"><input type="checkbox" checked={portfolioContext} disabled={!aiConsent} onChange={e => setPortfolioContext(e.target.checked)}/> Include holding quantities and average costs</label>
        {error && <p className="error" role="alert">{error}</p>}
        <button className="button primary" disabled={busy || !aiConsent}>{busy ? "Researching…" : "Ask Stock Tracker"}<ArrowUpRight size={16}/></button>
      </form> : <Empty icon={<Sparkles size={20}/>} title="AI provider awaiting configuration" text="Market prices and research sources are available."/>}
    </section>
  </div>
  {company && <div className="two-grid">
    <section className="panel table-panel"><div className="panel-heading"><h2>Reported earnings</h2></div>
      {company.earnings.length ? <div className="table-scroll"><table><thead><tr><th>Period</th><th>EPS actual</th><th>EPS estimate</th><th>Surprise</th></tr></thead><tbody>
        {company.earnings.map(row => <tr key={row.date}><td>{dateText(row.date,true)}</td><td>{money(row.actual,asset.currency)}</td><td>{money(row.estimate,asset.currency)}</td><td>{row.surprise === null ? "—" : `${qty(row.surprise)}%`}</td></tr>)}
      </tbody></table></div> : <Empty title="No earnings returned"/>}
    </section>
    <section className="panel table-panel"><div className="panel-heading"><h2>Recent company news</h2></div>
      {company.news.length ? company.news.map(item => <a className="list-row" key={item.url} href={item.url} target="_blank" rel="noreferrer"><span><strong>{item.title}</strong><small>{[item.source,dateText(item.time)].filter(Boolean).join(" · ")}</small></span><ExternalLink size={15}/></a>) : <Empty title="No recent stories returned"/>}
    </section>
  </div>}
  </>;
}

export function Connections({ enabled }: { enabled: boolean }) {
  const [accounts,setAccounts] = useState<Account[]>([]);
  const [positions,setPositions] = useState<Position[]>();
  const [selected,setSelected] = useState("");
  const [link,setLink] = useState("");
  const [error,setError] = useState("");
  const [busy,setBusy] = useState(false);
  async function fetchAccounts() {
    const {registered} = await service<{registered:boolean}>("brokerage",{operation:"status"});
    setAccounts(registered ? await service<Account[]>("brokerage",{operation:"listAccounts"}) : []);
    setSelected("");
    setPositions(undefined);
  }
  async function refresh() {
    setBusy(true); setError("");
    try { await fetchAccounts(); } catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  async function connect() {
    setBusy(true); setError(""); setLink("");
    try {
      await service("brokerage",{operation:"registerUser"});
      const result = await service<{redirectURI?:string}>("brokerage",{operation:"loginLink",params:{connectionType:"read",connectionPortalVersion:"v4",immediateRedirect:false}});
      const url = new URL(result.redirectURI ?? "");
      if (url.protocol !== "https:") throw new Error("The connection link is invalid.");
      setLink(url.href);
    } catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  async function load(id: string) {
    setSelected(id); setPositions(undefined); setError(""); setBusy(true);
    try {
      const response = await service<{ results: Position[] }>("brokerage", {operation:"accountAllPositions",params:{accountId:id}});
      setPositions(response.results.filter(position => position.instrument.kind !== "cash" && !position.cash_equivalent));
    }
    catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  return <section className="panel table-panel"><div className="panel-heading"><h2><Landmark size={18}/> Brokerage connections</h2>{enabled && <div className="inline-actions"><button className="button secondary small" disabled={busy} onClick={() => void refresh()}>Refresh accounts</button><button className="button primary small" disabled={busy} onClick={() => void connect()}>Connect brokerage</button></div>}</div>
    {!enabled ? <Empty icon={<Landmark size={20}/>} title="Brokerage provider awaiting configuration" text="Your manually tracked portfolio remains available from your account."/> :
      <>{link && <p className="notice"><a href={link} target="_blank" rel="noreferrer">Open the secure read-only connection portal <ExternalLink size={15}/></a></p>}
        {error && <p className="notice error" role="alert">{error}</p>}
        {!accounts.length && <Empty title="No accounts loaded" text="Refresh your linked accounts or connect a brokerage."/>}
        {accounts.map(account => {
          const status = account.positions_status;
          const restriction = status && status !== "available" ? positionsStatusLabels[status] : undefined;
          return <div key={account.id}><div className="list-row">
            <span><strong>{account.name ?? account.institution_name ?? "Brokerage account"}</strong>
              <small>{[account.institution_name, account.number, restriction].filter(Boolean).join(" · ")}</small></span>
            <button className="button secondary small" disabled={busy || Boolean(restriction)} onClick={() => void load(account.id)}>View positions</button>
          </div>
          {selected === account.id && positions && (positions.length ? positions.map((position, index) => {
            const price = position.price == null ? NaN : Number(position.price);
            const currency = position.currency;
            return <div className="list-row child-row" key={position.instrument.id ?? index}>
              <span><strong>{position.instrument.symbol ?? "Position"}</strong><small>{position.instrument.description}</small></span>
              <span>{position.units != null ? `${position.units} units` : "Units unavailable"} · {
                Number.isFinite(price) && currency && /^[A-Z]{3}$/.test(currency) ? money(price, currency) : "—"
              }</span>
            </div>;
          }) : <Empty title="No reported positions"/>)}</div>;
        })}
      </>}
  </section>;
}
