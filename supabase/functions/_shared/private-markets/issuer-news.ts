const origin = "https://www.advancell.com.au";
export const advancellNewsroom = origin + "/category/news/";
export const advancellCompany = "d72c4060-1ae7-4a2f-8f2e-9f4bf1577e02";

export type IssuerNotice = {
  source_url: string;
  title: string;
  significance: string;
  published_at: string;
};

export class IssuerNewsError extends Error {
  constructor(readonly code: string, readonly retryAfterSeconds?: number) {
    super(code);
  }
}

function articleURL(value: unknown): value is string {
  return typeof value === "string" &&
    /^https:\/\/www\.advancell\.com\.au\/news\/[a-z0-9-]{1,240}\/$/.test(value);
}

export function newsroomLinks(html: string): string[] {
  const urls = new Set<string>();
  // The category page marks the article-card links. Its navigation also links
  // to the News landing page and unrelated site sections.
  for (const tag of html.matchAll(/<a\b[^>]{1,1024}>/gi)) {
    const attributes = tag[0];
    if (!/\sclass=["'][^"']*\bentire-meta-link\b[^"']*["']/i.test(attributes)) continue;
    const href = /\shref=["']([^"']+)["']/i.exec(attributes)?.[1];
    if (articleURL(href)) urls.add(href);
  }
  if (!urls.size) throw new IssuerNewsError("NEWSROOM_LAYOUT_CHANGED");
  return [...urls].slice(0, 10);
}

const clean = (value: string) => value.replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/gu, " ").trim();

const topics: [RegExp, string, string][] = [
  [/\b(?:fundraising|financing|funding round|series [a-z]|capital raise)\b/i,
    "Issuer published a financing update", "Read the announcement for the issuer’s account of the financing and disclosed terms."],
  [/\b(?:appoints?|appointment|leadership|board of directors|chief \w+ officer)\b/i,
    "Issuer published a leadership update", "Read the announcement for changes to management or the board."],
  [/\b(?:presents?|results|updated data)\b.*\b(?:clinical|trial|phase|data|study)\b/i,
    "Issuer published a clinical results update", "Read the announcement for the research results reported by the company."],
  [/\b(?:to present|conference|congress|symposium)\b/i,
    "Issuer published a conference update", "Read the announcement for presentation plans or conference participation."],
  [/\b(?:clinical|trial|phase|data|study)\b/i,
    "Issuer published a clinical development update", "Read the announcement for the issuer’s account of its research or clinical programme."],
  [/\b(?:collaboration|partnership|agreement)\b/i,
    "Issuer published a business partnership update", "Read the announcement for the collaboration described by the issuer."],
  [/\b(?:manufactur\w+|facility|headquarters)\b/i,
    "Issuer published an operations update", "Read the announcement for changes to company facilities or operations."],
];

export function newsroomNotice(html: string, url: string, now: Date): IssuerNotice {
  for (const match of html.matchAll(/<script\b[^>]*\btype=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script\s*>/gi)) {
    let graph: unknown;
    try { graph = JSON.parse(match[1])?.["@graph"]; } catch { continue; }
    if (!Array.isArray(graph)) continue;
    for (const article of graph) {
      if (article?.["@type"] !== "Article" || article.mainEntityOfPage?.["@id"] !== url ||
        !Array.isArray(article.articleSection) || !article.articleSection.includes("News") ||
        typeof article.headline !== "string" || typeof article.datePublished !== "string") continue;
      const headline = clean(article.headline);
      if (!headline || headline.length > 360 || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(article.datePublished)) {
        continue;
      }
      const day = article.datePublished.slice(0, 10);
      const calendarDate = new Date(day + "T00:00:00Z");
      if (!Number.isFinite(calendarDate.getTime()) || calendarDate.toISOString().slice(0, 10) !== day) continue;
      const published = Date.parse(article.datePublished);
      if (!Number.isFinite(published) || published > now.getTime()) continue;
      const [, topic, detail] = topics.find(([pattern]) => pattern.test(headline)) ??
        [null, "Issuer published a company update", "Read the announcement for the details released by the company."];
      // Classify the publisher's metadata. Persist our description and link
      // without copying headlines or report text.
      return {
        source_url: url, title: topic, significance: detail, published_at: new Date(published).toISOString(),
      };
    }
  }
  throw new IssuerNewsError("NEWSROOM_METADATA_UNAVAILABLE");
}

export async function getNewsroomPage(url: string, fetcher: typeof fetch, etag?: string | null) {
  const response = await fetcher(url, {
    headers: { accept: "text/html", ...(etag ? { "if-none-match": etag } : {}) },
    redirect: "error",
    signal: AbortSignal.timeout(8_000),
  });
  if (response.status === 304) return { html: null, etag: etag ?? null };
  if (!response.ok || !response.headers.get("content-type")?.toLowerCase().startsWith("text/html")) {
    await response.body?.cancel();
    const retry = response.headers.get("retry-after");
    const delay = retry && /^\d{1,6}$/.test(retry) ? Number(retry) : undefined;
    throw new IssuerNewsError("NEWSROOM_HTTP_" + response.status, delay);
  }
  const body = response.body?.getReader();
  if (!body) throw new IssuerNewsError("NEWSROOM_EMPTY");
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let bytes = 0;
  let html = "";
  try {
    for (;;) {
      const chunk = await body.read();
      if (chunk.done) break;
      bytes += chunk.value.byteLength;
      if (bytes > 512_000) throw new IssuerNewsError("NEWSROOM_TOO_LARGE");
      html += decoder.decode(chunk.value, { stream: true });
    }
    html += decoder.decode();
  } catch (error) {
    await body.cancel().catch(() => {});
    throw error;
  } finally {
    body.releaseLock();
  }
  const validator = response.headers.get("etag");
  return { html, etag: validator && validator.length <= 160 ? validator : null };
}

export async function readIssuerNews(
  etag: string | null,
  fetcher: typeof fetch = fetch,
  now = new Date(),
) {
  const page = await getNewsroomPage(advancellNewsroom, fetcher, etag);
  if (page.html === null) return { etag: page.etag, notices: [], failures: 0 };
  const urls = newsroomLinks(page.html);
  // Re-check the current archive page when it changes. A successful URL only
  // appears once in the database, including if the issuer edits its metadata.
  const results: PromiseSettledResult<IssuerNotice>[] = [];
  for (let offset = 0; offset < urls.length; offset += 3) {
    const group = await Promise.allSettled(urls.slice(offset, offset + 3).map(async (url) => {
      const article = await getNewsroomPage(url, fetcher);
      if (article.html === null) throw new IssuerNewsError("NEWSROOM_ARTICLE_UNAVAILABLE");
      return newsroomNotice(article.html, url, now);
    }));
    results.push(...group);
    const denied = group.find((result) => result.status === "rejected" &&
      result.reason instanceof IssuerNewsError &&
      ["NEWSROOM_HTTP_403", "NEWSROOM_HTTP_429", "NEWSROOM_HTTP_503"].includes(result.reason.code));
    if (denied?.status === "rejected") throw denied.reason;
  }
  const notices = results.flatMap((result) => result.status === "fulfilled" ? [result.value] : []);
  const failures = results.length - notices.length;
  return { etag: failures ? null : page.etag, notices, failures };
}
