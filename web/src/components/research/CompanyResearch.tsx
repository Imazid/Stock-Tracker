"use client";

import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { ArrowUpRight, ChevronLeft, ChevronRight, Download } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";
import { CompanyAlerts } from "./CompanyAlerts";
import { AssistantChat } from "@/components/assistant/AssistantChat";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Input } from "@/components/ui/Field";
import { useSearch } from "@/hooks/market";
import { getJSON } from "@/lib/api";
import { money } from "@/lib/format";
import { cn } from "@/lib/cn";
import { dcf } from "@/lib/research-financials";
import { RESEARCH_SECTIONS, type CompanyReport, type DatasetCoverage, type Evidence, type FilingPassages, type FinancialFact, type ResearchResponse, type ResearchSection } from "@/lib/research-types";

const LABELS = {
  overview: "Overview", financials: "Financials", valuation: "Valuation", earnings: "Earnings",
  ownership: "Ownership", events: "News & Filings", options: "Options", peers: "Competitors", ai: "AI Research",
};
type Tab = ResearchSection | "ai";
const STATUS = {
  available: "Available", partial: "Partial", historical: "Historical", delayed: "Delayed",
  unavailable: "Unavailable", restricted: "Entitlement required", not_applicable: "Not applicable",
};
const selectClass = "rounded-lg border border-border bg-surface-2 px-2.5 py-2 text-sm text-text";
const decimal = new Intl.NumberFormat("en-AU", { maximumFractionDigits: 6 });
const short = new Intl.NumberFormat("en-AU", { notation: "compact", maximumFractionDigits: 2 });

function Source({ evidence, children }: { evidence: Evidence; children?: ReactNode }) {
  return <a href={evidence.url} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-primary-fg hover:underline">
    {children ?? evidence.provider}<ArrowUpRight aria-hidden className="h-3 w-3 shrink-0" />
  </a>;
}

function Coverage({ rows }: { rows: DatasetCoverage[] }) {
  if (!rows.length) return null;
  return (
    <details className="rounded-xl border border-border bg-surface px-4 py-3 text-sm" open={rows.every((r) => ["unavailable", "restricted", "not_applicable", "historical"].includes(r.status))}>
      <summary className="cursor-pointer font-medium">Data coverage</summary>
      <ul className="mt-3 grid gap-3 sm:grid-cols-2">
        {rows.map((row) => <li key={row.dataset} className="space-y-1">
          <div className="flex flex-wrap items-center gap-2"><span>{row.dataset}</span><Badge tone={row.status === "available" ? "up" : "neutral"}>{STATUS[row.status]}</Badge></div>
          <p className="text-xs leading-relaxed text-text-2">{row.detail}{row.refreshedAt ? ` Retrieved ${new Date(row.refreshedAt).toLocaleString("en-AU")}.` : ""}</p>
        </li>)}
      </ul>
    </details>
  );
}

function exportFacts(facts: FinancialFact[], symbol: string) {
  const escape = (value: string | number | undefined) => {
    const raw = String(value ?? "");
    const text = typeof value === "string" && /^[\t\r\n=+\-@]/.test(raw) ? "'" + raw : raw;
    return '"' + text.replaceAll('"', '""') + '"';
  };
  const lines = [
    ["Concept", "Metric", "Value", "Unit", "Start", "End", "Filed", "Provider", "Source", "Retrieved", "Formula", "Inputs"],
    ...facts.map((f) => [f.concept, f.label, f.value, f.unit, f.start, f.end, f.evidence.publishedAt, f.evidence.provider, f.evidence.url, f.evidence.retrievedAt, f.formula, f.inputs?.map((i) => i.url).join(" | ")]),
  ];
  const url = URL.createObjectURL(new Blob([lines.map((line) => line.map(escape).join(",")).join("\r\n")], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = `${symbol}-financials.csv`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function Table({ headings, rows, label }: { headings: string[]; rows: { id: string; cells: ReactNode[]; order: (number | string | undefined)[] }[]; label: string }) {
  const [sort, setSort] = useState<{ column: number; descending: boolean }>();
  const sorted = useMemo(() => {
    if (!sort) return rows;
    return [...rows].sort((a, b) => {
      const x = a.order[sort.column], y = b.order[sort.column];
      if (x == null) return y == null ? 0 : 1;
      if (y == null) return -1;
      const order = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y));
      return sort.descending ? -order : order;
    });
  }, [rows, sort]);
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-sm" aria-label={label}>
        <thead className="border-b border-border bg-surface-2 text-xs text-text-2">
          <tr>{headings.map((heading, column) => <th key={heading} scope="col" aria-sort={sort?.column === column ? sort.descending ? "descending" : "ascending" : undefined}>
            <button className="w-full whitespace-nowrap px-4 py-2.5 text-left hover:text-text" onClick={() => setSort({ column, descending: sort?.column === column && !sort.descending })}>
              {heading}{sort?.column === column ? sort.descending ? " ↓" : " ↑" : ""}
            </button>
          </th>)}</tr>
        </thead>
        <tbody className="divide-y divide-border">
          {sorted.map((row) => <tr key={row.id}>{row.cells.map((cell, i) => <td key={i} className="px-4 py-2.5 align-top tabular">{cell ?? "—"}</td>)}</tr>)}
        </tbody>
      </table>
    </div>
  );
}

