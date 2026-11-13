"use client";

import { useRef, useState, type FormEvent } from "react";
import { Activity, ArrowLeftRight, Bot, ClipboardList, FlaskConical, Play, Plus, Shield, SquareActivity, Wallet } from "lucide-react";
import { service } from "../lib/backend";
import { dateText, message, money, pct, qty, venues, type Instrument, type Point, type Provenance } from "../lib/models";
import Chart from "./chart";
import { AssetText, Change, Empty } from "./ui";

type Ledger = { id: string; name: string; kind: string; currency: string; cash: number; realizedPnL: number; startingCash: number; positions: { instrument: Instrument; quantity: number; lastPrice: number }[]; equityHistory: { time: number; equity: number }[] };
type Order = { id: string; instrument: Instrument; side: string; type: string; status: string; quantity: number; filledQuantity: number; createdAt: number };
type Rule = { title: string; summary: string; sizing: { value: number }; universe: Instrument[] };
type Agent = { id: string; name: string; status: string; mode: string; ledgerID?: string; lastRunAt?: number; nextRunAt?: number; reviewEachPaperTrade: boolean; versions: {version: number; spec: Rule}[] };
type Proposal = { id: string; agentID: string; instrument: Instrument; side: string; quantity: number; headline: string; status: string; expiresAt: number; notional: number };
type Log = { id: string; time: number; summary: string; kind: string; sequence: number };
export type TradingState = { ledgers: Ledger[]; orders: Order[]; agents: Agent[]; proposals: Proposal[]; runs: { id: string; summary: string; startedAt: number }[]; audit: { events: Log[] }; accountPolicy: { killSwitchEngaged: boolean } };
type Preview = { canSubmit: boolean; ledgerName: string; estimatedPrice: number; estimatedValue: number; estimatedFee: number; cashAfter: number; quantity: number; currency: string; willQueueUntilOpen: boolean; risk: { checks: { id: string; detail: string; status: string }[] } };
type OrderRequest = { clientOrderID: string; ledgerID: string; instrument: Instrument; side: string; type: string; timeInForce: string; quantity: number; limitPrice?: number; stopPrice?: number; mode: "paper" };
type Backtest = { points: Point[]; endingValue: number; returnPct: number; benchmarkPct: number | null; sessions: number; assumptions: string[]; warnings: string[]; maxDrawdown: number; tradeCount: number; currency: string; provenance: Provenance };
export type TradeAction = (action: string, fields?: Record<string, unknown>, key?: string) => Promise<Record<string, unknown> & { state?: TradingState }>;

const currencies = [...new Set(Object.values(venues).map(value => value.currency))];
const orderStatus: Record<string, string> = { pendingSubmit: "Sending", accepted: "Working", partiallyFilled: "Partly filled", filled: "Filled", canceled: "Cancelled", rejected: "Rejected", expired: "Expired" };
const open = new Set(["pendingSubmit", "accepted", "partiallyFilled"]);

