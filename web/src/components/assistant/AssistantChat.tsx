"use client";

import { ArrowUp, BrainCircuit, CircleAlert, ExternalLink, FileText, FlaskConical, Loader2, RotateCcw, Square, Ticket } from "lucide-react";
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Notice } from "@/components/ui/Notice";
import { type AssistantTurn, toolLabel, useAssistant } from "@/hooks/assistant";
import { getJSON } from "@/lib/api";
import { cn } from "@/lib/cn";
import { useSession } from "@/lib/session";

export const SUGGESTIONS = [
  "How has BHP done over the last year compared with the ASX 200?",
  "Compare BTC and ETH volatility over the last 3 months.",
  "What's in my watchlist today, and what moved the most?",
  "Backtest buying BTC when the 20-day average crosses above the 50-day, exiting on the reverse.",
  "Prepare a ticket to buy 5 AAPL with a limit at today's bid.",
];

function CardIcon({ kind }: { kind: string }) {
  if (kind === "order_ticket") return <Ticket aria-hidden className="h-4 w-4" />;
  if (kind === "backtest") return <FlaskConical aria-hidden className="h-4 w-4" />;
  return <FileText aria-hidden className="h-4 w-4" />;
}

function Turn({ turn }: { turn: AssistantTurn }) {
  if (turn.role === "user") {
    return <div className="ml-auto max-w-[85%] whitespace-pre-wrap rounded-2xl rounded-br-md bg-primary/15 px-3.5 py-2 text-[13px] text-text">{turn.text}</div>;
  }
  return (
    <div className="space-y-2">
      {turn.tools.length > 0 ? (
        <ul className="flex flex-wrap gap-1.5" aria-label="Steps">
          {turn.tools.map((t) => (
            <li key={t.id}>
              <Badge tone={t.status === "error" ? "down" : t.status === "running" ? "warn" : "neutral"}>
                {t.status === "running" ? <Loader2 aria-hidden className="mr-1 inline h-3 w-3 animate-spin" /> : null}
                {toolLabel(t.name)}{t.status === "error" ? " — unavailable" : ""}
              </Badge>
            </li>
          ))}
        </ul>
      ) : null}
      {turn.text ? <div className="whitespace-pre-wrap text-[13px] leading-relaxed text-text">{turn.text}</div> : null}
      {!turn.done && !turn.text ? <p className="text-[13px] text-text-3">Working…</p> : null}
      {turn.cards.map((card, i) => (
        <Link key={i} href={card.href} className="flex items-center gap-2 rounded-lg border border-border bg-surface-2 px-3 py-2 text-[13px] hover:border-primary/50">
          <CardIcon kind={card.kind} />
          <span className="flex-1 font-medium text-text">{card.title}</span>
          <span className="text-text-3">{card.kind === "order_ticket" ? "Review — nothing is sent" : "Open"}</span>
          <ExternalLink aria-hidden className="h-3.5 w-3.5 text-text-3" />
        </Link>
      ))}
      {turn.sources.length > 0 ? (
        <details className="text-[12px] text-text-3">
          <summary className="cursor-pointer select-none">Sources ({turn.sources.length})</summary>
          <ul className="mt-1 space-y-0.5">
            {turn.sources.map((s, i) => (
              <li key={i}>{s.url ? <a href={s.url} target="_blank" rel="noreferrer" className="text-primary-fg hover:underline">{s.label}</a> : s.label} · {s.source}{s.observedAt ? ` · ${new Date(s.observedAt).toLocaleString()}` : ""}{s.status ? ` · ${s.status.replace("_", "-")}` : ""}</li>
            ))}
          </ul>
        </details>
      ) : null}
      {turn.error ? (
        <p role="status" className="flex items-start gap-1.5 text-[13px] text-down"><CircleAlert aria-hidden className="mt-0.5 h-4 w-4 shrink-0" />{turn.error.message}</p>
      ) : null}
    </div>
  );
}

interface Status { assistant: boolean; accounts: boolean }

