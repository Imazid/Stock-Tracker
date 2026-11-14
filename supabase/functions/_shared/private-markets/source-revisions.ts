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

export function fundingRoundRevision<T extends { round: { share_classes: { name: string; rights: string; source_url?: string }[] } }>(
  deal: T,
): Promise<string> {
  const shareClasses = deal.round.share_classes.toSorted((a, b) => {
    const left = JSON.stringify([a.name, a.rights, a.source_url]);
    const right = JSON.stringify([b.name, b.rights, b.source_url]);
    return left < right ? -1 : left > right ? 1 : 0;
  });
  return sourceRevision({ ...deal, round: { ...deal.round, share_classes: shareClasses } });
}

export async function changedSourceIds<T extends { id: string }>(
  records: T[], saved: Record<string, string> | undefined, revision: (item: T) => Promise<string>,
): Promise<string[]> {
  if (!saved) return [];
  const changes = await Promise.all(records.map(async (item) =>
    Object.hasOwn(saved, item.id) && saved[item.id] !== await revision(item) ? item.id : null));
  return changes.filter((id): id is string => id !== null);
}
