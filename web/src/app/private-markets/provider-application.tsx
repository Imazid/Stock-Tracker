"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Field, Input } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { accessToken } from "@/lib/session";
import { SourceLink } from "./catalog";
import { availability, privateMarkets, providerName, sourceHref, type PrivateDeal } from "./private-data";

function providerHandoffUrl(provider: string, value: string) {
  const href = sourceHref(value);
  if (!href) return;
  const url = new URL(href);
  const hosts = provider === "birchal" ? ["birchal.com", "www.birchal.com"]
    : provider === "onmarket" ? ["onmarket.com.au", "www.onmarket.com.au", "crowd.onmarket.com.au"] : [];
  if (!url.port && hosts.includes(url.hostname)) return href;
}

type PendingHandoff = { id: string; amount: string; currency: string; reviewedAt: number };

export function ProviderApplication({ owner, deal, handoff }: { owner?: string; deal: PrivateDeal; handoff?: PendingHandoff }) {
  const [amount, setAmount] = useState("");
  const [reviewed, setReviewed] = useState(false);
  const [risk, setRisk] = useState(false);
  const [ready, setReady] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const amountID = useId();
  const request = useRef<AbortController | null>(null);
  useEffect(() => () => request.current?.abort(), []);

  const amountText = handoff?.amount ?? amount.trim();
  const validAmount = /^\d{1,16}(?:\.\d{1,4})?$/.test(amountText) && Number(amountText) > 0;
  const documentUrl = deal.offer_document_url;
  const supportedProvider = ["birchal", "onmarket"].includes(deal.provider);
  if (!documentUrl || !sourceHref(documentUrl) || !supportedProvider ||
    (handoff && (handoff.currency !== deal.round.currency || availability(deal, handoff.reviewedAt) !== "open"))) {
    return handoff ? <Notice tone="warn">The current offer is unavailable for this handoff. Check your application with the provider.</Notice> : null;
  }

  async function submit() {
    if (!owner || !validAmount || !reviewed || !risk || request.current) return;
    if (availability(deal, Date.now()) !== "open") {
      setReady(false);
      setError("The offer needs to be verified again. Reopen the current round.");
      return;
    }
    const controller = new AbortController();
    request.current = controller;
    setPending(true);
    setError("");
    const fields = {
      owner, signal: controller.signal,
      ...(handoff ? { id: handoff.id } : { opportunity_id: deal.id, amount: amountText }),
      currency: deal.round.currency, document_url: documentUrl, acknowledged: true,
    };
    try {
      if (ready) {
        const { handoff_url, commitment_id } = await privateMarkets<{ handoff_url: string; commitment_id: string }>(
          handoff ? "handoff_resume" : "handoff", fields);
        const href = providerHandoffUrl(deal.provider, handoff_url);
        const token = await accessToken(owner);
        if (controller.signal.aborted || !token) return;
        if (!href || (handoff && commitment_id !== handoff.id)) throw new Error("The provider link could not be verified.");
        window.location.assign(href);
      } else {
        const result = await privateMarkets<{ ready: boolean }>(handoff ? "handoff_resume_check" : "handoff_check", fields);
        if (!controller.signal.aborted) {
          if (result.ready !== true) throw new Error("Readiness could not be verified. Try again.");
          setReady(true);
        }
      }
    } catch (failure) {
      if (!controller.signal.aborted) {
        setReady(false);
        setError(failure instanceof Error ? failure.message : "The provider request could not be verified.");
      }
    } finally {
      request.current = null;
      if (!controller.signal.aborted) setPending(false);
    }
  }

  function revise() {
    setReady(false);
    setError("");
  }

  const form = owner ? <form className="mt-3 space-y-3" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
      <p>Identity checks, the application and any payment take place with {providerName(deal.provider)}.</p>
      <div className="flex flex-wrap gap-x-4 gap-y-2">
        <SourceLink url={documentUrl}>Read the current offer document</SourceLink>
        <a href="/private-markets?view=portfolio#investor-profile" className="text-primary-fg hover:underline">Investor profile</a>
      </div>
      <label className="flex items-start gap-2">
        <input type="checkbox" className="mt-1" checked={reviewed} disabled={pending}
          onChange={(event) => { setReviewed(event.target.checked); revise(); }} />
        <span>I reviewed the current offer document.</span>
      </label>
      <label className="flex items-start gap-2">
        <input type="checkbox" className="mt-1" checked={risk} disabled={pending}
          onChange={(event) => { setRisk(event.target.checked); revise(); }} />
        <span>I understand I could lose the entire investment and may be unable to sell it.</span>
      </label>
      <Field label={`Requested amount (${deal.round.currency})`} htmlFor={amountID} className="max-w-64">
        <Input id={amountID} inputMode="decimal" maxLength={21} value={handoff?.amount ?? amount}
          readOnly={!!handoff} disabled={pending}
          onChange={(event) => { setAmount(event.target.value); revise(); }} />
      </Field>
      {amountText && !validAmount && <p>Enter a positive amount with up to four decimal places.</p>}
      {ready && <p role="status">Readiness check passed. Stock Tracker checks the latest terms again before opening the provider.</p>}
      <Button size="sm" variant="primary" type="submit" disabled={!validAmount || !reviewed || !risk || pending}>
        {pending ? "Checking requirements…" : ready ? `Open ${providerName(deal.provider)} application` : "Check readiness"}
      </Button>
      {error && <Notice tone="warn">{error}</Notice>}
    </form> : <div className="mt-3"><ButtonLink href="/login?next=/private-markets" size="sm">Sign in</ButtonLink></div>;
  if (handoff) return form;
  return <details className="border-t border-border px-4 py-3 text-[13px] text-text-2 md:px-5">
    <summary className="cursor-pointer font-medium text-text">Provider application</summary>
    {form}
  </details>;
}