function Facts({ facts }: { facts: FinancialFact[] }) {
  return <Table label="Financial facts" headings={["Metric", "Value", "Unit", "Period end", "Filed", "Source"]} rows={facts.map((f) => ({
    id: `${f.concept}:${f.unit}:${f.start}:${f.end}:${f.evidence.url}:${f.value}`,
    order: [f.label, f.value, f.unit, f.end, f.evidence.publishedAt, f.evidence.provider],
    cells: [
      <span key="metric" title={f.concept}>{f.label}</span>,
      <span key="value" className="whitespace-nowrap" title={decimal.format(f.value)}>{decimal.format(f.value)}</span>,
      f.unit, <span key="end" className="whitespace-nowrap">{f.end}</span>, f.evidence.publishedAt?.slice(0, 10),
      f.inputs?.length ? <details key="source"><summary className="cursor-pointer text-primary-fg">Inputs</summary>{f.formula ? <p className="my-1 text-xs text-text-2">{f.formula}</p> : null}<ul className="space-y-1">
        {f.inputs.map((input, i) => <li key={i}><Source evidence={input}>Filing {i + 1}</Source></li>)}</ul></details>
        : <Source key="source" evidence={f.evidence} />,
    ],
  }))} />;
}

const ASSUMPTIONS = [
  ["cashFlow", "Annual free cash flow"], ["growth", "5-year growth (%)"], ["discount", "Discount rate (%)"],
  ["terminal", "Terminal growth (%)"], ["netDebt", "Net debt"], ["shares", "Diluted shares outstanding"],
] as const;

function Scenario() {
  const [inputs, setInputs] = useState({ cashFlow: "", growth: "", discount: "", terminal: "", netDebt: "", shares: "" });
  const complete = Object.values(inputs).every((value) => value.trim() !== "");
  const assumptions = { cashFlow: Number(inputs.cashFlow), growth: Number(inputs.growth) / 100, discount: Number(inputs.discount) / 100,
    terminal: Number(inputs.terminal) / 100, netDebt: Number(inputs.netDebt), shares: Number(inputs.shares) };
  const value = complete ? dcf(assumptions) : undefined;
  return <Card>
    <CardHeader title="Discounted cash flow" subtitle="Five-year scenario. Enter cash flow and net debt in the same currency, with absolute share counts." />
    <div className="space-y-4 border-t border-border p-4">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {ASSUMPTIONS.map(([key, label]) => <label key={key} className="space-y-1 text-xs text-text-2">
          <span>{label}</span><Input type="number" step="any" value={inputs[key]} onChange={(e) => setInputs((current) => ({ ...current, [key]: e.target.value }))} />
        </label>)}
      </div>
      {complete && value === undefined ? <p role="status" className="text-sm text-warn">Cash flow and shares must be positive. Discount rate must be positive and above terminal growth.</p> : null}
      {value !== undefined ? <>
        <p className="text-sm text-text-2">Scenario equity value per share <strong className="ml-2 text-xl text-text">{decimal.format(value)}</strong></p>
        <Table label="DCF sensitivity per share" headings={["Discount rate", ...[-0.005, 0, 0.005].map((shift) => `${decimal.format((assumptions.terminal + shift) * 100)}% terminal`)]}
          rows={[-0.01, 0, 0.01].map((shift) => {
            const discount = assumptions.discount + shift;
            const values = [-0.005, 0, 0.005].map((terminalShift) => dcf({ ...assumptions, discount, terminal: assumptions.terminal + terminalShift }));
            return { id: String(shift), order: [discount, ...values], cells: [`${decimal.format(discount * 100)}%`, ...values.map((n) => n === undefined ? "—" : decimal.format(n))] };
          })} />
      </> : null}
      <details className="text-xs text-text-2"><summary className="cursor-pointer">Calculation</summary>
        <p className="mt-2">Discount each projected annual free cash flow and the perpetual terminal value to today. Subtract net debt, then divide by diluted shares.</p>
      </details>
    </div>
  </Card>;
}

