"use client";

// Conversation state for the research assistant. One turn = POST /api/agents/runs with the
// plain-text history, read back as NDJSON events (see server/agent/run.ts AgentEvent).

import { useCallback, useEffect, useRef, useState } from "react";
import type { AgentEvent } from "@/server/agent/run";

export interface AssistantTool {
  id: string;
  name: string;
  status: "running" | "done" | "error";
}

export interface AssistantTurn {
  role: "user" | "assistant";
  text: string;
  tools: AssistantTool[];
  sources: Extract<AgentEvent, { type: "sources" }>["items"];
  cards: Extract<AgentEvent, { type: "card" }>["card"][];
  error?: { code: string; message: string };
  done: boolean;
}

const TOOL_LABELS: Record<string, string> = {
  search_instruments: "Searching instruments",
  get_quote: "Getting a quote",
  get_price_history: "Reading price history",
  get_company_research: "Collecting company evidence",
  get_company_dataset: "Reading company data",
  search_filing_text: "Searching the original filing",
  get_watchlist: "Reading your watchlist",
  get_portfolio: "Reading your portfolio",
  explain_portfolio_movement: "Calculating portfolio movement",
  draft_strategy: "Drafting a strategy",
  run_backtest: "Running a backtest",
  prepare_order_ticket: "Preparing an order ticket",
};
export const toolLabel = (name: string) => TOOL_LABELS[name] ?? name;

async function errorFrom(response: Response): Promise<{ code: string; message: string }> {
  const body = (await response.json().catch(() => undefined)) as { error?: { code?: string; message?: string } } | undefined;
  return { code: body?.error?.code ?? `http_${response.status}`, message: body?.error?.message ?? `The assistant answered ${response.status}.` };
}

export function useAssistant(instrumentId?: string, section?: string) {
  const [turns, setTurns] = useState<AssistantTurn[]>([]);
  const [busy, setBusy] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  useEffect(() => () => abortRef.current?.abort(), []);

  const update = (fn: (turn: AssistantTurn) => AssistantTurn) =>
    setTurns((all) => (all.length === 0 ? all : [...all.slice(0, -1), fn(all[all.length - 1])]));

  const send = useCallback(async (text: string, shareAccountContext: boolean) => {
    const message = text.trim();
    if (!message || busy) return;
    const history = [...turns.filter((t) => t.text.trim() !== "" && !t.error), { role: "user" as const, text: message }]
      .map((t) => ({ role: t.role, content: t.text }));
    setTurns((all) => [
      ...all,
      { role: "user", text: message, tools: [], sources: [], cards: [], done: true },
      { role: "assistant", text: "", tools: [], sources: [], cards: [], done: false },
    ]);
    setBusy(true);
    const abort = new AbortController();
    abortRef.current = abort;
    try {
      const response = await fetch("/api/agents/runs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages: history.slice(-39).filter((turn, index) => index !== 0 || turn.role === "user"), shareAccountContext, company: instrumentId && section ? { instrumentId, section } : undefined }),
        signal: abort.signal,
      });
      if (!response.ok || !response.body) {
        const error = await errorFrom(response);
        update((t) => ({ ...t, error, done: true }));
        return;
      }
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let newline: number;
        while ((newline = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (!line) continue;
          let event: AgentEvent;
          try {
            event = JSON.parse(line) as AgentEvent;
          } catch {
            continue;
          }
          update((t) => {
            switch (event.type) {
              case "text": return { ...t, text: t.text + event.delta };
              case "tool": {
                const others = t.tools.filter((x) => x.id !== event.id);
                return { ...t, tools: [...others, { id: event.id, name: event.name, status: event.status }] };
              }
              case "sources": return { ...t, sources: [...t.sources, ...event.items] };
              case "card": return { ...t, cards: [...t.cards, event.card] };
              case "error": return { ...t, error: { code: event.code, message: event.message } };
              case "done": return { ...t, done: true };
            }
          });
        }
      }
      update((t) => ({ ...t, done: true }));
    } catch {
      if (!abort.signal.aborted) update((t) => ({ ...t, error: { code: "network", message: "The assistant couldn't be reached." }, done: true }));
      else update((t) => ({ ...t, done: true }));
    } finally {
      setBusy(false);
      abortRef.current = null;
    }
  }, [busy, turns, instrumentId, section]);

  const stop = useCallback(() => abortRef.current?.abort(), []);
  const reset = useCallback(() => {
    abortRef.current?.abort();
    setTurns([]);
  }, []);

  return { turns, busy, send, stop, reset };
}
