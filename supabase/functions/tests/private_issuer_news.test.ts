import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { advancellNewsroom, newsroomLinks, newsroomNotice, readIssuerNews } from "../_shared/private-markets/issuer-news.ts";

const first = "https://www.advancell.com.au/news/leadership-update/";
const second = "https://www.advancell.com.au/news/research-update/";
const now = new Date("2026-11-14T00:00:00Z");
const listing = (...urls: string[]) => urls.map((url) => `<a class="entire-meta-link" href="${url}">Notice</a>`).join("");
function article(url: string, details: Record<string, unknown> = {}) {
  const metadata = {
    "@type": "Article", mainEntityOfPage: { "@id": url }, articleSection: ["News"],
    headline: "AdvanCell appoints a Chief Financial Officer", datePublished: "2026-11-04T12:59:55+00:00",
    dateModified: "2026-11-11T01:00:00+00:00", description: "Untrusted confidential details",
    ...details,
  };
  return `<script type="application/ld+json">${JSON.stringify({ "@graph": [metadata] })}</script>`;
}
const html = (body: string, etag?: string) => new Response(body, {
  headers: { "content-type": "text/html; charset=utf-8", ...(etag ? { etag } : {}) },
});

Deno.test("issuer newsroom follows only same-origin news links and deduplicates cards", () => {
  assertEquals(newsroomLinks(listing(first, first, "https://www.advancell.com.au/news/", first + "?secret=1",
    "https://example.test/news/forged/", "https://www.advancell.com.au/news/../admin/", second)), [first, second]);
  assertThrows(() => newsroomLinks('<a data-class="entire-meta-link" href="' + first + '">Other</a>'));
});

Deno.test("issuer newsroom verifies canonical article, section and publication timestamp", () => {
  const notice = newsroomNotice(article(first), first, now);
  assertEquals(notice, {
    source_url: first, title: "Issuer published a leadership update",
    significance: "Read the announcement for changes to management or the board.",
    published_at: "2026-11-04T12:59:55.000Z",
  });
  assertThrows(() => newsroomNotice(article(second), first, now));
  assertThrows(() => newsroomNotice(article(first, { articleSection: ["Presentations/Publications"] }), first, now));
  assertThrows(() => newsroomNotice(article(first, { datePublished: "2026-11-16T00:00:00Z" }), first, now));
  assertThrows(() => newsroomNotice(article(first, { datePublished: "today" }), first, now));
  assertThrows(() => newsroomNotice(article(first, { datePublished: "2026-02-30T00:00:00Z" }), first, now));
});

Deno.test("issuer refresh uses ETag and does not rediscover articles on an unchanged page", async () => {
  const calls: string[] = [];
  const response = await readIssuerNews('"a"', (url, init) => {
    calls.push(String(url));
    assertEquals(init?.redirect, "error");
    assertEquals(new Headers(init?.headers).get("if-none-match"), '"a"');
    return Promise.resolve(new Response(null, { status: 304 }));
  }, now);
  assertEquals(calls, [advancellNewsroom]);
  assertEquals(response, { etag: '"a"', notices: [], failures: 0 });
});

Deno.test("partial issuer results preserve usable facts and force a later recheck", async () => {
  const response = await readIssuerNews('"a"', (url) => Promise.resolve(
    url === advancellNewsroom ? html(listing(first, second), '"b"') :
      url === first ? html(article(first)) : html("Publisher changed metadata"),
  ), now);
  assertEquals(response.etag, null);
  assertEquals(response.failures, 1);
  assertEquals(response.notices.map((notice) => notice.source_url), [first]);
});

Deno.test("issuer refresh respects denial or throttling and rejects oversized pages", async () => {
  await assertRejects(() => readIssuerNews(null, (url) => Promise.resolve(
    url === advancellNewsroom ? html(listing(first)) : new Response(null, { status: 429, headers: { "retry-after": "7200" } }),
  ), now), Error, "NEWSROOM_HTTP_429");
  await assertRejects(() => readIssuerNews(null, () => Promise.resolve(html("a".repeat(512_001))), now), Error, "NEWSROOM_TOO_LARGE");
});
