"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input } from "@/components/ui/Field";
import { accessToken } from "@/lib/session";
import { verifyAuthenticator } from "@/lib/supabase/verify-authenticator";

type ExportSection = { id: string; label: string };

class ExportError extends Error {
  constructor(message: string, readonly code?: string) { super(message); }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function exportRequest(owner: string, signal: AbortSignal, body: Record<string, unknown>) {
  signal.throwIfAborted();
  const token = await accessToken(owner);
  if (!token) throw new Error("Sign in again to export your account.");
  const response = await fetch("/api/workspace-service/account-export", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
    cache: "no-store",
    signal,
  });
  const data: unknown = await response.json().catch(() => null);
  signal.throwIfAborted();
  if (!response.ok || !isRecord(data)) {
    const error = isRecord(data) && isRecord(data.error) ? data.error : null;
    throw new ExportError(
      typeof error?.message === "string" ? error.message : "Couldn’t read your account records. Try again.",
      typeof error?.code === "string" ? error.code : undefined,
    );
  }
  return data;
}

async function accountArchive(owner: string, signal: AbortSignal, progress: (message: string) => void) {
  const manifest = await exportRequest(owner, signal, {});
  const sections: unknown = manifest.sections;
  const invalid = new Error("The account export response was incomplete. Try again.");
  if (!Array.isArray(sections) || !sections.every((entry): entry is ExportSection =>
    isRecord(entry) && typeof entry.id === "string" && /^[a-z][a-z0-9_]*$/.test(entry.id)
    && typeof entry.label === "string" && entry.label.trim().length > 0
  )) throw invalid;
  const ids = new Set(sections.map(({ id }) => id));
  if (!ids.has("account") || ids.size !== sections.length) throw invalid;

  const cloudRecords: Record<string, unknown[]> = Object.create(null);
  let completed = 0;
  for (let index = 0; index < sections.length; index += 4) {
    const batch = sections.slice(index, index + 4);
    await Promise.all(batch.map(async ({ id }) => {
      const records: Record<string, unknown>[] = [];
      let offset = 0;
      while (true) {
        const page = await exportRequest(owner, signal, { section: id, offset });
        if (!Array.isArray(page.records) || !page.records.every(isRecord)) throw invalid;
        records.push(...page.records);
        if (page.next_offset === null) break;
        if (typeof page.next_offset !== "number" || !Number.isSafeInteger(page.next_offset) ||
          page.next_offset <= offset || page.next_offset - offset !== page.records.length) throw invalid;
        offset = page.next_offset;
      }
      if (id === "account" && (records.length !== 1 || records[0].id !== owner)) throw invalid;
      cloudRecords[id] = records;
      if (!signal.aborted) progress(`Read ${++completed} of ${sections.length} sections.`);
    }));
  }
  if (!await accessToken(owner)) throw new Error("Sign in again to export your account.");
  signal.throwIfAborted();
  const orderedRecords = Object.fromEntries(sections.map(({ id }) => [id, cloudRecords[id]]));
  return {
    schema_version: 1,
    exported_at: new Date().toISOString(),
    description: "Stock Tracker account records. Cloud sections were read during the export.",
    cloud_records: orderedRecords,
  };
}

export function AccountExport({ owner }: { owner: string }) {
  const codeId = useId();
  const active = useRef<AbortController | null>(null);
  const [code, setCode] = useState("");
  const [verify, setVerify] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  useEffect(() => () => active.current?.abort(), []);

  async function download() {
    if (active.current || (verify && !/^\d{6}$/.test(code))) return;
    const request = new AbortController();
    active.current = request;
    setBusy(true);
    setStatus(verify ? "Verifying authenticator…" : "Preparing account export…");
    setError("");
    try {
      if (verify) {
        await verifyAuthenticator(owner, code, request.signal);
        setVerify(false);
        setCode("");
      }
      const archive = await accountArchive(owner, request.signal, setStatus);
      request.signal.throwIfAborted();
      const url = URL.createObjectURL(new Blob([JSON.stringify(archive, null, 2) + "\n"], { type: "application/json" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = `stock-tracker-account-${archive.exported_at.slice(0, 10)}.json`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setStatus("Account export downloaded.");
    } catch (failure) {
      if (!request.signal.aborted) {
        setStatus("");
        if (failure instanceof ExportError && failure.code === "MFA_REQUIRED") setVerify(true);
        setCode("");
        setError(failure instanceof Error ? failure.message : "Couldn’t export your account. Try again.");
      }
    } finally {
      if (active.current === request) {
        request.abort();
        active.current = null;
        setBusy(false);
      }
    }
  }

  return <Card id="account-data" className="scroll-mt-20">
    <CardHeader title="Account data" />
    <form className="space-y-3 border-t border-border p-4 text-sm text-text-2" onSubmit={(event) => {
      event.preventDefault();
      void download();
    }}>
      <p>Download your synced portfolio, watchlists, trading history and Private Markets records as JSON. Use iPhone Settings to include records stored on that device.</p>
      <p>Keep the downloaded file somewhere safe. It contains readable personal and financial information.</p>
      {verify && <Field label="Authenticator code" htmlFor={codeId}>
        <Input id={codeId} type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={6}
          value={code} disabled={busy} onChange={(event) => setCode(event.target.value.replace(/\D/g, ""))} />
      </Field>}
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="sm" variant="primary" disabled={busy || (verify && code.length !== 6)}>
          {verify ? "Verify and download" : "Download account data"}
        </Button>
        {busy && <Button size="sm" onClick={() => {
          active.current?.abort();
          active.current = null;
          setBusy(false);
          setCode("");
          setStatus("Export cancelled.");
        }}>Cancel export</Button>}
      </div>
      {status && <p role="status">{status}</p>}
      {error && <p role="alert" className="text-down">{error}</p>}
    </form>
  </Card>;
}
