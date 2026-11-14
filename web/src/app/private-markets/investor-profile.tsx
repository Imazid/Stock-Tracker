"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { countryName, dateLabel, privateMarkets, providerName, type InvestorProfile, type InvestorProfileResponse } from "./private-data";

const emptyProfile: InvestorProfile = { country: "AU", declared_class: "unknown" };

export function InvestorProfileCard({ owner }: { owner: string }) {
  const cache = useQueryClient();
  const [draft, setDraft] = useState<InvestorProfile | null>(null);
  const queryKey = ["private-markets", owner, "profile"];
  const profile = useQuery({
    queryKey, gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<InvestorProfileResponse>("profile", { owner, signal }),
  });
  const form = draft ?? profile.data?.profile ?? emptyProfile;
  const save = useMutation({
    mutationFn: (value: InvestorProfile) => privateMarkets("save_profile", { owner, ...value }),
    onSuccess: async () => {
      await cache.invalidateQueries({ queryKey });
      setDraft(null);
    },
  });

  return <section id="investor-profile" className="scroll-mt-20">
    <Card>
      <CardHeader title="Investor profile" />
      <div className="space-y-3 border-t border-border p-4 text-[13px] text-text-2">
        <p>Your provider verifies identity, eligibility and supporting documents.</p>
        {profile.isPending && <p role="status">Loading investor profile…</p>}
        {profile.error && <Notice tone="down">{profile.error.message} <Button size="sm" onClick={() => void profile.refetch()}>Retry profile</Button></Notice>}
        {profile.data && <>
          <form className="space-y-3" onSubmit={(event) => {
            event.preventDefault();
            if (/^[A-Z]{2}$/.test(form.country) && !save.isPending) save.mutate(form);
          }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Country code" htmlFor="investor-country">
                <Input id="investor-country" value={form.country} maxLength={2} autoCapitalize="characters" pattern="[A-Z]{2}"
                  disabled={save.isPending} required onChange={(event) => {
                    save.reset();
                    setDraft({ ...form, country: event.target.value.toUpperCase() });
                  }} />
              </Field>
              <Field label="Self-declared classification" htmlFor="investor-class">
                <Select id="investor-class" value={form.declared_class} disabled={save.isPending} onChange={(event) => {
                  save.reset();
                  setDraft({ ...form, declared_class: event.target.value as InvestorProfile["declared_class"] });
                }}>
                  <option value="unknown">Undeclared</option>
                  <option value="retail">Retail</option>
                  <option value="wholesale">Wholesale</option>
                </Select>
              </Field>
            </div>
            <Button type="submit" size="sm" variant="primary" disabled={save.isPending || !/^[A-Z]{2}$/.test(form.country)}>
              {save.isPending ? "Saving…" : "Save profile"}
            </Button>
            {save.isSuccess && <p role="status">Investor profile saved.</p>}
            {save.error && <Notice tone="down">{save.error.message}</Notice>}
          </form>
          <div className="space-y-2 border-t border-border pt-3">
            <h3 className="font-medium text-text">Provider verification</h3>
            {!profile.data.eligibility.length && <p>No provider verification on record.</p>}
            {profile.data.eligibility.map((check) => {
              const status = check.connection.revoked_at ? "Connection revoked"
                : Date.parse(check.expires_at) <= profile.dataUpdatedAt ? "Verification expired"
                : Date.parse(check.verified_at) > profile.dataUpdatedAt ? "Verification pending" : "Verification current";
              return <div key={`${check.provider}:${check.jurisdiction}`} className="rounded-lg border border-border bg-surface-2 p-3">
                <p className="font-medium text-text">{providerName(check.provider)} · {countryName(check.jurisdiction)}</p>
                <p>{check.verified_class === "retail" ? "Retail" : "Wholesale"} · {status}</p>
                <p>Verified {dateLabel(check.verified_at, "time")} · Expires {dateLabel(check.expires_at, "time")}</p>
                {check.accountant_certificate_reviewed_at && <p>Accountant certificate reviewed {dateLabel(check.accountant_certificate_reviewed_at)}</p>}
              </div>;
            })}
          </div>
        </>}
      </div>
    </Card>
  </section>;
}
