"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useId, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { dateLabel, privateMarkets, type SavedExcerpt } from "./private-data";

export function dealRoomExcerpts(owner: string) {
  return {
    queryKey: ["private-markets", owner, "documents"], gcTime: 0, retry: false as const,
    queryFn: ({ signal }: { signal: AbortSignal }) => privateMarkets<{ items: SavedExcerpt[] }>("documents", { owner, signal }),
  };
}

export function DealRoom({ owner }: { owner: string }) {
  const titleID = useId();
  const excerptID = useId();
  const cache = useQueryClient();
  const [title, setTitle] = useState("");
  const [excerpt, setExcerpt] = useState("");
  const [authorized, setAuthorized] = useState(false);
  const [opened, setOpened] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const options = dealRoomExcerpts(owner);
  const items = useQuery(options);
  const selected = items.data?.items.find((item) => item.id === opened);
  const content = useQuery({
    queryKey: [...options.queryKey, opened], enabled: Boolean(selected), gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ excerpt: string }>("document", { owner, signal, id: opened }),
  });
  const save = useMutation({
    mutationFn: () => privateMarkets<SavedExcerpt>("save_document", {
      owner, title: title.trim(), excerpt: excerpt.trim(), authorized: true,
    }),
    onSuccess: async ({ id }) => {
      setTitle("");
      setExcerpt("");
      setAuthorized(false);
      setOpened(id);
      await cache.invalidateQueries({ queryKey: options.queryKey, exact: true });
    },
  });
  const remove = useMutation({
    mutationFn: (id: string) => privateMarkets("delete_document", { owner, id }),
    onSuccess: async (_, id) => {
      setOpened((current) => current === id ? null : current);
      setConfirmDelete((current) => current === id ? null : current);
      cache.removeQueries({ queryKey: [...options.queryKey, id], exact: true });
      cache.setQueryData<{ items: SavedExcerpt[] }>(options.queryKey,
        (data) => data && { items: data.items.filter((item) => item.id !== id) });
      await cache.invalidateQueries({ queryKey: options.queryKey, exact: true });
    },
  });
  const valid = Boolean(title.trim()) && excerpt.trim().length >= 40 && excerpt.length <= 4_500;

  function revise() {
    setAuthorized(false);
    save.reset();
  }

  return <div className="grid items-start gap-4 lg:grid-cols-2">
    <Card>
      <CardHeader title="Add a research excerpt" />
      <form className="space-y-3 border-t border-border p-4" onSubmit={(event) => {
        event.preventDefault();
        if (valid && authorized && !save.isPending) save.mutate();
      }}>
        <Field label="Excerpt title" htmlFor={titleID}>
          <Input id={titleID} maxLength={160} value={title} required disabled={save.isPending}
            onChange={(event) => { setTitle(event.target.value); revise(); }} />
        </Field>
        <Field label="Reviewed excerpt" htmlFor={excerptID} hint="Paste 40–4,500 characters. Remove personal identifiers and banking details.">
          <textarea id={excerptID} className="w-full rounded-lg border border-border bg-surface-2 p-3 text-sm text-text"
            rows={8} value={excerpt} minLength={40} maxLength={4_500} required disabled={save.isPending}
            onChange={(event) => { setExcerpt(event.target.value); revise(); }} />
        </Field>
        <label className="flex items-start gap-2 text-[13px] text-text-2">
          <input type="checkbox" className="mt-0.5" checked={authorized} disabled={save.isPending}
            onChange={(event) => setAuthorized(event.target.checked)} />
          <span>I have permission to store this excerpt in Stock Tracker.</span>
        </label>
        <p className="text-xs text-text-2">Stock Tracker encrypts saved excerpts. AI research requires separate consent.</p>
        <Button type="submit" variant="primary" size="sm" disabled={!valid || !authorized || save.isPending}>
          {save.isPending ? "Saving…" : "Save excerpt"}
        </Button>
        {save.isSuccess && <p role="status" className="text-sm text-text-2">Excerpt saved.</p>}
        {save.error && <Notice tone="down">{save.error.message}</Notice>}
      </form>
    </Card>
    <div className="min-w-0 space-y-4">
      <Card>
        <CardHeader title="Saved excerpts" subtitle="Available from Deal Room on web and iPhone." />
        {items.isPending && <p className="border-t border-border p-4 text-sm text-text-2" role="status">Loading excerpts…</p>}
        {items.error && <div className="p-4"><Notice tone="down">{items.error.message} <Button size="sm" onClick={() => void items.refetch()}>Retry</Button></Notice></div>}
        {items.data && !items.data.items.length && <EmptyState title="No excerpts saved" className="border-t border-border" />}
        <ul className="divide-y divide-border">
          {items.data?.items.map((item) => <li key={item.id}>
            <button type="button" className="w-full px-4 py-2.5 text-left text-sm hover:bg-surface-2" aria-pressed={opened === item.id}
              onClick={() => { setOpened(item.id); setConfirmDelete(null); remove.reset(); }}>
              <span className="block break-words font-medium text-text">{item.title}</span>
              <span className="text-xs text-text-3">{dateLabel(item.created_at)}</span>
            </button>
          </li>)}
        </ul>
      </Card>
      {selected && <Card>
        <CardHeader title={<span className="break-words">{selected.title}</span>}
          actions={<Button size="sm" onClick={() => { setOpened(null); setConfirmDelete(null); }}>Close excerpt</Button>} />
        <div className="space-y-3 border-t border-border p-4 text-sm text-text-2">
          {content.isPending && <p role="status">Opening excerpt…</p>}
          {content.error && <Notice tone="down">{content.error.message} <Button size="sm" onClick={() => void content.refetch()}>Retry</Button></Notice>}
          {content.data && <p className="whitespace-pre-wrap break-words">{content.data.excerpt}</p>}
          {confirmDelete === selected.id ? <div className="space-y-2">
            <p>Delete this excerpt? Saved research reports may still contain quotes from it.</p>
            <div className="flex flex-wrap gap-2">
              <Button size="sm" variant="danger" disabled={remove.isPending} onClick={() => remove.mutate(selected.id)}>Confirm deletion</Button>
              <Button size="sm" disabled={remove.isPending} onClick={() => setConfirmDelete(null)}>Cancel</Button>
            </div>
          </div> : <Button size="sm" onClick={() => setConfirmDelete(selected.id)}>Delete excerpt</Button>}
          {remove.error && <Notice tone="down">{remove.error.message}</Notice>}
        </div>
      </Card>}
    </div>
  </div>;
}
