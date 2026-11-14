import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Field, Input, Select } from "@/components/ui/Field";
import { SPLIT_MIN_DATE, SPLIT_MAX_RATIO, splitFields, type SplitActivity, type StockSplit } from "@/lib/portfolio-splits";
import { browserSupabase } from "@/lib/supabase/client";
import { BrokerActivity } from "./broker-activity";

type Holding = { id: string; asset_symbol: string; asset_exchange: string | null; date_added: string; deleted_at: string | null };
type Draft = { holding_id: string; effective_date: string; new_shares: string; old_shares: string; statement_reference: string };
const emptyDraft: Draft = { holding_id: "", effective_date: "", new_shares: "", old_shares: "", statement_reference: "" };
const todayInSydney = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Australia/Sydney", dateStyle: "short" }).format(new Date());
const utcDay = (daysAgo: number) => new Date(Date.now() - daysAgo * 86_400_000).toISOString().slice(0, 10);

function db() {
  const client = browserSupabase();
  if (!client) throw new Error("Accounts are unavailable.");
  return client;
}

async function readSplits(userId: string) {
  const [holdings, splits] = await Promise.all([
    db().from("portfolio_holdings").select("id,asset_symbol,asset_exchange,date_added,deleted_at")
      .eq("user_id", userId).eq("asset_kind", "Stock").order("asset_symbol").order("id").limit(1000)
      .overrideTypes<Holding[], { merge: false }>(),
    db().from("portfolio_stock_splits").select(splitFields).eq("user_id", userId)
      .order("effective_date", { ascending: false }).order("id").limit(1000)
      .overrideTypes<StockSplit[], { merge: false }>(),
  ]);
  if (holdings.error || splits.error) throw new Error("Couldn’t load split adjustments.");
  return { holdings: holdings.data, splits: splits.data };
}

function holdingLabel(holding: Holding) {
  return [holding.asset_symbol, holding.asset_exchange, holding.date_added.slice(0, 10), holding.deleted_at ? "archived" : null]
    .filter(Boolean).join(" · ");
}

