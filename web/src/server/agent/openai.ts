import type { AgentEvent, ChatTurn } from "./run.ts";
import { COMPANY_RESEARCH_TOOLS } from "./tools-schema.ts";
import { SYSTEM_PROMPT } from "./prompt.ts";
import { asToolResult, runTool, type ToolContext, type ToolName, TOOLS } from "./tools.ts";

const maxToolRounds = 4;
const model = "gpt-4o-mini";
const tools = TOOLS.map(({ name, description, input_schema }) => ({
  type: "function" as const, function: { name, description, parameters: input_schema },
}));

interface ToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

interface Completion {
  choices?: Array<{ message: { content?: string | null; tool_calls?: ToolCall[] }; finish_reason: string }>;
  usage?: { prompt_tokens: number; completion_tokens: number };
}

type Message =
  | { role: "system" | "user" | "assistant"; content: string | null; tool_calls?: ToolCall[] }
  | { role: "tool"; tool_call_id: string; content: string };

export async function runOpenAITurn(
  key: string,
  history: ChatTurn[],
  ctx: ToolContext,
  emit: (event: AgentEvent) => void,
  signal: AbortSignal,
) {
  const messages: Message[] = [{ role: "system", content: SYSTEM_PROMPT }, ...history];
  if (ctx.company) {
    const current = messages.at(-1)!;
    current.content = `Active company listing: ${ctx.company.instrumentId}. Active research section: ${ctx.company.section}.\n\n${current.content}`;
  }
  const activeTools = ctx.company ? tools.filter((tool) => COMPANY_RESEARCH_TOOLS.has(tool.function.name)) : tools;
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

  for (let round = 0; round <= maxToolRounds; round++) {
    if (signal.aborted) return;
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model, messages, tools: activeTools, max_completion_tokens: 900, store: false }),
      signal: AbortSignal.any([signal, AbortSignal.timeout(20_000)]),
      cache: "no-store",
    });
    if (!response.ok) {
      await response.body?.cancel();
      const limited = response.status === 429;
      emit({ type: "error", code: limited ? "rate_limited" : "unavailable",
        message: limited ? "The assistant is busy. Try again in a minute." : "The assistant provider is unavailable." });
      return;
    }
    const completion = await response.json() as Completion;
    const choice = completion.choices?.[0];
    if (!choice) throw new Error("The model returned no answer.");
    usage.input += completion.usage?.prompt_tokens ?? 0;
    usage.output += completion.usage?.completion_tokens ?? 0;

    const calls = choice.message.tool_calls ?? [];
    if (calls.length === 0) {
      if (choice.message.content) emit({ type: "text", delta: choice.message.content });
      else emit({ type: "error", code: "no_answer", message: "The assistant returned no answer." });
      emit({ type: "done", stopReason: choice.finish_reason, usage });
      return;
    }
    if (round === maxToolRounds || calls.length > 8) {
      emit({ type: "error", code: "too_many_steps", message: "The assistant used too many steps. Try a narrower question." });
      emit({ type: "done", stopReason: "max_tool_rounds", usage });
      return;
    }

    messages.push({ role: "assistant", content: choice.message.content ?? null, tool_calls: calls });
    const outcomes = await Promise.all(calls.map(async (call): Promise<Message> => {
      const { name, arguments: raw } = call.function;
      emit({ type: "tool", id: call.id, name, status: "running" });
      let input: unknown;
      try { input = JSON.parse(raw); } catch { input = null; }
      const result = !ctx.company || COMPANY_RESEARCH_TOOLS.has(name)
        ? await runTool(name, input, ctx)
        : { data: { error: "This conversation is scoped to company research." }, isError: true };
      emit({ type: "tool", id: call.id, name, status: result.isError ? "error" : "done" });
      if (result.sources?.length) emit({ type: "sources", items: result.sources });
      if (result.card) emit({ type: "card", card: result.card });
      return { role: "tool", tool_call_id: call.id, content: asToolResult(name as ToolName, result) };
    }));
    messages.push(...outcomes);
  }
}
