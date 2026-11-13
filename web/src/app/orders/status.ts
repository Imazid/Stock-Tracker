import type { IntentStatus } from "@oms/api.ts";
import type { Tone } from "@/components/ui/Badge";

export const STATUS_LABEL: Record<IntentStatus, string> = {
  draft: "Draft", risk_checked: "Risk checked", awaiting_approval: "Awaiting approval", approved: "Approved",
  submitting: "Submitting", submitted: "Submitted", partially_filled: "Partially filled", filled: "Filled",
  rejected: "Rejected", expired: "Expired", cancelled: "Cancelled", failed: "Failed", reconciliation_required: "Checking with broker",
};

export const STATUS_TONE: Record<IntentStatus, Tone> = {
  draft: "neutral", risk_checked: "primary", awaiting_approval: "warn", approved: "primary", submitting: "primary", submitted: "primary",
  partially_filled: "primary", filled: "up", rejected: "down", expired: "neutral", cancelled: "neutral", failed: "down", reconciliation_required: "warn",
};

export type StatusGroup = "pending" | "working" | "filled" | "stopped" | "attention";

export const GROUP_OF: Record<IntentStatus, StatusGroup> = {
  draft: "pending", risk_checked: "pending", awaiting_approval: "pending", approved: "pending",
  submitting: "working", submitted: "working", partially_filled: "working", filled: "filled",
  rejected: "stopped", expired: "stopped", cancelled: "stopped", failed: "stopped", reconciliation_required: "attention",
};

export const GROUP_LABEL: Record<StatusGroup, string> = { pending: "Needs you", working: "Open at broker", filled: "Filled", stopped: "Stopped", attention: "Being reconciled" };
