"use client";

import { useEffect, useId, useState, type FormEvent } from "react";
import { ArrowDown, ArrowRight, ArrowUp, Search } from "lucide-react";
import { service } from "../lib/backend";
import { fromTicker, instrumentID, popular, venues, type Instrument, type Venue } from "../lib/models";
import { AssetText } from "./ui";

export type Command = { label: string; action: () => void; icon: React.ReactNode };

export default function Palette({ commands, connected, choose, custom, initial = "" }: { commands: Command[]; connected: boolean; choose: (asset: Instrument) => void; custom: (asset: Instrument) => void; initial?: string }) {
  const instructions = useId();
  const [query,setQuery] = useState(initial);
  const [remote,setRemote] = useState<Instrument[]>([]);
  const [cursor,setCursor] = useState(0);
  const [venue,setVenue] = useState<Venue>("us");
  const [manual,setManual] = useState(false);
  const term = query.trim();
  useEffect(() => {
    if (!connected || term.length < 2) return;
    let alive = true;
    const timer = setTimeout(() => { service<Instrument[]>("market",{action:"search",query:term}).then(result => { if (alive) setRemote(result); }).catch(() => {}); },200);
    return () => { alive = false; clearTimeout(timer); };
  }, [connected,term]);
  const local = [...popular,...remote].filter(item => `${item.symbol} ${item.name}`.toLowerCase().includes(term.toLowerCase()));
  const assets = [...new Map(local.map(item => [instrumentID(item),item])).values()].slice(0, term ? 8 : 5);
  const pages = commands.filter(command => !term || command.label.toLowerCase().includes(term.toLowerCase()));
  const rows = [...pages.map(command => ({ key:command.label, label:command.label, node:<span className="command-icon">{command.icon}{command.label}</span>, action:command.action })), ...assets.map(asset => ({ key:instrumentID(asset), label:`${asset.symbol}, ${asset.name}`, node:<AssetText asset={asset}/>, action:() => choose(asset) }))];
  const highlighted = Math.min(rows.length - 1, cursor);

  function submit(event: FormEvent) {
    event.preventDefault();
    if (manual) {
      if (connected && /^[A-Za-z0-9][A-Za-z0-9.-]{0,15}$/.test(term)) custom(fromTicker(term,"",venue));
    } else if (rows[highlighted]) rows[highlighted].action();
  }

  return <form onSubmit={submit} className="palette-form">
    <div className="palette-search"><Search size={20}/><input data-dialog-focus aria-describedby={manual ? undefined : instructions} aria-label={manual ? "Enter a ticker" : "Search assets or jump to a page"} placeholder={manual ? "Enter a ticker" : "Search assets or jump to a page…"} value={query} maxLength={80} onChange={e => { setQuery(e.target.value); setCursor(0); setRemote([]); }}
      onKeyDown={event => {
        if (manual || !rows.length || (event.key !== "ArrowDown" && event.key !== "ArrowUp")) return;
        event.preventDefault(); setCursor((highlighted + (event.key === "ArrowDown" ? 1 : rows.length - 1)) % rows.length);
      }}/></div>
    {!manual && <span className="sr-only" role="status">{rows[highlighted]?.label ?? "No matching results"}</span>}
    {manual ? <div className="form"><label>Exchange<select value={venue} onChange={e => setVenue(e.target.value as Venue)}>{Object.entries(venues).map(([key,value]) => <option key={key} value={key}>{value.title} · {value.currency}</option>)}</select></label><button disabled={!/^[A-Za-z0-9][A-Za-z0-9.-]{0,15}$/.test(term)} className="button primary">Open ticker</button><button className="text-button" type="button" onClick={() => setManual(false)}>Back to search</button></div> :
      <><div className="palette-results">{rows.map((row,index) => <button type="button" key={row.key} className={index === highlighted ? "selected" : ""} onPointerEnter={() => setCursor(index)} onClick={row.action}>{row.node}<ArrowRight size={15}/></button>)}
      {!rows.length && <p className="muted">No matching results.</p>}</div>
      <footer className="palette-footer"><span id={instructions}><ArrowUp size={12} aria-hidden="true"/><ArrowDown size={12} aria-hidden="true"/> <span aria-hidden="true">Navigate <kbd>↵</kbd> Open</span><span className="sr-only">Use the arrow keys to navigate. Press Enter to open.</span></span>{connected && <button type="button" className="text-button" onClick={() => setManual(true)}>Enter any ticker</button>}</footer></>}
  </form>;
}
