import type { AiProxyDeps } from "../_shared/ai/proxy.ts";
import { buildResearch, type Evidence, ResearchError } from "../_shared/private-markets/research.ts";
import { Field, HttpError } from "../_shared/server/http.ts";

type Source = { id: string; title: string; text: string; url: string };
type Filing = { provider?: string; url?: string; publishedAt?: string; license?: string };

function filingURL(evidence: Filing | undefined) {
  if (evidence?.license !== "public_filing" || !evidence.url) return;
  try {
    const url = new URL(evidence.url);
    if (url.protocol === "https:" && !url.username && !url.password) return url.href;
  } catch { /* Ignore malformed source links. */ }
}

export async function answerCompanyQuestion(
  userID: string,
  instrumentID: string,
  body: Record<string, unknown>,
  loadReport: () => Promise<unknown>,
  deps: AiProxyDeps,
) {
  if (body.consent !== true) throw new HttpError(403, "research_consent", "Allow your question and public filing evidence to be sent to the AI provider.");
  const question = Field.string(body.question, "question", 500).trim();
  if (!question) throw new HttpError(400, "research_question", "Enter a question about this company.");
  const report = await loadReport() as {
    instrumentId: string;
    facts: { label: string; end: string; value: number; unit: string; evidence?: Filing; inputs?: Filing[] }[];
    events: { title: string; date: string; evidence?: Filing }[];
    profile?: { name: string; industry?: string; sector?: string; incorporation?: string; evidence?: Filing };
  };
  if (report.instrumentId !== instrumentID) throw new HttpError(503, "research_unavailable", "Company research is temporarily unavailable.");
  const sources: Source[] = [];
  const add = (title: string, lines: string[], filing: Filing | undefined) => {
    const url = filingURL(filing);
    if (!url || sources.length >= 10) return;
    const existing = sources.find((source) => source.url === url);
    if (existing) {
      existing.text += "\n" + lines.join("\n");
      return;
    }
    sources.push({ id: `O${sources.length + 1}`, title: title.slice(0, 180), text: lines.join("\n"), url });
  };
  for (const fact of report.facts.slice(0, 10)) {
    if (fact.inputs?.length || !Number.isFinite(fact.value)) continue;
    add(fact.evidence?.provider ?? "Issuer filing", [
      `${fact.label.slice(0, 100)}: ${fact.value} ${fact.unit.slice(0, 25)} for the period ended ${fact.end.slice(0, 10)}.`,
      `Filed ${fact.evidence?.publishedAt?.slice(0, 10) ?? "on an unavailable date"}.`,
    ], fact.evidence);
  }
  const profile = report.profile;
  if (profile) {
    add(profile.name, [
      `Issuer: ${profile.name.slice(0, 160)}.`,
      ...(profile.industry || profile.sector ? [`Industry or sector: ${(profile.industry || profile.sector)!.slice(0, 150)}.`] : []),
      ...(profile.incorporation ? [`Incorporation: ${profile.incorporation.slice(0, 100)}.`] : []),
    ], profile.evidence);
  }
  for (const event of report.events.slice(0, 8)) {
    add(event.title, [`Issuer filing: ${event.title.slice(0, 150)}. Filed ${event.date.slice(0, 10)}.`], event.evidence);
  }
  if (!sources.length) throw new HttpError(422, "research_no_evidence", "Public filing evidence is unavailable for this listing.");
  try {
    // Keep source URLs and the user's account on this server. The gateway receives
    // the question, listing and selected public evidence only.
    const evidence: Evidence[] = sources.map(({ id, title, text }) => ({ id, title, text }));
    const result = await buildResearch(userID, `Selected listing: ${instrumentID}\nQuestion: ${question}`, evidence, "question", deps);
    const finding = result.findings[0];
    return {
      instrumentId: instrumentID, answer: finding.analysis, missing: finding.missing,
      citations: finding.evidence.map(({ source, quote }, index) => {
        const match = sources.find(({ id }) => id === source)!;
        return { id: `${source}:${index}`, title: match.title, url: match.url, excerpt: quote };
      }),
    };
  } catch (error) {
    if (error instanceof ResearchError) throw new HttpError(error.status, error.code, error.message);
    throw error;
  }
}
