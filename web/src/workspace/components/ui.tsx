"use client";

import { useId, useLayoutEffect, useRef, type ReactNode } from "react";
import { Activity, ArrowDownRight, ArrowUpRight, Bitcoin, X } from "lucide-react";
import { money, pct, type Instrument, type Series } from "../lib/models";

export function Brand({ small = false }: { small?: boolean }) {
  return <div className={`brand ${small ? "compact" : ""}`}><span className="brand-mark" aria-hidden="true"><Activity size={21} strokeWidth={2.7}/></span>
    <span className="brand-label">Stock<span className="brand-muted"> Tracker</span><small aria-hidden="true">WORKSPACE</small></span></div>;
}

const assetColors: Record<string, string> = { SPY: "violet", QQQ: "blue", BTC: "orange", ETH: "blue", AAPL: "silver", NVDA: "green", MSFT: "blue", SOL: "violet", CBA: "orange" };

export function AssetMark({ asset }: { asset: Instrument }) {
  const color = assetColors[asset.symbol] ?? (asset.assetClass === "crypto" ? "orange" : "blue");
  return <span className={`asset-mark ${color}`} aria-hidden="true">{asset.symbol === "BTC" ? <Bitcoin size={17}/> : asset.symbol.slice(0, 1)}</span>;
}

export function Change({ value }: { value: number | null }) {
  if (value === null || !Number.isFinite(value)) return <span className="muted mono">—</span>;
  return <span className={`change ${value >= 0 ? "up" : "down"}`}>{value >= 0 ? <ArrowUpRight size={13}/> : <ArrowDownRight size={13}/>} {pct(value)}</span>;
}

export function Sparkline({ series }: { series?: Series }) {
  const values = series?.bars.map(bar => bar.close) ?? [];
  if (values.length < 2) return <span className="sparkline"/>;
  const min = Math.min(...values), max = Math.max(...values);
  const d = values.map((value, index) => `${index === 0 ? "M" : "L"}${index / (values.length - 1) * 80} ${27 - (value - min) / (max - min || 1) * 21}`).join(" ");
  return <svg className={`sparkline ${values.at(-1)! >= values[0] ? "up" : "down"}`} viewBox="0 0 80 34" aria-hidden="true"><path d={d}/></svg>;
}

export function AssetText({ asset }: { asset: Instrument }) {
  return <span className="asset-text"><AssetMark asset={asset}/><span><strong>{asset.symbol}</strong><small>{asset.name}</small></span></span>;
}

export function Empty({ icon, title, text, children }: { icon?: ReactNode; title: string; text?: string; children?: ReactNode }) {
  return <div className="empty">{icon && <span className="empty-icon">{icon}</span>}<strong>{title}</strong>{text && <p>{text}</p>}{children}</div>;
}

export function Modal({ title, onClose, children, palette = false }: { title: string; onClose: () => void; children: ReactNode; palette?: boolean }) {
  const headingId = useId();
  const ref = useRef<HTMLDialogElement>(null);
  const close = useRef<HTMLButtonElement>(null);

  useLayoutEffect(() => {
    const dialog = ref.current;
    const opener = document.activeElement;
    dialog?.showModal();
    return () => {
      dialog?.close();
      if (opener instanceof HTMLElement && opener.isConnected && !opener.closest("dialog")) {
        opener.focus({ preventScroll: true });
      }
    };
  }, []);

  useLayoutEffect(() => {
    const initialFocus = ref.current?.querySelector<HTMLElement>("[data-dialog-focus]") ?? close.current;
    initialFocus?.focus({ preventScroll: true });
  }, [title]);

  return <dialog ref={ref} aria-labelledby={headingId} className={`dialog ${palette ? "palette" : ""}`} onCancel={event => { event.preventDefault(); onClose(); }} onClick={event => { if (event.target === event.currentTarget) onClose(); }}>
    <div className="dialog-body"><header><h2 id={headingId}>{title}</h2><button ref={close} type="button" aria-label="Close" className="icon-button" onClick={onClose}><X size={19}/></button></header>{children}</div>
  </dialog>;
}

export function Price({ value, currency }: { value: number | null | undefined; currency?: string }) {
  return <span className="mono">{money(value, currency)}</span>;
}
