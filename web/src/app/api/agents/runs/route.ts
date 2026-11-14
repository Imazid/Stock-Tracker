// POST /api/agents/runs — one research-assistant turn, streamed as NDJSON (AgentEvent per line).
// Body: { messages: { role: "user" | "assistant", content: string }[] } (last one from the user).
//
// Needs ANTHROPIC_API_KEY on the server and a signed-in person (each turn costs money); in local
// development without Supabase it runs signed-out with public market data only.

import Anthropic from "@anthropic-ai/sdk";
import { RESEARCH_SECTIONS, type ResearchSection } from "@/lib/research-types";
import { activityPeriodTitle, agentActivityQuestion } from "@/lib/agent-activity-question";
import { parseInstrumentID } from "@/server/market/instruments";
import { supabaseConfigured } from "@/lib/env";
import { serverSupabase } from "@/lib/supabase/server";
import { type AgentEvent, type ChatTurn, runTurn } from "@/server/agent/run";
import { runOpenAITurn } from "@/server/agent/openai";
import { accountAgentActivity } from "@/server/agent/activity";
import { accountPortfolioRisk } from "@/server/portfolio/risk";
import { portfolioRiskQuestion } from "@/lib/portfolio-risk-question";
import { jsonError, rateLimited } from "@/server/http/respond";

export const runtime = "nodejs";
export const maxDuration = 300;

function decodeHistory(body: unknown): ChatTurn[] {
  if (typeof body !== "object" || body === null) throw new Error("Send a JSON object.");
  const raw = (body as { messages?: unknown }).messages;
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > 40) throw new Error("Send 1 to 40 messages.");
  const turns = raw.map((m) => {
    const t = m as { role?: unknown; content?: unknown };
    if ((t.role !== "user" && t.role !== "assistant") || typeof t.content !== "string" || t.content.trim() === "" || t.content.length > 8000) {
      throw new Error("Each message needs a role (user or assistant) and up to 8000 characters of text.");
    }
    return { role: t.role, content: t.content } as ChatTurn;
  });
  if (turns[turns.length - 1].role !== "user") throw new Error("The last message must be from you.");
  if (turns[0].role !== "user") throw new Error("The conversation must start with your message.");
  return turns;
}

export async function POST(request: Request) {
  const limited = rateLimited(request, 12);
  if (limited) return limited;
  const anthropicConfigured = Boolean(process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN);
  const openAIKey = process.env.OPENAI_API_KEY;
  const supabase = await serverSupabase();
  let owner: string | undefined;
  if (supabase) {
    const { data } = await supabase.auth.getUser();
    owner = data.user?.id;
    if (!owner) return jsonError(401, "unauthenticated", "Sign in to use the assistant.");
  } else if (supabaseConfigured || process.env.NODE_ENV === "production") {
    return jsonError(503, "feature_disabled", "Accounts aren't configured, so the assistant is off.");
  }

  let history: ChatTurn[];
  let shareAccountContext = false;
  let company: { instrumentId: string; section: string } | undefined;
  let timeZone = "UTC";
  try {
    const body = await request.json();
    history = decodeHistory(body);
    shareAccountContext = body.shareAccountContext === true;
    if (typeof body.timeZone === "string" && body.timeZone.length <= 80) {
      try { timeZone = new Intl.DateTimeFormat("en", { timeZone: body.timeZone }).resolvedOptions().timeZone; } catch { /* Use UTC. */ }
    }
    if (body.company !== undefined) {
      const { instrumentId, section } = body.company ?? {};
      if (typeof instrumentId !== "string" || !RESEARCH_SECTIONS.includes(section as ResearchSection)) throw new Error("Choose a company research context.");
      const instrument = parseInstrumentID(instrumentId);
      if (instrument.venue === "crypto") throw new Error("Choose a company or fund listing.");
      company = { instrumentId: `${instrument.venue}:${instrument.symbol}`, section };
    }
  } catch (error) {
    return jsonError(400, "invalid", error instanceof Error ? error.message : "Bad request.");
  }

  const question = history[history.length - 1].content.trim();
  const period = company ? undefined : agentActivityQuestion(question);
  const riskQuestion = !company && portfolioRiskQuestion(question);
  if ((period || riskQuestion) && (!owner || !supabase)) return jsonError(401, "unauthenticated", "Sign in to use account data.");
  if (!period && !riskQuestion && !anthropicConfigured && !openAIKey) return jsonError(503, "feature_disabled", "The assistant is unavailable on this site.");

  const encoder = new TextEncoder();
  const abort = new AbortController();
  request.signal.addEventListener("abort", () => abort.abort());
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const emit = (event: AgentEvent) => {
        try {
          controller.enqueue(encoder.encode(JSON.stringify(event) + "\n"));
        } catch {
          // The browser went away.
        }
      };
      try {
        if (period && supabase) {
          const summary = await accountAgentActivity(supabase, period, timeZone, abort.signal).catch(() => undefined);
          if (!summary) {
            emit({ type: "error", code: "unavailable", message: "Your agent activity could not be loaded. Try again in a moment." });
          } else {
            emit({ type: "activity", title: activityPeriodTitle[period], summary });
          }
          emit({ type: "done", stopReason: "end_turn", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
          return;
        }
        if (riskQuestion && supabase && owner) {
          const summary = await accountPortfolioRisk(supabase, owner, abort.signal).catch(() => undefined);
          if (summary) emit({ type: "portfolio_risk", summary });
          else emit({ type: "error", code: "unavailable", message: "Your portfolio risk summary could not be loaded. Try again in a moment." });
          emit({ type: "done", stopReason: "end_turn", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
          return;
        }
        const context = { supabase: shareAccountContext && !company ? supabase ?? undefined : undefined,
          signedIn: shareAccountContext && !company && Boolean(owner), owner: shareAccountContext && !company ? owner : undefined,
          company, timeZone, now: Date.now(), signal: abort.signal };
        if (anthropicConfigured) await runTurn(history, context, emit, abort.signal);
        else if (openAIKey) await runOpenAITurn(openAIKey, history, context, emit, abort.signal);
      } catch (error) {
        if (error instanceof Anthropic.RateLimitError) emit({ type: "error", code: "rate_limited", message: "The assistant is busy. Try again in a minute." });
        else if (error instanceof Anthropic.AuthenticationError) emit({ type: "error", code: "feature_disabled", message: "The assistant's API key was refused." });
        else if (error instanceof Anthropic.APIError) emit({ type: "error", code: "unavailable", message: `The assistant couldn't answer (${error.status ?? "network"}).` });
        else if (!abort.signal.aborted) emit({ type: "error", code: "internal", message: "Something went wrong." });
      } finally {
        controller.close();
      }
    },
    cancel() {
      abort.abort();
    },
  });
  return new Response(stream, { headers: { "Content-Type": "application/x-ndjson; charset=utf-8", "Cache-Control": "no-store" } });
}
