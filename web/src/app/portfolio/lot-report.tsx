"use client";

import { useState, type FormEvent } from "react";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input } from "@/components/ui/Field";

export function LotReport() {
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [downloading, setDownloading] = useState(false);
  const [error, setError] = useState("");

  async function download(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const query = new URLSearchParams();
    if (start) query.set("from", start);
    if (end) query.set("through", end);
    setDownloading(true);
    setError("");
    try {
      const response = await fetch(`/api/portfolio/lots?${query}`, { cache: "no-store" });
      if (!response.ok) {
        setError(response.status === 401 ? "Sign in again to download your lot records." : "Couldn’t download your lot records. Try again.");
        return;
      }
      const url = URL.createObjectURL(await response.blob());
      const link = document.createElement("a");
      link.href = url;
      link.download = "stock-tracker-preliminary-fifo-lots-usd.csv";
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch {
      setError("Couldn’t download your lot records. Try again.");
    } finally {
      setDownloading(false);
    }
  }

  return (
    <Card>
      <CardHeader title="Tax-lot records" subtitle="Download a preliminary USD record of purchases, sale matches, fees and open lots." />
      <form onSubmit={(event) => void download(event)} className="space-y-3 border-t border-border p-4">
        <p className="text-sm text-text-2">
          Matches synced purchases in first-in, first-out order within each holding. Position snapshots and purchases with missing costs need acquisition records before the report can estimate a result. Check the lots you actually sold, corporate actions and transaction-date AUD values against your records. This report does not calculate tax.
        </p>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="First sale date (Sydney time)" htmlFor="lot-from">
            <Input id="lot-from" type="date" min="1900-01-01" max={end || "9998-12-31"} value={start}
              onChange={(event) => setStart(event.target.value)} />
          </Field>
          <Field label="Last sale date (Sydney time)" htmlFor="lot-through">
            <Input id="lot-through" type="date" min={start || "1900-01-01"} max="9998-12-31" value={end}
              onChange={(event) => setEnd(event.target.value)} />
          </Field>
        </div>
        <p className="text-xs text-text-3">Leave dates blank to include all history. Earlier sales with missing purchase records are included for review.</p>
        {error && <p role="alert" className="text-sm text-down">{error}</p>}
        <Button type="submit" size="sm" disabled={downloading}>
          {downloading ? "Preparing download…" : "Download preliminary lot CSV"}
        </Button>
      </form>
    </Card>
  );
}