export function useCompanyProfile(id: string, enabled: boolean) {
  return useQuery({
    queryKey: ["company-research", id, "overview"], enabled, staleTime: 5 * 60_000, retry: false,
    queryFn: () => getJSON<ResearchResponse>(`/api/markets/instruments/${encodeURIComponent(id)}/research?section=overview`),
  });
}

function PeerComparison({ id }: { id: string }) {
  const [input, setInput] = useState("");
  const [peers, setPeers] = useState<{ id: string; symbol: string }[]>([]);
  const lookup = useSearch(input);
  const selected = [id, ...peers.map((peer) => peer.id)];
  const data = useQuery({
    queryKey: ["research-comparison", ...selected], enabled: peers.length > 0, retry: false, staleTime: 120_000,
    queryFn: () => Promise.all(selected.map(async (listing) => {
      try {
        const result = await getJSON<ResearchResponse>(`/api/markets/instruments/${encodeURIComponent(listing)}/research?section=valuation`);
        return { listing, facts: result.facts ?? [] };
      } catch {
        return { listing, facts: [] as FinancialFact[] };
      }
    })),
  });
  const metrics = [...new Set((data.data ?? []).flatMap((row) => row.facts.map((fact) => fact.label)))];
  return <Card>
    <CardHeader title="Compare companies" subtitle="Each observation keeps its own reporting period and currency." />
    <div className="space-y-3 border-t border-border p-4">
      <label className="grid gap-1 text-xs text-text-2">Find a company to compare
        <Input type="search" value={input} maxLength={64} onChange={(event) => setInput(event.target.value)} disabled={peers.length >= 3} />
      </label>
      {input.trim() ? <div className="flex flex-wrap gap-2">
        {lookup.data?.results.filter((item) => item.venue !== "crypto" && !selected.includes(item.id)).slice(0, 5).map((item) => <Button key={item.id} size="sm" variant="secondary" onClick={() => {
          setPeers((current) => [...current, { id: item.id, symbol: item.symbol }]);
          setInput("");
        }}>{item.symbol} · {item.exchangeLabel}</Button>)}
      </div> : null}
      {peers.length ? <div className="flex flex-wrap gap-2">{peers.map((peer) => <Button key={peer.id} size="sm" variant="ghost" onClick={() => setPeers((current) => current.filter((item) => item.id !== peer.id))}>Remove {peer.symbol}</Button>)}</div> : null}
      {data.isFetching ? <p className="text-xs text-text-2" role="status">Loading comparable filing data…</p> : null}
      {data.data && !metrics.length ? <p className="text-xs text-text-2">No comparable filing data was returned.</p> : null}
    </div>
    {data.data && metrics.length ? <Table label="Company comparison" headings={["Metric", ...data.data.map((row) => row.listing.split(":")[1] + " · " + row.listing.split(":")[0].toUpperCase())]} rows={metrics.map((metric) => {
      const values = data.data!.map((row) => row.facts.find((fact) => fact.label === metric));
      return { id: metric, order: [metric, ...values.map((fact) => fact?.value)], cells: [metric, ...values.map((fact) => fact ? <div key={fact.evidence.url} className="whitespace-nowrap">
        <p>{decimal.format(fact.value)} {fact.unit}</p><p className="text-xs text-text-2">{fact.end} · <Source evidence={fact.evidence} /></p>
      </div> : undefined)] };
    })} /> : null}
  </Card>;
}

