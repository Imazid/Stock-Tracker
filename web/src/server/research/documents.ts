import { parse, type DefaultTreeAdapterMap } from "parse5";
import type { FilingPassages } from "@/lib/research-types";
import type { Instrument } from "@engine/market.ts";
import { cached } from "@/server/market/cache";
import { ResearchInputError } from "./service";
import { findSecListing, SEC, secArchive, secDirectory, secSubmissions } from "./sec";
import { providerResponse } from "./upstream";

type Node = DefaultTreeAdapterMap["node"];
const ALLOWED_FORM = /^(10-K|10-Q|8-K|20-F|40-F|6-K)(\/A)?$/;
const SEC_ARCHIVE = /^https:\/\/www\.sec\.gov\/Archives\/edgar\/data\/[0-9]+\/[0-9]{18}\/[\w.-]+\.html?$/i;
const SKIP = new Set(["head", "script", "style", "noscript", "ix:header", "ix:hidden"]);
const BREAK = new Set(["body", "div", "p", "br", "h1", "h2", "h3", "h4", "li", "tr", "td", "th"]);

function paragraphs(html: string): string[] {
  const parts: string[] = [];
  const queue: (Node | null)[] = [parse(html)];
  while (queue.length) {
    const node = queue.pop();
    if (!node) { parts.push("\n"); continue; }
    if (node.nodeName === "#text" && "value" in node) { parts.push(node.value); continue; }
    if (SKIP.has(node.nodeName) || "attrs" in node && node.attrs.some(({ name, value }) => name === "style" && /display\s*:\s*none/i.test(value))) continue;
    if ("childNodes" in node) {
      if (BREAK.has(node.nodeName)) { parts.push("\n"); queue.push(null); }
      for (let index = node.childNodes.length - 1; index >= 0; index--) queue.push(node.childNodes[index]);
    }
  }
  return parts.join("").split(/\n/).map((part) => part.replace(/\s+/g, " ").trim()).filter((part) => part.length >= 30);
}

async function documentText(url: string): Promise<{ lines: string[]; retrievedAt: string }> {
  if (!SEC_ARCHIVE.test(url) || url.endsWith("-index.htm")) throw new ResearchInputError("This filing has no supported SEC primary HTML document.");
  return cached(`research:document:${url}`, 86_400_000, async () => {
    const response = await providerResponse(new URL(url), SEC, { "User-Agent": process.env.RESEARCH_SEC_USER_AGENT!.trim(), Accept: "text/html" }, 200);
    const reader = response.body?.getReader();
    if (!reader) throw new Error("The filing body was empty.");
    const decoder = new TextDecoder();
    let html = "";
    let bytes = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > 5_000_000) throw new ResearchInputError("This filing exceeds the interactive document size limit. Open the original filing.");
        html += decoder.decode(value, { stream: true });
      }
      html += decoder.decode();
    } finally {
      await reader.cancel().catch(() => {});
    }
    return { lines: paragraphs(html), retrievedAt: new Date().toISOString() };
  });
}

export async function filingPassages(instrument: Instrument, accession: string, query: string, archive?: number): Promise<FilingPassages> {
  if (instrument.venue !== "us" || !/^\d{10}-\d{2}-\d{6}$/.test(accession)) throw new ResearchInputError("Choose a SEC filing accession from this listing.");
  const listing = findSecListing(await secDirectory(), instrument.symbol);
  if (!listing) throw new ResearchInputError("A SEC issuer mapping is unavailable for this listing.");
  const submissions = await secSubmissions(listing);
  const archived = archive !== undefined && submissions.archives[archive] ? await secArchive(listing.cik, submissions.archives[archive]) : [];
  const event = [...submissions.events, ...archived].find((row) => row.id === accession && ALLOWED_FORM.test(row.category));
  if (!event) throw new ResearchInputError("This accession could not be resolved to a supported report for this issuer.");
  const { lines, retrievedAt } = await documentText(event.evidence.url);
  const stop = new Set(["the", "and", "for", "with", "that", "this", "from", "what", "where", "about"]);
  const words = [...new Set(query.toLowerCase().match(/[a-z0-9][a-z0-9-]{2,}/g) ?? [])].filter((word) => !stop.has(word)).slice(0, 12);
  const ranked = lines.map((line, i) => {
    const text = line.toLowerCase();
    return { i, score: words.filter((word) => text.includes(word)).length };
  }).filter((match) => match.score > 0).sort((a, b) => b.score - a.score || a.i - b.i);
  const selected: number[] = [];
  for (const { i } of ranked) {
    if (selected.every((other) => Math.abs(other - i) > 2)) selected.push(i);
    if (selected.length === 8) break;
  }
  const passages = selected.map((i) => {
    const line = lines[i];
    const match = words.map((word) => line.toLowerCase().indexOf(word)).filter((index) => index >= 0);
    const from = Math.max(0, Math.min(...match) - 160);
    return { location: i + 1, text: line.length > 950 ? line.slice(from, from + 1000) : lines.slice(Math.max(0, i - 1), i + 2).join(" ").slice(0, 1100) };
  });
  return { passages, evidence: { ...event.evidence, retrievedAt }, form: event.category };
}