export function PaperDesk({ state, act, onNewOrder, onAsset }: { state: TradingState; act: TradeAction; onNewOrder: () => void; onAsset: (asset: Instrument) => void }) {
  const [busy,setBusy] = useState(false);
  const [notice,setNotice] = useState("");
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setBusy(true); setNotice("");
    try {
      await act("createPortfolio", { name: String(form.get("name")).trim(), startingCash: Number(form.get("cash")), currency: form.get("currency") }, crypto.randomUUID());
      setNotice("Paper portfolio created.");
    } catch (error) { setNotice(message(error)); } finally { setBusy(false); }
  }
  return <>
    {state.accountPolicy.killSwitchEngaged && <div className="notice"><Shield size={16}/> The account kill switch is engaged.</div>}
    <div className="two-grid">
      <section className="panel table-panel"><div className="panel-heading"><h2><Wallet size={18}/> Paper portfolios</h2><button className="button small primary" onClick={onNewOrder}><Plus size={15}/> New paper order</button></div>
        {!state.ledgers.length && <Empty title="No paper portfolios" text="Create a portfolio with virtual cash to start practicing."/>}
        {state.ledgers.map(ledger => <div className="ledger" key={ledger.id}><div className="list-row"><span><strong>{ledger.name}</strong><small>{ledger.kind === "agentPaper" ? "Agent portfolio" : "Manual portfolio"} · {ledger.currency}</small></span><span><strong className="mono">{money(ledger.cash, ledger.currency)}</strong><small>Available cash</small></span></div>
          {ledger.positions.map(position => <div className="list-row child-row" key={position.instrument.symbol}><button className="plain" onClick={() => onAsset(position.instrument)}><AssetText asset={position.instrument}/></button><span className="mono">{qty(position.quantity)} units</span></div>)}
        </div>)}
      </section>
      <section className="panel table-panel"><div className="panel-heading"><h2><Plus size={18}/> Create paper portfolio</h2></div><form className="form panel-form" onSubmit={submit}><label>Name<input name="name" placeholder="My practice portfolio" maxLength={80} required/></label><div className="form-grid"><label>Starting cash<input name="cash" type="number" min="100" defaultValue="10000" step="any" required/></label><label>Currency<select name="currency">{currencies.map(currency => <option key={currency}>{currency}</option>)}</select></label></div><button className="button secondary" disabled={busy}>{busy ? "Creating…" : "Create portfolio"}</button>{notice && <p role="status">{notice}</p>}</form></section>
    </div>
    <section className="panel table-panel"><div className="panel-heading"><h2><ClipboardList size={18}/> Paper orders</h2></div>
      {!state.orders.length ? <Empty title="No paper orders"/> : <div className="table-scroll"><table><thead><tr><th>Asset</th><th>Side</th><th>Units filled</th><th>Status</th><th>Created</th><th><span className="sr-only">Actions</span></th></tr></thead><tbody>{[...state.orders].reverse().map(order => <tr key={order.id}><td><button className="plain" onClick={() => onAsset(order.instrument)}><AssetText asset={order.instrument}/></button></td><td className="titlecase">{order.side}</td><td>{qty(order.filledQuantity)} / {qty(order.quantity)}</td><td><span className="pill">{orderStatus[order.status] ?? order.status}</span></td><td>{dateText(order.createdAt)}</td><td>{open.has(order.status) && <button className="button small secondary" onClick={() => void act("cancelOrder", { orderID: order.id }).catch(() => {})}>Cancel</button>}</td></tr>)}</tbody></table></div>}
    </section>
  </>;
}

