"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { Segmented } from "@/components/ui/Segmented";
import { CompareRounds, SourceLink } from "./catalog";
import { dateLabel, privateMarkets, type Finding, type PrivateDeal, type Report, type ResearchRun, type SavedReport } from "./private-data";

type Mode = "question" | "committee";
const reportKey = (owner: string) => ["private-markets", owner, "reports"];

function ResearchFinding({ finding, sources }: { finding: Finding; sources: Report["sources"] }) {
  const scenarios = [
    { label: "Bull", text: finding.bull }, { label: "Base", text: finding.base }, { label: "Bear", text: finding.bear },
  ];
  return (
    <section className="space-y-3 border-t border-border px-4 py-4 text-sm leading-relaxed text-text-2">
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="font-semibold text-text">{finding.title}</h3>
        <Badge>{finding.confidence} confidence</Badge>
      </div>
      <p className="whitespace-pre-wrap break-words">{finding.analysis}</p>
      {finding.evidence.length > 0 && <ul className="space-y-2">
        {finding.evidence.map(({ source, quote }, index) => {
          const origin = sources.find((entry) => entry.id === source);
          return <li key={index} className="border-l-2 border-border-strong pl-3">
            <blockquote className="break-words">{quote}</blockquote>
            <SourceLink url={origin?.url}>{origin?.title ?? source}</SourceLink>
          </li>;
        })}
      </ul>}
      {finding.missing.length > 0 && <div>
        <h4 className="font-medium text-text">Missing evidence</h4>
        <ul className="list-disc space-y-0.5 pl-5">{finding.missing.map((item, index) => <li key={index}>{item}</li>)}</ul>
      </div>}
      {finding.questions.length > 0 && <div>
        <h4 className="font-medium text-text">Due diligence questions</h4>
        <ul className="list-disc space-y-0.5 pl-5">{finding.questions.map((item, index) => <li key={index}>{item}</li>)}</ul>
      </div>}
      {scenarios.some(({ text }) => text) && <dl className="grid gap-2 md:grid-cols-3">
        {scenarios.filter(({ text }) => text).map(({ label, text }) => (
          <div key={label} className="rounded-lg border border-border bg-surface-2 p-3">
            <dt className="font-medium text-text">{label} scenario</dt><dd>{text}</dd>
          </div>
        ))}
      </dl>}
    </section>
  );
}

function ReportView({ report }: { report: Report }) {
  return (
    <Card className="min-w-0 break-words">
      <CardHeader title={report.question} subtitle={`Saved ${dateLabel(report.created_at, "time")}`} />
      {!!report.reported_facts?.length && <section className="space-y-3 border-t border-border p-4 text-sm">
        <h3 className="font-semibold text-text">Reported figures</h3>
        {report.reported_facts.map((group) => (
          <div key={group.source} className="rounded-lg border border-border bg-surface-2 p-3">
            <h4 className="font-medium text-text"><SourceLink url={report.sources.find((source) => source.id === group.source)?.url}>{group.title}</SourceLink></h4>
            <dl className="mt-2 space-y-1 text-text-2">
              {group.entries.map(({ label, value }, index) => (
                <div key={index} className="flex flex-wrap justify-between gap-x-3">
                  <dt>{label}</dt><dd className="font-medium tabular-nums text-text">{value}</dd>
                </div>
              ))}
            </dl>
          </div>
        ))}
      </section>}
      {report.committee && <ResearchFinding finding={report.committee} sources={report.sources} />}
      {report.findings.map((finding) => <ResearchFinding key={finding.title} finding={finding} sources={report.sources} />)}
      <div className="space-y-1 border-t border-border p-4 text-sm">
        <h3 className="font-semibold text-text">Sources</h3>
        <ul className="space-y-1">{report.sources.map(({ id, title, url }) => (
          <li key={id} className="text-text-2"><SourceLink url={url}>{title}</SourceLink></li>
        ))}</ul>
      </div>
    </Card>
  );
}

