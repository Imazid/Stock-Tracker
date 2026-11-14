import { validManualSnapshot } from "./manual-snapshot.ts";

const sydneyDay = new Intl.DateTimeFormat("sv-SE", { dateStyle: "short", timeZone: "Australia/Sydney" });

export function accountHolding(value: unknown, now: Date) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const holding = value as Record<string, unknown>;
  if (Object.keys(holding).some((key) => ![
    "id", "name", "assetClass", "currency", "units", "ownership", "shareClass", "lockupUntil",
    "commitment", "valuation", "excerptID",
  ].includes(key))) return null;
  const { excerptID, ...fields } = holding;
  const canonical = {
    ...fields, paid: "0", returned: "0", pendingCalls: "0",
    ...(excerptID !== undefined ? {
      ownershipEvidence: { excerptID, reviewedOn: now.toISOString().replace(/\.\d{3}Z$/, "Z") },
    } : {}),
  };
  const today = Date.parse(`${sydneyDay.format(now)}T00:00:00Z`);
  return validManualSnapshot([canonical], today) ? canonical : null;
}