export function StockSplits({ userId }: { userId: string }) {
  const [expanded, setExpanded] = useState(false);
  const [draft, setDraft] = useState(emptyDraft);
  const [activity, setActivity] = useState<SplitActivity>();
  const [showBroker, setShowBroker] = useState(false);
  const [brokerStart, setBrokerStart] = useState(() => utcDay(89));
  const [brokerEnd, setBrokerEnd] = useState(() => utcDay(0));
  const [editing, setEditing] = useState<StockSplit>();
  const [removing, setRemoving] = useState<StockSplit>();
  const [feedback, setFeedback] = useState("");
  const [error, setError] = useState("");
  const cache = useQueryClient();
  const queryKey = ["portfolio-stock-splits", userId];
  const records = useQuery({ queryKey, queryFn: () => readSplits(userId), enabled: expanded });
  const holdings = records.data?.holdings ?? [];
  const splits = records.data?.splits ?? [];
  const today = todayInSydney();

  const save = useMutation({
    mutationFn: async ({ draft, editing, activity }: { draft: Draft; editing?: StockSplit; activity?: SplitActivity }) => {
      const newShares = Number(draft.new_shares);
      const oldShares = Number(draft.old_shares);
      if (!draft.holding_id || !draft.effective_date || draft.effective_date < SPLIT_MIN_DATE || draft.effective_date > today ||
          ![newShares, oldShares].every((value) => Number.isInteger(value) && value >= 1 && value <= SPLIT_MAX_RATIO) ||
          newShares === oldShares) throw new Error("Choose a holding and date, and enter two different whole numbers for the ratio.");
      const values = { holding_id: draft.holding_id, effective_date: draft.effective_date,
        new_shares: newShares, old_shares: oldShares, statement_reference: draft.statement_reference.trim() };
      const table = db().from("portfolio_stock_splits");
      const write = editing
        ? table.update(values).eq("user_id", userId).eq("id", editing.id).eq("updated_at", editing.updated_at)
        : table.insert({ ...values, user_id: userId, ...(activity && {
          snaptrade_activity_id: activity.id, snaptrade_activity_date: activity.date,
          snaptrade_activity_label: activity.label, snaptrade_activity_symbol: activity.symbol,
        }) });
      const { data, error } = await write.select("id").maybeSingle();
      if (error?.code === "23505") {
        if (error.message.includes("portfolio_stock_splits_snaptrade_activity_key")) {
          throw new Error("This SnapTrade event is already recorded. Edit its existing adjustment to correct it.");
        }
        throw new Error("This holding already has an adjustment on that date. Edit that entry to correct it.");
      }
      if (error) throw new Error("Couldn’t save the adjustment. Try again.");
      if (!data) throw new Error("This adjustment changed elsewhere. Refresh the list and try again.");
    },
    onSuccess: async () => {
      setEditing(undefined);
      setDraft(emptyDraft);
      setActivity(undefined);
      setFeedback("Split adjustment saved.");
      await Promise.all([cache.invalidateQueries({ queryKey }), cache.invalidateQueries({ queryKey: ["portfolio-gains", userId] })]);
    },
    onError: (error) => setError(error.message),
  });

  const remove = useMutation({
    mutationFn: async (split: StockSplit) => {
      const { data, error } = await db().from("portfolio_stock_splits").delete()
        .eq("user_id", userId).eq("id", split.id).eq("updated_at", split.updated_at).select("id").maybeSingle();
      if (error) throw new Error("Couldn’t remove the adjustment. Try again.");
      if (!data) throw new Error("This adjustment changed elsewhere. Refresh the list and try again.");
    },
    onSuccess: async (_, split) => {
      setRemoving(undefined);
      if (editing?.id === split.id) {
        setEditing(undefined);
        setDraft(emptyDraft);
      }
      setFeedback("Split adjustment removed.");
      await Promise.all([cache.invalidateQueries({ queryKey }), cache.invalidateQueries({ queryKey: ["portfolio-gains", userId] })]);
    },
    onError: (error) => setError(error.message),
  });
  const busy = save.isPending || remove.isPending;

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setFeedback("");
    save.mutate({ draft, editing, activity });
  }

  function reviewSplit(source: SplitActivity) {
    setActivity(source);
    setDraft((current) => ({ ...current, effective_date: current.effective_date || source.date }));
    setRemoving(undefined);
    setError("");
    setFeedback("");
    document.getElementById("split-holding")?.focus();
  }

  function edit(split: StockSplit) {
    setEditing(split);
    setActivity(undefined);
    setRemoving(undefined);
    setDraft({ holding_id: split.holding_id, effective_date: split.effective_date, new_shares: String(split.new_shares),
      old_shares: String(split.old_shares), statement_reference: split.statement_reference });
    setError("");
    setFeedback("");
    document.getElementById("split-holding")?.focus();
  }

  return (
    <section className="space-y-3 border-t border-border p-4" aria-label="Stock split adjustments">
      <Button size="sm" aria-expanded={expanded} aria-controls="stock-split-controls" onClick={() => setExpanded(!expanded)}>
        {expanded ? "Hide stock split adjustments" : "Manage stock split adjustments"}
      </Button>
      {expanded && <div id="stock-split-controls" className="space-y-4">
        <p className="text-sm text-text-2">
          Enter splits and reverse splits from your broker statement. Use the ratio and the Sydney date when the new units first applied.
          Enter trades in the units shown on each trade confirmation. Adjustments apply to this report. Check any cash paid for fractional shares separately.
        </p>
        {records.isPending && <p className="text-sm text-text-2" role="status">Loading adjustments…</p>}
        {records.isError && <div className="flex flex-wrap items-center gap-2 text-sm">
          <p role="alert">{records.error.message}</p><Button size="sm" onClick={() => void records.refetch()}>Retry</Button>
        </div>}
        {splits.length > 0 && <ul className="divide-y divide-border rounded-lg border border-border">
          {splits.map((split) => <li key={split.id} className="flex flex-wrap items-center justify-between gap-2 p-3">
            <div className="min-w-0 text-sm">
              <p className="font-medium">{split.portfolio_holdings?.asset_symbol ?? "Holding"} · {split.new_shares} for {split.old_shares}</p>
              <p className="[overflow-wrap:anywhere] text-text-2">{split.effective_date}{split.statement_reference && ` · ${split.statement_reference}`}</p>
              {split.snaptrade_activity_id && <p className="[overflow-wrap:anywhere] text-xs text-text-2">
                {["SnapTrade reference", split.snaptrade_activity_label, split.snaptrade_activity_symbol, split.snaptrade_activity_date].filter(Boolean).join(" · ")}
              </p>}
            </div>
            {removing?.id === split.id ? <div className="flex flex-wrap gap-2">
              <Button size="sm" disabled={busy} onClick={() => setRemoving(undefined)}>Cancel</Button>
              <Button size="sm" variant="danger" disabled={busy} onClick={() => { setError(""); setFeedback(""); remove.mutate(split); }}>Remove adjustment</Button>
            </div> : <div className="flex gap-2">
              <Button size="sm" disabled={busy} onClick={() => edit(split)}>Edit</Button>
              <Button size="sm" disabled={busy} onClick={() => setRemoving(split)}>Remove</Button>
            </div>}
          </li>)}
        </ul>}
        {records.isSuccess && holdings.length === 0 && <p className="text-sm text-text-2">Sync a stock holding to add a split adjustment.</p>}
        {holdings.length > 0 && <div className="space-y-3">
          <Button size="sm" aria-expanded={showBroker} aria-controls="split-broker-controls" onClick={() => setShowBroker(!showBroker)}>
            {showBroker ? "Hide brokerage lookup" : "Find splits in linked accounts"}
          </Button>
          {showBroker && <div id="split-broker-controls" className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="First reported date" htmlFor="split-broker-from">
                <Input id="split-broker-from" type="date" min={SPLIT_MIN_DATE} max={brokerEnd || today} value={brokerStart}
                  onChange={(event) => setBrokerStart(event.target.value)} />
              </Field>
              <Field label="Last reported date" htmlFor="split-broker-through">
                <Input id="split-broker-through" type="date" min={brokerStart || SPLIT_MIN_DATE} max={today} value={brokerEnd}
                  onChange={(event) => setBrokerEnd(event.target.value)} />
              </Field>
            </div>
            {brokerStart >= SPLIT_MIN_DATE && brokerEnd >= brokerStart && brokerEnd <= today ?
              <BrokerActivity key={`${brokerStart}/${brokerEnd}`} mode="splits" start={brokerStart} end={brokerEnd}
                selectedId={activity?.id} canInclude={!busy && !editing && !activity}
                imported={new Set(splits.flatMap((split) => split.snaptrade_activity_id ? [split.snaptrade_activity_id] : []))}
                onReview={reviewSplit} />
              : <p className="text-sm text-text-2">Choose a valid range of reported dates.</p>}
          </div>}
        </div>}
        {holdings.length > 0 && <form onSubmit={submit} className="space-y-3">
          <fieldset disabled={busy} className="space-y-3">
            {activity && <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="min-w-0 [overflow-wrap:anywhere] text-sm text-text-2" role="status">
                {["Reviewing SnapTrade event", activity.label, activity.symbol, activity.date].filter(Boolean).join(" · ")}
              </p>
              <Button size="sm" onClick={() => setActivity(undefined)}>Clear broker reference</Button>
            </div>}
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Stock holding" htmlFor="split-holding">
                <Select id="split-holding" required value={draft.holding_id} onChange={(event) => setDraft({ ...draft, holding_id: event.target.value })}>
                  <option value="">Choose a holding</option>
                  {holdings.map((holding) => <option key={holding.id} value={holding.id}>{holdingLabel(holding)}</option>)}
                </Select>
              </Field>
              <Field label="Split effective date (Sydney)" htmlFor="split-date">
                <Input id="split-date" required type="date" min={SPLIT_MIN_DATE} max={today} value={draft.effective_date}
                  onChange={(event) => setDraft({ ...draft, effective_date: event.target.value })} />
              </Field>
              <Field label="New shares in ratio" htmlFor="split-new">
                <Input id="split-new" required type="number" min={1} max={SPLIT_MAX_RATIO} step={1} value={draft.new_shares}
                  onChange={(event) => setDraft({ ...draft, new_shares: event.target.value })} />
              </Field>
              <Field label="Old shares in ratio" htmlFor="split-old">
                <Input id="split-old" required type="number" min={1} max={SPLIT_MAX_RATIO} step={1} value={draft.old_shares}
                  onChange={(event) => setDraft({ ...draft, old_shares: event.target.value })} />
              </Field>
            </div>
            <Field label="Statement reference (optional)" htmlFor="split-reference">
              <Input id="split-reference" value={draft.statement_reference} maxLength={200}
                onChange={(event) => setDraft({ ...draft, statement_reference: event.target.value })} />
            </Field>
            <div className="flex flex-wrap gap-2">
              <Button size="sm" type="submit" disabled={busy}>{editing ? "Save changes" : "Add split adjustment"}</Button>
              {editing && <Button size="sm" disabled={busy} onClick={() => { setEditing(undefined); setDraft(emptyDraft); setError(""); }}>Cancel edit</Button>}
            </div>
          </fieldset>
        </form>}
        {error && <p className="text-sm text-down" role="alert">{error}</p>}
        {feedback && <p className="text-sm text-text-2" role="status">{feedback}</p>}
      </div>}
    </section>
  );
}