/** The chat itself; `compact` for the side panel, full size for the AI Workspace page. */
export function AssistantChat({ compact = false, company, reportRequest = 0 }: {
  compact?: boolean;
  company?: { instrumentId: string; symbol: string; section: string };
  reportRequest?: number;
}) {
  const { turns, busy, send, stop, reset } = useAssistant(company?.instrumentId, company?.section);
  const reportPrompt = company
    ? `Write a source-backed investment research report on ${company.symbol}, covering business, performance, finances, valuation, risks, recent filings, earnings and peers. Cite the evidence and mark missing datasets.`
    : undefined;
  const suggestions = reportPrompt ? [
    reportPrompt,
    "How has operating cash flow changed over the last five years?",
    "What do the latest reported results show about profitability and financial risk?",
  ] : SUGGESTIONS;
  const [draft, setDraft] = useState("");
  const bottom = useRef<HTMLDivElement>(null);
  const session = useSession();
  const lastReportRequest = useRef(0);
  const status = useQuery({ queryKey: ["status"], queryFn: () => getJSON<Status>("/api/status"), staleTime: 60_000 });

  useEffect(() => {
    if (!turns.length) return;
    bottom.current?.scrollIntoView({ block: "end" });
  }, [turns]);

  useEffect(() => {
    if (!reportPrompt || reportRequest <= lastReportRequest.current || !status.data || busy || session.status === "loading") return;
    lastReportRequest.current = reportRequest;
    if (status.data.assistant && (!status.data.accounts || session.status === "signedIn")) void send(reportPrompt);
  }, [busy, reportPrompt, reportRequest, send, session.status, status.data]);

  const submit = (text: string) => {
    if (!text.trim()) return;
    setDraft("");
    void send(text);
  };

  const unavailable = status.data && !status.data.assistant;

  return (
    <div className={cn("flex min-h-0 flex-1 flex-col", compact ? "" : "rounded-xl border border-border bg-surface")}>
      <div className={cn("min-h-0 flex-1 space-y-4 overflow-y-auto", compact ? "p-4" : "p-5")} aria-live="polite">
        {unavailable ? (
          <Notice tone="warn" title="The assistant isn't switched on for this site">
            The server needs an <code className="rounded bg-surface px-1">ANTHROPIC_API_KEY</code>{status.data?.accounts ? "" : " and accounts (Supabase) configured"}. Nothing here answers until then.
          </Notice>
        ) : null}
        {turns.length === 0 ? (
          <div className="space-y-3">
            <div className="flex items-center gap-2 text-sm font-medium text-text"><BrainCircuit aria-hidden className="h-4 w-4 text-primary-fg" />{company ? `Ask about ${company.symbol}` : "Ask about markets, your watchlist or a strategy"}</div>
            <p className="text-[13px] leading-relaxed text-text-2">
              {company ? "Research uses the selected listing, company datasets and source documents available to this app." : <>Answers come from the app&apos;s market data and your own lists, with sources and times. It can draft a strategy, run a backtest or fill in an order ticket for you to review — it never places, approves or sends an order. General information only, not personal advice.</>}
            </p>
            <ul className="space-y-1.5">
              {suggestions.slice(0, compact ? 3 : suggestions.length).map((s, i) => (
                <li key={s}>
                  <button type="button" disabled={busy || unavailable} onClick={() => submit(s)} className="w-full rounded-lg border border-border px-3 py-2 text-left text-[13px] text-text-2 hover:border-primary/50 hover:text-text disabled:opacity-50">{company && i === 0 ? "Generate AI research report" : s}</button>
                </li>
              ))}
            </ul>
          </div>
        ) : (
          turns.map((t, i) => <Turn key={i} turn={t} />)
        )}
        <div ref={bottom} />
      </div>
      <form
        className="border-t border-border p-3"
        onSubmit={(e) => {
          e.preventDefault();
          submit(draft);
        }}
      >
        <label htmlFor={company ? "company-assistant-input" : compact ? "assistant-input-panel" : "assistant-input"} className="sr-only">Message the assistant</label>
        <div className="flex items-end gap-2">
          <textarea
            id={company ? "company-assistant-input" : compact ? "assistant-input-panel" : "assistant-input"}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                submit(draft);
              }
            }}
            rows={compact ? 2 : 3}
            maxLength={8000}
            disabled={unavailable}
            placeholder={unavailable ? "Not available on this site" : "Ask a question…"}
            className="min-h-0 flex-1 resize-none rounded-lg border border-border bg-surface-2 px-3 py-2 text-[13px] text-text placeholder:text-text-3 focus:border-primary focus:outline-none disabled:opacity-50"
          />
          {busy ? (
            <Button type="button" variant="secondary" size="sm" onClick={stop} aria-label="Stop"><Square className="h-4 w-4" /></Button>
          ) : (
            <Button type="submit" variant="primary" size="sm" disabled={!draft.trim() || unavailable} aria-label="Send"><ArrowUp className="h-4 w-4" /></Button>
          )}
        </div>
        {turns.length > 0 ? (
          <button type="button" onClick={reset} className="mt-2 inline-flex items-center gap-1 text-[12px] text-text-3 hover:text-text"><RotateCcw aria-hidden className="h-3 w-3" />New conversation</button>
        ) : null}
      </form>
    </div>
  );
}
