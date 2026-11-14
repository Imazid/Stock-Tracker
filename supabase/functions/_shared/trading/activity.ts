import type { AgentRun, TradeProposal, TradingSignal } from "./agent.ts";
import type { AuditEvent } from "./audit.ts";
import type { Fill, Order } from "./orders.ts";
import { addCivilDays, civilDateInZone, instantInZone } from "./calendar.ts";

export interface AgentActivityRow extends Pick<AgentRun, "id" | "agentID" | "strategyVersion" | "trigger" | "startedAt" | "status" | "summary"> {
  agentName: string;
}

export interface AgentActivityPage {
  runs: AgentActivityRow[];
  nextCursor?: string;
}

export interface AgentActivityDetail {
  run: AgentRun;
  agentName?: string;
  signals: TradingSignal[];
  proposals: TradeProposal[];
  orders: Order[];
  fills: Fill[];
  reviews: AuditEvent[];
}

export const ACTIVITY_PERIODS = ["thisWeek", "lastWeek", "lastSevenDays"] as const;
export type AgentActivityPeriod = typeof ACTIVITY_PERIODS[number];

export interface AgentActivitySummary {
  from: number;
  through: number;
  timeZone: string;
  runs: number;
  failedRuns: number;
  skippedRuns: number;
  proposals: number;
  blocked: number;
  approvals: number;
  declines: number;
  fills: number;
  recent: AgentActivityRow[];
}

export function agentActivityWindow(period: AgentActivityPeriod, timeZone: string, now: number) {
  if (period === "lastSevenDays") return { from: now - 7 * 86_400_000, through: now };
  const day = civilDateInZone(timeZone, now);
  const weekday = new Date(Date.UTC(day.year, day.month - 1, day.day)).getUTCDay();
  const monday = addCivilDays(day, -((weekday + 6) % 7));
  const start = instantInZone(timeZone, monday);
  return period === "thisWeek" ? { from: start, through: now }
    : { from: instantInZone(timeZone, addCivilDays(monday, -7)), through: start };
}