function FilingSearch({ id, accession, archive }: { id: string; accession: string; archive: string }) {
  const [query, setQuery] = useState("");
  const [submitted, setSubmitted] = useState("");
  const params = new URLSearchParams({ accession, q: submitted });
  if (archive) params.set("archive", archive);
  const search = useQuery({
    queryKey: ["filing-text", id, accession, archive, submitted], enabled: Boolean(submitted), retry: false, staleTime: 10 * 60_000,
    queryFn: () => getJSON<FilingPassages>(`/api/markets/instruments/${encodeURIComponent(id)}/research/filing?${params}`),
  });
  return <details className="mt-2 text-xs">
    <summary className="cursor-pointer text-text-2">Search filing text</summary>
    <form className="mt-2 flex min-w-56 gap-2" onSubmit={(event) => { event.preventDefault(); setSubmitted(query.trim()); }}>
      <Input type="search" aria-label="Keywords in filing" placeholder="Keywords in filing" value={query} maxLength={100} onChange={(event) => setQuery(event.target.value)} />
      <Button size="sm" variant="secondary" type="submit" disabled={!query.trim()}>Find</Button>
    </form>
    {search.isFetching ? <p className="mt-2 text-text-2" role="status">Searching the original filing…</p> : null}
    {search.isError ? <p className="mt-2 text-warn" role="status">{search.error.message}</p> : null}
    {search.data ? <ul className="mt-2 max-w-lg space-y-2">
      {search.data.passages.length ? search.data.passages.map((passage) => <li key={passage.location} className="rounded border border-border bg-surface-2 p-2 leading-relaxed">{passage.text}</li>)
        : <li className="text-text-2">No matching passages.</li>}
    </ul> : null}
  </details>;
}