export function OrderTicket({ state, asset, act, onDone }: { state?: TradingState; asset: Instrument; act: TradeAction; onDone: (message: string) => void }) {
  const ledgers = state?.ledgers.filter(ledger => ledger.kind === "manualPaper" && ledger.currency === asset.currency) ?? [];
  const [type,setType] = useState("market");
  const [preview,setPreview] = useState<{ result: Preview; order: OrderRequest }>();
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState("");
  const [attempted,setAttempted] = useState(false);
  const outstandingKey = `stock-tracker-order:${ledgers.map(ledger => ledger.id).join(",")}:${asset.venue}:${asset.symbol}`;
  const [unresolved, setUnresolved] = useState<OrderRequest | null>(() => {
    try { return JSON.parse(sessionStorage.getItem(outstandingKey) ?? "null") as OrderRequest | null; }
    catch { return null; }
  });

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    const form = new FormData(event.currentTarget);
    setBusy(true); setError("");
    try {
      if (preview || unresolved) {
        const order = preview?.order ?? unresolved!;
        sessionStorage.setItem(outstandingKey, JSON.stringify(order));
        setAttempted(true);
        const result = await act("placeOrder", { order }, order.clientOrderID);
        sessionStorage.removeItem(outstandingKey);
        setUnresolved(null); setAttempted(false);
        if (!result.accepted) { setError(String(result.summary ?? "The order was rejected.")); setPreview(undefined); return; }
        const status = String(result.status ?? (result.order as Order | undefined)?.status ?? "accepted");
        onDone(`Paper order · ${orderStatus[status] ?? status}`);
        return;
      }
      const order: OrderRequest = {
        mode: "paper", clientOrderID: crypto.randomUUID(), ledgerID: String(form.get("ledger")), instrument: asset,
        side: String(form.get("side")), type, timeInForce: String(form.get("tif")), quantity: Number(form.get("quantity")),
      };
      if (form.has("limit")) order.limitPrice = Number(form.get("limit"));
      if (form.has("stop")) order.stopPrice = Number(form.get("stop"));
      const result = await service<{ preview: Preview }>("trading", { action: "previewOrder", order });
      setPreview({ result: result.preview, order });
    } catch (failure) { setError(message(failure)); } finally { setBusy(false); }
  }

  if (!ledgers.length) return <Empty icon={<Wallet size={20}/>} title={`A ${asset.currency} paper portfolio is required`} text="Create a portfolio on the Paper trading page and return to this asset to submit an order."/>;
  return <form className="form" onSubmit={submit}>
    <AssetText asset={asset}/>
    {preview ? <div className="order-preview">
      <strong className="titlecase">{preview.order.side} {qty(preview.result.quantity)} {asset.symbol}</strong>
      <dl><dt>Portfolio</dt><dd>{preview.result.ledgerName}</dd><dt>Estimated price</dt><dd>{money(preview.result.estimatedPrice, asset.currency)}</dd><dt>Estimated value</dt><dd>{money(preview.result.estimatedValue, asset.currency)}</dd><dt>Estimated fees</dt><dd>{money(preview.result.estimatedFee, asset.currency)}</dd><dt>Cash after order</dt><dd>{money(preview.result.cashAfter, asset.currency)}</dd></dl>
      {preview.result.willQueueUntilOpen && <p className="notice">Queues until the next market session.</p>}
      {preview.result.risk.checks.filter(check => check.status === "failed" || check.status === "warning").map(check => <p key={check.id} className={check.status === "failed" ? "error" : "muted"}>{check.detail}</p>)}
    </div> : unresolved ? <p className="notice">An earlier submission is awaiting confirmation. Retry its original order ID to retrieve the result safely.</p> : <>
      <label>Portfolio<select name="ledger">{ledgers.map(ledger => <option key={ledger.id} value={ledger.id}>{ledger.name} · {money(ledger.cash, ledger.currency)}</option>)}</select></label>
      <div className="form-grid"><label>Side<select name="side"><option value="buy">Buy</option><option value="sell">Sell</option></select></label><label>Order type<select value={type} onChange={e => setType(e.target.value)}><option value="market">Market</option><option value="limit">Limit</option><option value="stop">Stop</option><option value="stopLimit">Stop limit</option></select></label></div>
      <div className="form-grid"><label>Units<input name="quantity" type="number" min=".00000001" step="any" required/></label><label>Time in force<select name="tif"><option value="day">Day</option><option value="gtc">Good till cancelled</option><option value="ioc">Immediate or cancel</option><option value="fok">Fill or kill</option></select></label></div>
      {(type === "limit" || type === "stopLimit") && <label>Limit price ({asset.currency})<input type="number" name="limit" step="any" min=".00000001" required/></label>}
      {(type === "stop" || type === "stopLimit") && <label>Stop price ({asset.currency})<input type="number" name="stop" step="any" min=".00000001" required/></label>}
    </>}
    {error && <p role="alert" className="error">{error}</p>}
    <button className="button primary" disabled={busy || (preview && !preview.result.canSubmit)}>{busy ? "Please wait…" : unresolved || attempted ? "Retry submission" : preview ? "Submit paper order" : "Preview paper order"}</button>
    {preview && !attempted && <button className="text-button" type="button" disabled={busy} onClick={() => { setPreview(undefined); setError(""); }}>Edit order</button>}
  </form>;
}

