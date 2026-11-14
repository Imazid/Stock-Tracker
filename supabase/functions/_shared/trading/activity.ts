import type { AgentRun, TradeProposal, TradingSignal } from "./agent.ts";
import type { AuditEvent } from "./audit.ts";
import type { Fill, Order } from "./orders.ts";

export interface AgentActivityRow extends Pick<AgentRun, "id" | "agentID" | "strategyVersion" | "trigger" | "startedAt" | "status" | "summary"> {
  agentName: string;
}

export interface AgentActivityPage {
  runs: AgentActivityRow[];
  nextCursor?: string;
}

export interface AgentActivityDetail {
  run: AgentRun;
  signals: TradingSignal[];
  proposals: TradeProposal[];
  orders: Order[];
  fills: Fill[];
  reviews: AuditEvent[];
}
