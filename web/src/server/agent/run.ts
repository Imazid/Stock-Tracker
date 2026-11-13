// One assistant turn: a streaming tool-use loop against the Claude API, emitted to the browser
// as newline-delimited JSON events. The model only ever sees read/prepare tools (tools.ts);
// there is no path from here to the order functions.

import Anthropic from "@anthropic-ai/sdk";
import { SYSTEM_PROMPT } from "./prompt.ts";
import { asToolResult, runTool, type ToolContext, type ToolName, TOOLS } from "./tools.ts";
import type { AgentSource } from "./tools-schema.ts";

export const MODEL = "claude-opus-5-5";
const MAX_TOOL_ROUNDS = 8;

export type AgentEvent =
  | { type: "text"; delta: string }
  | { type: "tool"; id: string; name: string; status: "running" | "done" | "error"; summary?: string }
  | { type: "sources"; items: AgentSource[] }
  | { type: "card"; card: { kind: string; title: string; href: string; payload: unknown } }
  | { type: "done"; stopReason: string; usage: { input: number; output: number; cacheRead: number; cacheWrite: number } }
  | { type: "error"; code: string; message: string };

/** Prior turns from the browser: plain text only (tool details aren't replayed across turns). */
export interface ChatTurn {
  role: "user" | "assistant";
  content: string;
}

const tools: Anthropic.Tool[] = TOOLS.map((t) => ({ ...t, eager_input_streaming: true }));

export async function runTurn(history: ChatTurn[], ctx: ToolContext, emit: (event: AgentEvent) => void, signal: AbortSignal): Promise<void> {
  const client = new Anthropic();
  const messages: Anthropic.MessageParam[] = history.map((t) => ({ role: t.role, content: t.content }));
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  let jsonRetries = 0;

  for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
    if (signal.aborted) return;
    const stream = client.beta.messages.stream(
      {
        model: MODEL,
        max_tokens: 16000,
        // Opus 5.5 defaults to medium effort; set it explicitly. Thinking is adaptive by default.
        output_config: { effort: "medium" },
        // Frozen system prompt + fixed tool list = a stable, cacheable prefix.
        system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
        tools,
        messages,
        // If a safety classifier declines, the API retries on a fallback model in the same call.
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
      },
      { signal },
    );
    stream.on("text", (delta) => emit({ type: "text", delta }));

    let message: Anthropic.Beta.Messages.BetaMessage;
    try {
      message = await stream.finalMessage();
      jsonRetries = 0;
    } catch (error) {
      // Only an unparseable streamed tool input is retried; API errors go to the caller.
      if (error instanceof Anthropic.APIError || signal.aborted || jsonRetries++ >= 2) throw error;
      continue;
    }
    usage.input += message.usage.input_tokens;
    usage.output += message.usage.output_tokens;
    usage.cacheRead += message.usage.cache_read_input_tokens ?? 0;
    usage.cacheWrite += message.usage.cache_creation_input_tokens ?? 0;

    if (message.stop_reason === "refusal") {
      emit({ type: "error", code: "refusal", message: "The assistant declined to answer that." });
      emit({ type: "done", stopReason: "refusal", usage });
      return;
    }
    const toolUses = message.content.filter((b): b is Anthropic.Beta.Messages.BetaToolUseBlock => b.type === "tool_use");
    if (message.stop_reason !== "tool_use" || toolUses.length === 0) {
      emit({ type: "done", stopReason: message.stop_reason ?? "end_turn", usage });
      return;
    }
    if (round === MAX_TOOL_ROUNDS) {
      emit({ type: "error", code: "too_many_steps", message: "The assistant used too many steps on this question. Try narrowing it." });
      emit({ type: "done", stopReason: "max_tool_rounds", usage });
      return;
    }

    // Append the assistant turn unchanged (thinking blocks included), then all tool results in one user turn.
    messages.push({ role: "assistant", content: message.content as Anthropic.MessageParam["content"] });
    const results = await Promise.all(toolUses.map(async (use) => {
      emit({ type: "tool", id: use.id, name: use.name, status: "running" });
      const outcome = await runTool(use.name, use.input, ctx);
      emit({ type: "tool", id: use.id, name: use.name, status: outcome.isError ? "error" : "done" });
      if (outcome.sources?.length) emit({ type: "sources", items: outcome.sources });
      if (outcome.card) emit({ type: "card", card: outcome.card });
      return {
        type: "tool_result" as const,
        tool_use_id: use.id,
        is_error: outcome.isError === true,
        content: asToolResult(use.name as ToolName, outcome),
      };
    }));
    messages.push({ role: "user", content: results });
  }
}
