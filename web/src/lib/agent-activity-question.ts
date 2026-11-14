import type { AgentActivityPeriod } from "@engine/activity.ts";

export const AGENT_ACTIVITY_QUESTION = "What did my agents do this week?";

export function agentActivityQuestion(text: string): AgentActivityPeriod | undefined {
  const question = text.toLowerCase().replace(/^please\s+/, "").replace(/[?.!]+$/, "").trim();
  const match = /^(?:what (?:did|have) my agents (?:do|done)|show(?: me)? (?:what my agents have done|my agents[’']? activity)|summari[sz]e my agents[’']? activity) (?:in |over |for )?(the )?(this week|last week|last (?:7|seven) days)$/.exec(question);
  if (!match) return undefined;
  return match[2] === "this week" ? "thisWeek" : match[2] === "last week" ? "lastWeek" : "lastSevenDays";
}

export const activityPeriodTitle = {
  thisWeek: "Agent activity this week", lastWeek: "Agent activity last week", lastSevenDays: "Agent activity in the last seven days",
} as const;
