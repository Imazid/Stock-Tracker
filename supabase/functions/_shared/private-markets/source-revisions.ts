import { utf8 } from "../secure/encoding.ts";

/** Compare published content while ignoring re-verification timestamps and object key order. */
export async function sourceRevision(value: unknown): Promise<string> {
  const canonical = JSON.stringify(value, (key, item) => {
    if (key === "verified_at") return undefined;
    if (!item || typeof item !== "object" || Array.isArray(item)) return item;
    return Object.fromEntries(Object.entries(item).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0));
  });
  const digest = await crypto.subtle.digest("SHA-256", utf8(canonical));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function announcementRevision(item: {
  company_name: string; title: string; significance: string; published_at: string; source_url: string;
}): Promise<string> {
  return sourceRevision([item.company_name, item.title, item.significance, Date.parse(item.published_at), item.source_url]);
}

export function fundingRoundRevision<T extends { round: {
  share_classes: { name: string; rights: string; source_url?: string }[];
  financing_structure?: string | null;
  capital_commitments?: number | null;
  secondary_purchase_amount?: number | null;
  secondary_closed_on?: string | null;
} }>(
  deal: T,
): Promise<string> {
  const shareClasses = deal.round.share_classes.toSorted((a, b) => {
    const left = JSON.stringify([a.name, a.rights, a.source_url]);
    const right = JSON.stringify([b.name, b.rights, b.source_url]);
    return left < right ? -1 : left > right ? 1 : 0;
  });
  const { financing_structure, capital_commitments, secondary_purchase_amount, secondary_closed_on, ...round } = deal.round;
  // Keep hashes comparable with reports saved before these fields were present.
  return sourceRevision({
    ...deal,
    round: { ...round, share_classes: shareClasses, financing_structure: financing_structure ?? undefined,
      capital_commitments: capital_commitments ?? undefined,
      secondary_purchase_amount: secondary_purchase_amount ?? undefined, secondary_closed_on: secondary_closed_on ?? undefined },
  });
}

export async function changedSourceIds<T extends { id: string }>(
  records: T[], saved: Record<string, string> | undefined, revision: (item: T) => Promise<string>,
): Promise<string[]> {
  if (!saved) return [];
  const changes = await Promise.all(records.map(async (item) =>
    Object.hasOwn(saved, item.id) && saved[item.id] !== await revision(item) ? item.id : null));
  return changes.filter((id): id is string => id !== null);
}

type PublishedRoundTerms = {
  stage: string; currency: string; raised: number | null; target: number | null;
  valuation: number | null; valuation_method: string | null; closes_at: string | null;
  financing_structure?: "fund" | "spv" | null; capital_commitments?: number | null;
  secondary_purchase_amount?: number | null; secondary_closed_on?: string | null;
};

export type SourceBaseline = { title: string; fields: Record<string, string | null> };
export type SourceChange = {
  source_id: string;
  title: string;
  fields: { field: string; previous: string | null; current: string | null }[];
};

export function fundingRoundBaseline(deal: { round: PublishedRoundTerms & { company: { name: string } };
  status: string; minimum: number | null; eligibility: string; jurisdictions: string[] }): SourceBaseline {
  const { round } = deal;
  const money = (value: number | null) => value === null ? null : `${round.currency} ${value}`;
  return {
    title: `${round.company.name} · ${round.stage}`,
    fields: {
      "Stage": round.stage,
      "Financing structure": round.financing_structure === "fund" ? "Fund"
        : round.financing_structure === "spv" ? "Special-purpose vehicle" : null,
      "Disclosed valuation": money(round.valuation),
      "Valuation basis": round.valuation_method,
      "Capital raised": money(round.raised),
      "Capital commitments": money(round.capital_commitments ?? null),
      "Secondary purchase amount": money(round.secondary_purchase_amount ?? null),
      "Secondary transaction closed on": round.secondary_closed_on ?? null,
      "Raise target": money(round.target),
      "Minimum investment": money(deal.minimum),
      "Published status": deal.status,
      "Published deadline": round.closes_at ? new Date(round.closes_at).toISOString() : null,
      "Eligibility": deal.eligibility,
      "Jurisdictions": [...deal.jurisdictions].sort().join(", ") || null,
    },
  };
}

export function announcementBaseline(item: { company_name: string; title: string; significance: string }): SourceBaseline {
  return { title: `${item.company_name} · ${item.title}`,
    fields: { "Headline": item.title, "Published summary": item.significance.slice(0, 1_600) } };
}

export function comparePublishedSources(previous: Record<string, SourceBaseline> | undefined,
  current: Record<string, SourceBaseline>): SourceChange[] {
  if (!previous) return [];
  return Object.entries(current).flatMap(([source_id, source]) => {
    if (!Object.hasOwn(previous, source_id)) return [];
    const fields = Object.entries(source.fields).flatMap(([field, value]) => {
      const earlier = previous[source_id].fields;
      if (!Object.hasOwn(earlier, field) || earlier[field] === value) return [];
      return [{ field, previous: earlier[field], current: value }];
    });
    return fields.length ? [{ source_id, title: source.title, fields }] : [];
  });
}

export function sourceChangeEvidence(changes: SourceChange[]): string {
  return changes.flatMap(({ title, fields }) => fields.map(({ field, previous, current }) => {
    const excerpt = (value: string | null) => (value ?? "Undisclosed").replace(/\s+/g, " ").slice(0, 70);
    return `${title.replace(/\s+/g, " ").slice(0, 35)} · ${field}: previously ${excerpt(previous)}; currently ${excerpt(current)}.`;
  })).slice(0, 15).join("\n");
}