export function Agents({ state, act }: { state: TradingState; act: TradeAction }) {
  const [selected,setSelected] = useState<Proposal>();
  const [audit,setAudit] = useState("");
  const [busy,setBusy] = useState(false);
  async function change(action: string, fields: Record<string, unknown> = {}) {
    setBusy(true);
    try { await act(action,fields,crypto.randomUUID()); setSelected(undefined); } catch {} finally { setBusy(false); }
  }
  return <>
    <section className="panel table-panel"><div className="panel-heading"><h2><Bot size={18}/> Your agents</h2><button className={`button small ${state.accountPolicy.killSwitchEngaged ? "secondary" : "danger"}`} disabled={busy} onClick={() => void change(state.accountPolicy.killSwitchEngaged ? "releaseKillSwitch" : "engageKillSwitch")}><Shield size={15}/>{state.accountPolicy.killSwitchEngaged ? "Release kill switch" : "Engage kill switch"}</button></div>
      {!state.agents.length && <Empty icon={<Bot size={20}/>} title="No agents yet" text="Prepare a rule in Strategy Studio and save it as a paper agent."/>}
      {state.agents.map(agent => <div className="list-row agent-row" key={agent.id}><span><strong>{agent.name} <span className="pill titlecase">{agent.status}</span></strong><small>{agent.versions.at(-1)?.spec.title} · {agent.mode === "paper" ? "Paper" : agent.mode}{agent.lastRunAt ? ` · Last run ${dateText(agent.lastRunAt)}` : ""}</small></span><div className="inline-actions"><button className="button small secondary" disabled={busy || agent.status !== "active"} onClick={() => void change("runAgent",{agentID:agent.id})}><Play size={14}/> Run</button><button className="button small secondary" disabled={busy} onClick={() => void change(agent.status === "active" ? "pauseAgent" : "resumeAgent",{agentID:agent.id})}>{agent.status === "active" ? "Pause" : "Resume"}</button></div></div>)}
    </section>
    <div className="two-grid">
      <section className="panel table-panel"><div className="panel-heading"><h2><ArrowLeftRight size={18}/> Pending approvals</h2></div>
        {!state.proposals.some(proposal => proposal.status === "pending") && <Empty title="No pending proposals"/>}
        {state.proposals.filter(proposal => proposal.status === "pending").map(proposal => <div className="list-row" key={proposal.id}><span><strong className="titlecase">{proposal.side} {qty(proposal.quantity)} {proposal.instrument.symbol}</strong><small>Expires {dateText(proposal.expiresAt)}</small></span><button className="button small secondary" onClick={() => setSelected(proposal)}>Review</button></div>)}
        {selected && <div className="form panel-form"><strong>{selected.headline}</strong><span>Estimated value {money(selected.notional, selected.instrument.currency)}</span><div className="inline-actions"><button className="button small primary" disabled={busy} onClick={() => void change("approveProposal",{proposalID:selected.id})}>Approve paper trade</button><button className="button small secondary" disabled={busy} onClick={() => void change("rejectProposal",{proposalID:selected.id})}>Reject</button></div></div>}
      </section>
      <section className="panel table-panel"><div className="panel-heading"><h2><SquareActivity size={18}/> Recent runs</h2></div>
        {!state.runs.length && <Empty title="No agent runs"/>}
        {[...state.runs].reverse().slice(0,10).map(run => <div className="list-row" key={run.id}><span><strong>{run.summary || "Agent run"}</strong><small>{dateText(run.startedAt)}</small></span></div>)}
      </section>
    </div>
    <section className="panel table-panel"><div className="panel-heading"><h2><Shield size={18}/> Audit activity</h2><button className="button small secondary" onClick={async () => {
      try { const result = await service<{isIntact:boolean;eventCount:number}>("trading",{action:"auditStatus"}); setAudit(result.isIntact ? `Verified ${result.eventCount} events.` : "The server reported an audit chain mismatch."); }
      catch (error) { setAudit(message(error)); }
    }}>Verify audit chain</button></div>
      {audit && <div className="notice" role="status">{audit}</div>}
      {!state.audit.events.length && <Empty title="No audit activity"/>}
      {[...state.audit.events].reverse().slice(0,25).map(event => <div className="list-row" key={event.sequence}><span><strong>{event.summary}</strong><small>{dateText(event.time)}</small></span></div>)}
    </section>
  </>;
}