export function Research({ owner, aiEnabled, selected, asOf }: { owner: string; aiEnabled: boolean; selected: PrivateDeal[]; asOf: number }) {
  const [question, setQuestion] = useState("");
  const [mode, setMode] = useState<Mode>("question");
  const [consent, setConsent] = useState(false);
  const [reportID, setReportID] = useState<string | null>(null);
  const [runID, setRunID] = useState<string | null>(null);
  const cache = useQueryClient();

  const saved = useQuery({
    queryKey: reportKey(owner), gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ items: SavedReport[] }>("reports", { owner, signal }),
  });
  const runs = useQuery({
    queryKey: ["private-markets", owner, "runs"], gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ runs: ResearchRun[] }>("research_runs", { owner, signal }),
  });
  const activeRun = useQuery({
    queryKey: ["private-markets", owner, "run", runID], enabled: Boolean(runID), gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<ResearchRun>("research_status", { owner, signal, id: runID }),
    refetchInterval: (query) => !query.state.error && (!query.state.data || query.state.data.status === "running") ? 3_000 : false,
    refetchIntervalInBackground: true,
  });
  const completion = activeRun.data?.status === "complete" ? activeRun.data.id : null;
  const shownID = reportID ?? completion;
  const shownReport = useQuery({
    queryKey: [...reportKey(owner), shownID], enabled: Boolean(shownID), gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<Report>("report", { owner, signal, id: shownID }),
  });
  const finished = activeRun.data?.status;
  useEffect(() => {
    if (finished === "complete" || finished === "failed") {
      void cache.invalidateQueries({ queryKey: reportKey(owner), exact: true });
      void cache.invalidateQueries({ queryKey: ["private-markets", owner, "runs"] });
    }
  }, [cache, finished, owner]);
  const submit = useMutation({
    mutationFn: ({ prompt, kind, sourceIDs }: { prompt: string; kind: Mode; sourceIDs: string[] }) =>
      privateMarkets<Report | { id: string; status: "running" }>("research", {
        owner, question: prompt, mode: kind, opportunity_ids: sourceIDs, document_ids: [], model_consent: true, background: kind === "committee",
      }),
    onSuccess: (result) => {
      if ("findings" in result) {
        cache.setQueryData([...reportKey(owner), result.id], result);
        setReportID(result.id);
        void cache.invalidateQueries({ queryKey: reportKey(owner), exact: true });
      } else {
        setRunID(result.id);
        void cache.invalidateQueries({ queryKey: ["private-markets", owner, "runs"] });
      }
    },
  });
  const running = Boolean(runID && !activeRun.error && (!activeRun.data || activeRun.data.status === "running"));
  const busy = submit.isPending || running;
  const reportBusy = Boolean(shownID && shownReport.isPending);
  const pendingRuns = runs.data?.runs.filter((item) => item.id !== runID) ?? [];

  return (
    <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(18rem,0.44fr)]">
      <div className="min-w-0 space-y-4">
        <Card>
          <CardHeader title="AI Investment Research" subtitle="Ask about one to three published funding rounds." />
          <form className="space-y-4 border-t border-border p-4" onSubmit={(event) => {
            event.preventDefault();
            if (!aiEnabled || !consent || busy || !question.trim() || !selected.length) return;
            setConsent(false);
            setReportID(null);
            setRunID(null);
            submit.mutate({ prompt: question.trim(), kind: mode, sourceIDs: selected.map(({ id }) => id) });
          }}>
            {selected.length ? <CompareRounds deals={selected} asOf={asOf} />
              : <p className="text-sm text-text-2">Select up to three rounds in Discover to start a report.</p>}
            {!aiEnabled && <Notice>New AI research is unavailable in this deployment. Saved reports are still available.</Notice>}
            <Field label="Research question" htmlFor="private-question">
              <textarea id="private-question" rows={3} maxLength={1_000} required disabled={!aiEnabled || busy}
                value={question} onChange={(event) => { setQuestion(event.target.value); setConsent(false); }}
                className="w-full rounded-lg border border-border bg-surface-2 p-3 text-sm text-text disabled:opacity-60" />
            </Field>
            <Segmented<Mode> label="Research mode" value={mode} onChange={(value) => { setMode(value); setConsent(false); }}
              options={[{ value: "question", label: "Question", disabled: busy }, { value: "committee", label: "Investment Committee", disabled: busy }]} />
            <label className="flex items-start gap-2 text-[13px] text-text-2">
              <input type="checkbox" className="mt-0.5" checked={consent} disabled={!aiEnabled || busy}
                onChange={(event) => setConsent(event.target.checked)} />
              <span>Allow Stock Tracker to send this question and the selected published sources to its AI provider.</span>
            </label>
            <Button type="submit" variant="primary" disabled={!aiEnabled || !consent || !question.trim() || !selected.length || busy}>
              {submit.isPending ? "Submitting…" : mode === "committee" ? "Run committee" : "Run research"}
            </Button>
          </form>
        </Card>
        {submit.error && <Notice tone="down">{submit.error.message}</Notice>}
        {running && <p className="text-sm text-text-2" role="status">Research is running. The report will appear in Saved reports when it finishes.</p>}
        {activeRun.error && <Notice tone="down">{activeRun.error.message} <Button size="sm" onClick={() => void activeRun.refetch()}>Retry status</Button></Notice>}
        {activeRun.data?.status === "failed" && <Notice tone="down">{activeRun.data.failure_message ?? "The research run could not finish."}</Notice>}
        {reportBusy && <p className="text-sm text-text-2" role="status">Opening report…</p>}
        {shownReport.error && <Notice tone="down">{shownReport.error.message} <Button size="sm" onClick={() => void shownReport.refetch()}>Retry report</Button></Notice>}
        {shownReport.data && <ReportView report={shownReport.data} />}
      </div>
      <Card className="min-w-0">
        <CardHeader title="Saved reports" subtitle="Reports saved to this account on web or iPhone." />
        {saved.isPending && <p className="border-t border-border p-4 text-sm text-text-2" role="status">Loading saved reports…</p>}
        {saved.error && <div className="border-t border-border p-4"><Notice tone="down">{saved.error.message} <Button size="sm" onClick={() => void saved.refetch()}>Retry list</Button></Notice></div>}
        {saved.data && !saved.data.items.length && <EmptyState title="No saved reports" className="border-t border-border" />}
        <ul>
          {saved.data?.items.map(({ id, title, created_at }) => (
            <li key={id} className="border-t border-border px-4 py-3">
              <button type="button" aria-pressed={(reportID ?? completion) === id} onClick={() => setReportID(id)}
                className="w-full break-words text-left text-sm font-medium text-primary-fg hover:underline">
                {title}<span className="mt-0.5 block text-xs font-normal text-text-3">{dateLabel(created_at, "time")}</span>
              </button>
            </li>
          ))}
        </ul>
        {pendingRuns.length > 0 && <div className="space-y-2 border-t border-border p-4">
          <h3 className="text-sm font-medium text-text">Recent runs</h3>
          <ul className="space-y-2">{pendingRuns.map((item) => <li key={item.id} className="text-xs text-text-2">
            {item.status === "failed" ? `${dateLabel(item.created_at, "time")} · ${item.failure_message ?? "Research failed"}`
              : <Button size="sm" onClick={() => { setReportID(null); setRunID(item.id); }}>Check run from {dateLabel(item.created_at, "time")}</Button>}
          </li>)}</ul>
        </div>}
      </Card>
    </div>
  );
}