function Section({ id, symbol, section, overview }: { id: string; symbol: string; section: ResearchSection; overview?: ResearchResponse }) {
  const [period, setPeriod] = useState("annual");
  const [statement, setStatement] = useState("");
  const [query, setQuery] = useState("");
  const [submitted, setSubmitted] = useState("");
  const [asOf, setAsOf] = useState("");
  const [versions, setVersions] = useState(false);
  const [archive, setArchive] = useState("");
  const [expiry, setExpiry] = useState("");
  const [page, setPage] = useState(0);
  const [chain, setChain] = useState<string[]>([]);
  const params = new URLSearchParams({ section, period, page: String(page), q: submitted, versions: String(versions) });
  if (asOf) params.set("asOf", asOf);
  if (statement) params.set("statement", statement);
  if (archive) params.set("archive", archive);
  if (expiry) params.set("expiry", expiry);
  if (chain.length) params.set("cursor", chain.at(-1)!);
  const response = useQuery({
    queryKey: ["company-research", id, params.toString()], enabled: section !== "overview",
    queryFn: () => getJSON<ResearchResponse>(`/api/markets/instruments/${encodeURIComponent(id)}/research?${params}`),
    retry: false, staleTime: section === "options" ? 15_000 : 120_000,
  });
  const data = section === "overview" ? overview : response.data;
  const searchable = ["financials", "events", "ownership", "earnings", "options", "peers"].includes(section);
  const remoteSearch = ["financials", "events", "ownership"].includes(section);
  const facts = data?.facts ?? [];
  const events = data?.events ?? [];
  const records = (data?.records ?? []).filter((r) => !submitted || `${r.label} ${r.date ?? ""} ${Object.values(r.values).join(" ")}`.toLowerCase().includes(submitted.toLowerCase()));
  const keys = [...new Set(records.flatMap((r) => Object.keys(r.values)))];
  const profile = data?.profile;
  const fields = profile ? [
    ["Industry", profile.industry], ["Sector", profile.sector], ["Headquarters", profile.headquarters],
    ["Incorporated in", profile.incorporation], ["Chief executive", profile.ceo], ["Employees", profile.employees?.toLocaleString("en-AU")],
    ["IPO date", profile.ipoDate], ["CIK", profile.cik], ["ISIN", profile.isin], ["CUSIP", profile.cusip],
  ].filter(([, value]) => value !== undefined) : [];

  return <div className="grid gap-4">
    <Card className="min-w-0">
      <CardHeader title={section === "overview" ? "Company profile" : LABELS[section]}
        subtitle={section === "financials" ? "Reported observations and original filings" : section === "valuation" ? "Calculated from matching annual SEC filing periods" : undefined}
        actions={data?.exportAllowed ? <Button size="sm" variant="secondary" onClick={() => exportFacts(facts, symbol)}><Download aria-hidden className="h-4 w-4" />Export page</Button> : undefined} />
      {section !== "overview" ? <div className="flex flex-wrap items-end gap-3 border-t border-border p-4">
        {section === "financials" ? <>
          <label className="grid gap-1 text-xs text-text-2">Period<select className={selectClass} value={period} onChange={(e) => { setPeriod(e.target.value); setPage(0); }}>
            <option value="annual">Annual</option><option value="quarter">Quarterly</option><option value="ttm">Trailing 12 months</option><option value="all">All observations</option>
          </select></label>
          <label className="grid gap-1 text-xs text-text-2">Statement<select className={selectClass} value={statement} onChange={(e) => { setStatement(e.target.value); setPage(0); }}>
            <option value="">All line items</option><option value="income">Income statement</option><option value="balance">Balance sheet</option><option value="cash">Cash flow</option><option value="other">Additional XBRL facts</option>
          </select></label>
          <label className="flex h-9 items-center gap-2 text-xs text-text-2"><input type="checkbox" checked={versions} disabled={period === "ttm"} onChange={(e) => { setVersions(e.target.checked); setPage(0); }} />Include prior filings</label>
        </> : null}
        {["financials", "valuation", "events", "ownership"].includes(section) ? <label className="grid gap-1 text-xs text-text-2">
          Published through (UTC)<Input type="date" value={asOf} onChange={(e) => { setAsOf(e.target.value); setPage(0); }} />
        </label> : null}
        {(section === "events" || section === "ownership") && (data?.archiveCount || archive) ? <label className="grid gap-1 text-xs text-text-2">Filing history
          <select className={selectClass} value={archive} onChange={(e) => { setArchive(e.target.value); setPage(0); }}>
            <option value="">Recent</option>{Array.from({ length: data?.archiveCount ?? Number(archive) + 1 }, (_, i) => <option key={i} value={i}>Recent + archive {i + 1}</option>)}
          </select></label> : null}
        {section === "options" ? <label className="grid gap-1 text-xs text-text-2">Expiration<Input type="date" value={expiry} onChange={(e) => { setExpiry(e.target.value); setChain([]); }} /></label> : null}
        {searchable ? <form className="flex min-w-0 items-end gap-2" onSubmit={(e) => { e.preventDefault(); setSubmitted(query.trim()); setPage(0); }}>
          <label className="grid min-w-0 gap-1 text-xs text-text-2">{remoteSearch ? "Find in dataset" : "Find on this page"}<Input type="search" value={query} maxLength={100} onChange={(e) => setQuery(e.target.value)} /></label>
          <Button size="sm" variant="secondary" type="submit">Filter</Button>
        </form> : null}
      </div> : null}
      {!data ? response.isError
        ? <EmptyState title="Research data could not be loaded" actions={<Button size="sm" onClick={() => response.refetch()}>Try again</Button>} />
        : <div className="skeleton m-4 h-28" aria-label="Loading research" />
        : <>
          {profile ? <div className="space-y-4 border-t border-border p-4">
            {profile.description ? <p className="max-w-3xl text-sm leading-relaxed text-text-2">{profile.description}</p> : null}
            <dl className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              {fields.map(([label, value]) => <div key={label}><dt className="text-xs text-text-3">{label}</dt><dd className="text-sm">{value}</dd></div>)}
            </dl>
            <p className="flex flex-wrap gap-4 text-xs"><Source evidence={profile.evidence} />{profile.website ? <a href={profile.website} target="_blank" rel="noreferrer" className="text-primary-fg hover:underline">Company website ↗</a> : null}</p>
          </div> : null}
          {facts.length ? <Facts facts={facts} /> : null}
          {events.length ? <Table label="Company filings and events" headings={["Filed / published", "Form", "Event", "Report date", "Source"]} rows={events.map((e) => ({
            id: e.id, order: [e.date, e.category, e.title, e.reportDate, e.evidence.provider],
            cells: [e.date.slice(0, 10), e.category, <div key="title"><Source evidence={e.evidence}>{e.title}</Source>
              {e.evidence.provider === "SEC EDGAR" && /^(10-K|10-Q|8-K|20-F|40-F|6-K)(\/A)?$/.test(e.category)
                ? <FilingSearch id={id} accession={e.id} archive={archive} /> : null}</div>, e.reportDate || undefined, e.publisher ?? e.evidence.provider],
          }))} /> : null}
          {records.length ? <Table label={LABELS[section]} headings={["Name", section === "options" ? "Expiry" : "Date", ...keys, "Source"]} rows={records.map((r) => ({
            id: r.id, order: [r.label, r.date, ...keys.map((key) => r.values[key]), r.evidence.provider],
            cells: [section === "peers" && id.startsWith("us:") ? <Link key="peer" className="text-primary-fg hover:underline" href={`/markets/${encodeURIComponent(`us:${r.label}`)}`}>{r.label}</Link> : r.label, r.date?.slice(0, 10), ...keys.map((key) => typeof r.values[key] === "number" ? <span key={key} title={decimal.format(r.values[key] as number)}>{short.format(r.values[key] as number)}</span> : r.values[key]),
              <span key="source"><Source evidence={r.evidence} />{r.evidence.publishedAt ? <span className="block text-xs text-text-3">{r.evidence.publishedAt}</span> : null}</span>],
          }))} /> : null}
          {data.links?.length ? <div className="border-t border-border p-4 text-sm">{data.links.map((link) => <a key={link.url} href={link.url} target="_blank" rel="noreferrer" className="text-primary-fg hover:underline">{link.label} ↗</a>)}</div> : null}
          {!profile && !facts.length && !events.length && !records.length && !data.links?.length ? <EmptyState title="No records for this view" /> : null}
          {((data.total ?? 0) > 25 || page > 0 || data.next || chain.length > 0) ? <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border px-4 py-3 text-xs text-text-2">
            <span>{data.total !== undefined ? `${data.total.toLocaleString("en-AU")} records · Page ${page + 1}` : `Page ${chain.length + 1}`}</span>
            <div className="flex gap-2">
              <Button size="sm" variant="secondary" aria-label="Previous page" disabled={!page && !chain.length} onClick={() => section === "options" ? setChain((c) => c.slice(0, -1)) : setPage((p) => p - 1)}><ChevronLeft className="h-4 w-4" /></Button>
              <Button size="sm" variant="secondary" aria-label="Next page" disabled={section === "options" ? !data.next : (page + 1) * 25 >= (data.total ?? 0)} onClick={() => section === "options" && data.next ? setChain((c) => [...c, data.next!]) : setPage((p) => p + 1)}><ChevronRight className="h-4 w-4" /></Button>
            </div>
          </div> : null}
        </>}
    </Card>
    {section === "valuation" ? <Scenario /> : null}
    {section === "peers" ? <PeerComparison id={id} /> : null}
    {data ? <Coverage rows={data.coverage} /> : null}
  </div>;
}