export function StrategyStudio({ asset, act }: { asset: Instrument; act: TradeAction }) {
  const [rule,setRule] = useState("Momentum");
  const [budget,setBudget] = useState(10000);
  const [name,setName] = useState("");
  const [spec,setSpec] = useState<Rule>();
  const [backtest,setBacktest] = useState<Backtest>();
  const [error,setError] = useState("");
  const [done,setDone] = useState("");
  const [busy,setBusy] = useState(false);
  const saveKey = useRef<string | null>(null);
  function reset() { setSpec(undefined); setBacktest(undefined); setDone(""); setError(""); saveKey.current = null; }
  async function run(action: "strategy" | "backtest" | "save") {
    if (busy) return;
    setBusy(true); setError(""); setDone("");
    try {
      if (action === "strategy") { const result = await service<{spec:Rule}>("market",{ action, asset, rule }); setSpec(result.spec); }
      if (action === "backtest") { setBacktest(await service<Backtest>("market",{ action, asset, rule, startingCash:budget })); }
      if (action === "save" && spec) {
        saveKey.current ??= crypto.randomUUID();
        const result = await act("createAgent", { draft: { name: name.trim() || spec.title, mode:"paper", spec, budget, maxPositionPct:10, reviewEachPaperTrade:true } }, saveKey.current);
        if (result.agent) setDone("Paper agent saved. Review its proposals on the Agents page.");
      }
    } catch (failure) { setError(message(failure)); } finally { setBusy(false); }
  }
  return <div className="two-grid studio-grid">
    <section className="panel table-panel"><div className="panel-heading"><h2><FlaskConical size={18}/> Strategy rules</h2></div><form className="form panel-form" onSubmit={e => { e.preventDefault(); void run("strategy"); }}>
      <AssetText asset={asset}/><div className="market-filter templates">{["Momentum","Mean reversion","Breakout","Moving average crossover"].map(value => <button type="button" aria-pressed={rule === value} key={value} onClick={() => { setRule(value); reset(); }}>{value}</button>)}</div>
      <label>Rule<textarea rows={3} maxLength={200} value={rule} onChange={e => { setRule(e.target.value); reset(); }} required/></label><p className="muted">Example: Buy when price crosses above its 50-day moving average.</p>
      <div className="form-grid"><label>Agent name<input maxLength={80} value={name} onChange={e => { setName(e.target.value); saveKey.current = null; }}/></label><label>Starting cash ({asset.currency})<input type="number" min="100" max="10000000" step="any" value={budget || ""} onChange={e => { setBudget(Number(e.target.value)); setBacktest(undefined); saveKey.current = null; }} required/></label></div>
      {spec && <div className="order-preview"><strong>{spec.title}</strong><p>{spec.summary}</p><p className="muted">{spec.sizing.value}% equity sizing · Paper approval required</p></div>}
      <div className="inline-actions"><button className="button secondary" disabled={busy}>Prepare rule</button><button className="button primary" type="button" disabled={busy || !spec || !budget || Boolean(done)} onClick={() => void run("save")}>Save paper agent</button></div>
      {error && <p className="error" role="alert">{error}</p>}{done && <p role="status">{done}</p>}
    </form></section>
    <section className="panel price-panel"><div className="panel-heading"><h2><Activity size={18}/> Historical backtest</h2><button className="button small secondary" disabled={busy || !rule.trim() || budget < 100} onClick={() => void run("backtest")}><Play size={14}/> Run backtest</button></div>
      {backtest ? <><div className="backtest-stats"><div><small>Ending value</small><strong>{money(backtest.endingValue,backtest.currency)}</strong><Change value={backtest.returnPct}/></div><div><small>Buy &amp; hold</small><strong>{backtest.benchmarkPct === null ? "—" : pct(backtest.benchmarkPct)}</strong></div><div><small>Max drawdown</small><strong>{backtest.maxDrawdown.toFixed(2)}%</strong></div><div><small>Trades</small><strong>{backtest.tradeCount}</strong></div></div><Chart points={backtest.points} currency={backtest.currency}/><footer className="chart-footer">{backtest.provenance.source} · {backtest.sessions} completed sessions · Next-open fills · 5 bps slippage</footer><details className="panel-form"><summary>Backtest assumptions</summary>{[...backtest.assumptions, ...backtest.warnings].map((line, index) => <p className="muted" key={index}>{line}</p>)}</details></> :
        <Empty icon={<FlaskConical size={20}/>} title="Run against historical prices" text="See simulated returns, drawdown and a buy-and-hold comparison for the selected asset."/>}
    </section>
  </div>;
}
