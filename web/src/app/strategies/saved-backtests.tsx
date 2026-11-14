"use client";

import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import type { BacktestArchive, SavedBacktestRow } from "@/lib/backtest-archive";
import { dateTime } from "@/lib/format";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";
import { BacktestReport } from "./backtest-panel";

const PAGE = 20;

export function SavedBacktests() {
  const session = useSession();
  return session.status === "signedIn" ? <AccountBacktests key={session.user.id} owner={session.user.id} /> :
    <Card><CardHeader title="Saved backtests" />
      <div className="px-4 pb-4 text-sm text-text-2">
        {session.status === "loading" ? "Checking account…" : session.status === "unconfigured" ? "Account storage is unavailable." :
          <ButtonLink href="/login?next=/strategies" size="sm">Sign in to open saved reports</ButtonLink>}
      </div>
    </Card>;
}

function AccountBacktests({ owner }: { owner: string }) {
  const [selected, select] = useState("");
  const [confirm, setConfirm] = useState(false);
  const cache = useQueryClient();
  const key = ["backtest-runs", owner];
  const reports = useInfiniteQuery({
    queryKey: key,
    initialPageParam: null as SavedBacktestRow | null,
    queryFn: async ({ pageParam, signal }) => {
      const db = browserSupabase();
      if (!db) throw new Error("Account storage is unavailable.");
      const query = db.from("backtest_runs").select("id,title,engine,ran_at,saved_at").eq("user_id", owner);
      if (pageParam) query.or(`saved_at.lt.${pageParam.saved_at},and(saved_at.eq.${pageParam.saved_at},id.lt.${pageParam.id})`);
      const { data, error } = await query.order("saved_at", { ascending: false }).order("id", { ascending: false }).limit(PAGE + 1).abortSignal(signal);
      if (error) throw new Error("Saved reports are unavailable.");
      return { rows: data.slice(0, PAGE) as SavedBacktestRow[], more: data.length > PAGE };
    },
    getNextPageParam: (page) => page.more ? page.rows.at(-1) : undefined,
  });
  const report = useQuery({
    queryKey: ["backtest-report", owner, selected], enabled: Boolean(selected),
    queryFn: async ({ signal }) => {
      const { data, error } = await browserSupabase()!.from("backtest_runs").select("report").eq("user_id", owner).eq("id", selected).abortSignal(signal).maybeSingle();
      if (error || data?.report?.schemaVersion !== 1 || !data.report.result?.usedRealMarketData) throw new Error("This report is unavailable.");
      return data.report as BacktestArchive;
    },
  });
  const remove = useMutation({
    mutationFn: async (id: string) => {
      const db = browserSupabase();
      if (!db || (await db.auth.getUser()).data.user?.id !== owner) throw new Error("Sign in again to remove this report.");
      const { error } = await db.from("backtest_runs").delete().eq("user_id", owner).eq("id", id);
      if (error) throw new Error("The report could not be removed. Try again.");
    },
    onSuccess: async (_, id) => {
      select("");
      setConfirm(false);
      cache.removeQueries({ queryKey: ["backtest-report", owner, id] });
      await cache.invalidateQueries({ queryKey: key });
    },
  });
  const rows = reports.data?.pages.flatMap((page) => page.rows) ?? [];
  return <Card id="saved-backtests">
    <CardHeader title="Saved backtests" subtitle="Your original simulated results and assumptions" />
    {reports.isPending ? <p role="status" className="px-4 pb-4 text-sm">Loading saved reports…</p>
      : reports.isError && !rows.length ? <div className="space-y-2 px-4 pb-4 text-sm"><p>{reports.error.message}</p><Button onClick={() => void reports.refetch()}>Retry</Button></div>
      : rows.length ? <ul className="divide-y divide-border border-t border-border">{rows.map((row) => <li key={row.id}>
        <button type="button" aria-expanded={selected === row.id} aria-controls={`report-${row.id}`} disabled={remove.isPending}
          className="block w-full px-4 py-3 text-left text-sm hover:bg-surface-2"
          onClick={() => { select(row.id === selected ? "" : row.id); setConfirm(false); remove.reset(); }}>
          <span className="block font-medium">{row.title}</span><span className="text-xs text-text-2">Run {dateTime(row.ran_at)}</span>
        </button>
        <div id={`report-${row.id}`} hidden={selected !== row.id}>{selected === row.id && <>
          {report.isPending ? <p role="status" className="px-4 py-3 text-sm">Loading report…</p> : report.isError ?
            <div className="space-y-2 px-4 py-3 text-sm"><p>{report.error.message}</p><Button onClick={() => void report.refetch()}>Retry report</Button></div> :
            <BacktestReport last={report.data} />}
          <div className="flex flex-wrap items-center gap-2 px-4 pb-4">
            {confirm ? <><span className="text-sm text-text-2">Remove this saved report?</span>
              <Button variant="danger" disabled={remove.isPending} onClick={() => remove.mutate(row.id)}>Remove report</Button>
              <Button disabled={remove.isPending} onClick={() => setConfirm(false)}>Cancel</Button></> :
              <Button size="sm" onClick={() => setConfirm(true)}>Remove saved report</Button>}
            {remove.isError && <p className="text-sm text-down" role="status">{remove.error.message}</p>}
          </div>
        </>}</div>
      </li>)}</ul> : <p className="px-4 pb-4 text-sm text-text-2">Save a completed backtest to open it here on any signed-in device.</p>}
    {reports.hasNextPage && <div className="space-y-2 px-4 py-3">
      {reports.isFetchNextPageError && <p role="status" className="text-sm text-down">Older reports could not be loaded.</p>}
      <Button disabled={reports.isFetchingNextPage} onClick={() => void reports.fetchNextPage()}>Load older reports</Button>
    </div>}
  </Card>;
}