function ResearchBrief({ id }: { id: string }) {
  const report = useQuery({
    queryKey: ["research-report", id], staleTime: 60_000, retry: false,
    queryFn: () => getJSON<CompanyReport>(`/api/markets/instruments/${encodeURIComponent(id)}/research/report`),
  });
  const data = report.data;
  return <Card className="min-w-0">
    <CardHeader title="Company research report" subtitle={data ? `Evidence collected through ${data.asOf} UTC` : undefined} />
    {!data ? report.isError ? <EmptyState title="The report could not be loaded" actions={<Button size="sm" onClick={() => report.refetch()}>Try again</Button>} />
      : <div role="status" className="p-4 text-sm text-text-2">Collecting company and market evidence…</div>
      : <div className="space-y-4 border-t border-border p-4 text-sm">
        {data.profile ? <p><strong>{data.profile.name}</strong> {data.profile.industry ? `· ${data.profile.industry}` : ""} · <Source evidence={data.profile.evidence} /></p> : null}
        {data.quote ? <p>{money(data.quote.last, data.quote.currency)} · {data.quote.source} · {data.quote.status.replaceAll("_", " ")}{data.quote.stale ? " · stale" : ""} · {new Date(data.quote.observedAt).toLocaleString("en-AU")}</p> : null}
        {data.history ? <p>{decimal.format(data.history.changePct)}% over the available 1-year window · {data.history.source} · {data.history.first.slice(0, 10)} to {data.history.last.slice(0, 10)} · {data.history.adjustment}</p> : null}
        {data.facts.length ? <details open><summary className="cursor-pointer font-medium">Reported finances and calculated ratios</summary><Facts facts={data.facts} /></details> : null}
        {([["Recent filings and news", data.events], ["Ownership disclosures", data.ownership]] as const).map(([label, entries]) => {
          if (!entries.length) return null;
          return <details key={String(label)}><summary className="cursor-pointer font-medium">{String(label)}</summary><ul className="mt-2 space-y-1">{entries.map((e) =>
            <li key={e.id}>{e.date.slice(0, 10)} · <Source evidence={e.evidence}>{e.category} · {e.title}</Source></li>)}</ul></details>;
        })}
        {([["Provider valuation multiples", data.multiples], ["Earnings and estimates", data.earnings], ["Provider peers", data.peers]] as const).map(([label, entries]) => {
          if (!entries.length) return null;
          return <details key={String(label)}><summary className="cursor-pointer font-medium">{String(label)}</summary><ul className="mt-2 space-y-2">{entries.map((r) =>
            <li key={r.id}>{r.date ? `${r.date} · ` : ""}{r.label} · {Object.entries(r.values).map(([key, val]) => `${key} ${typeof val === "number" ? decimal.format(val) : val}`).join(" · ")} · <Source evidence={r.evidence} /></li>)}</ul></details>;
        })}
        {data.links?.map((link) => <p key={link.url}><a href={link.url} target="_blank" rel="noreferrer" className="text-primary-fg hover:underline">{link.label} ↗</a></p>)}
        <Coverage rows={data.coverage} />
      </div>}
  </Card>;
}

