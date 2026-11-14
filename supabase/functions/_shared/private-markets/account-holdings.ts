import { validManualSnapshot } from "./manual-snapshot.ts";

const sydneyDay = new Intl.DateTimeFormat("sv-SE", { dateStyle: "short", timeZone: "Australia/Sydney" });

export function accountHolding(value: unknown, now: Date) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const holding = value as Record<string, unknown>;
  if (Object.keys(holding).some((key) => ![
    "id", "name", "assetClass", "currency", "units", "ownership", "shareClass", "lockupUntil",
    "commitment", "valuation", "excerptID",
  ].includes(key))) return null;
  const { excerptID, id, ...fields } = holding;
  if (excerptID !== undefined && typeof excerptID !== "string") return null;
  const canonical = {
    ...fields, id: typeof id === "string" ? id.toLowerCase() : id, valuation: fields.valuation, paid: "0", returned: "0", pendingCalls: "0",
    ...(excerptID !== undefined ? {
      ownershipEvidence: { excerptID, reviewedOn: now.toISOString().replace(/\.\d{3}Z$/, "Z") },
    } : {}),
  };
  const today = Date.parse(`${sydneyDay.format(now)}T00:00:00Z`);
  return validManualSnapshot([canonical], today) ? canonical : null;
}