export function CompanyResearch({ id, symbol, overview, overviewError, retryOverview }: { id: string; symbol: string; overview?: ResearchResponse; overviewError: boolean; retryOverview: () => void }) {
  const [tab, setTab] = useState<ResearchSection>("overview");
  const [assistantOpen, setAssistantOpen] = useState(false);
  const [reportOpen, setReportOpen] = useState(false);
  const [reportRequest, setReportRequest] = useState(0);
  const switchTab = (item: Tab) => {
    if (item === "ai") setAssistantOpen((open) => !open);
    else setTab(item);
  };
  return <section aria-label="Company intelligence" className="mt-6 min-w-0 space-y-4">
    <div className="flex flex-wrap items-center justify-between gap-2">
      <h2 className="text-lg font-semibold tracking-tight">Company intelligence</h2>
      <Button size="sm" variant="primary" onClick={() => {
        setReportOpen(!reportOpen);
        if (!reportOpen) {
          setAssistantOpen(true);
          if (reportRequest === 0) setReportRequest(1);
        }
      }} aria-expanded={reportOpen}>Research Everything</Button>
    </div>
    <nav aria-label="Company research sections" className="flex flex-wrap gap-1 rounded-xl border border-border bg-surface p-1.5">
      {([...RESEARCH_SECTIONS, "ai"] as Tab[]).map((item) => <button key={item} type="button" aria-pressed={item === "ai" ? assistantOpen : tab === item}
        onClick={() => switchTab(item)} className={cn("rounded-md px-3 py-2 text-xs font-medium", (item === "ai" ? assistantOpen : tab === item) ? "bg-primary-soft text-text" : "text-text-2 hover:bg-surface-2 hover:text-text")}>{LABELS[item]}</button>)}
    </nav>
    <CompanyAlerts id={id} />
    <div className={cn("grid gap-4", assistantOpen && "xl:grid-cols-[minmax(0,1fr)_minmax(19rem,24rem)]")}>
      <div className="min-w-0 space-y-4">
        {reportOpen ? <ResearchBrief id={id} /> : null}
        {tab === "overview" && overviewError ? <Card><EmptyState title="Company profile could not be loaded" actions={<Button size="sm" onClick={retryOverview}>Try again</Button>} /></Card>
          : <Section key={tab} id={id} symbol={symbol} section={tab} overview={overview} />}
      </div>
      <aside aria-label="Company research assistant" hidden={!assistantOpen} className="min-w-0">
        {assistantOpen ? <div className="flex items-center justify-between gap-2 px-1 pb-2"><h3 className="font-medium">{symbol} research</h3>
          <Button size="sm" variant="ghost" onClick={() => setAssistantOpen(false)}>Collapse</Button></div> : null}
        <div className="flex h-[34rem] min-h-0">
          <AssistantChat company={{ instrumentId: id, symbol, section: tab }} reportRequest={reportRequest} />
        </div>
      </aside>
    </div>
  </section>;
}
