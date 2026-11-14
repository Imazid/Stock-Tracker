"use client";

import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { Activity } from "lucide-react";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageHeader } from "@/components/ui/PageHeader";
import { dateTime } from "@/lib/format";
import { useOrderUpdates } from "@/hooks/useOrderUpdates";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";

interface Event {
  id: string;
  source: "Practice" | "Provider";
  title: string;
  description?: string;
  time: string;
  intentId?: string;
}

async function readEvents(userId: string): Promise<Event[]> {
  const db = browserSupabase();
  if (!db) throw new Error("Accounts are unavailable.");
  const [practice, provider] = await Promise.all([
    db.from("agent_events").select("id,title,body,created_at").eq("user_id", userId)
      .order("created_at", { ascending: false }).order("seq", { ascending: false }).limit(50),
    db.from("oms_events").select("id,intent_id,kind,at").eq("user_id", userId)
      .order("id", { ascending: false }).limit(50),
  ]);
  if (practice.error || provider.error) throw new Error("Couldn’t load activity.");
  const events: Event[] = [
    ...practice.data.map((row): Event => ({
      id: `practice:${row.id}`, source: "Practice", title: row.title, description: row.body, time: row.created_at,
    })),
    ...provider.data.map((row): Event => ({
      id: `provider:${row.id}`, source: "Provider",
      title: String(row.kind).split(".").at(-1)!.replaceAll("_", " "),
      time: row.at, intentId: row.intent_id ?? undefined,
    })),
  ];
  return events.sort((left, right) => Date.parse(right.time) - Date.parse(left.time)).slice(0, 50);
}

export function ActivityView() {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  useOrderUpdates(userId, "activity");
  const activity = useQuery({
    queryKey: ["activity", userId],
    enabled: Boolean(userId),
    queryFn: () => readEvents(userId!),
    refetchInterval: 30_000,
  });

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader title="Activity" description="Recent practice trades, agent alerts and provider order events." />
      <Card>
        {session.status === "unconfigured" ? <EmptyState title="Accounts are unavailable" />
          : session.status === "signedOut" ? (
            <EmptyState icon={<Activity aria-hidden />} title="Sign in to view activity"
              actions={<ButtonLink href="/login?next=/activity" variant="primary">Sign in</ButtonLink>} />
          ) : session.status === "loading" || activity.isPending ? (
            <div className="m-4 skeleton h-20" role="status" aria-label="Loading activity" />
          ) : activity.isError ? (
            <EmptyState title="Couldn’t load activity" tone="down"
              actions={<Button onClick={() => void activity.refetch()}>Retry</Button>} />
          ) : activity.data?.length ? (
            <ol className="divide-y divide-border">
              {activity.data.map((event) => (
                <li key={event.id} className="grid gap-2 px-4 py-3 sm:grid-cols-[1fr_auto]">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge>{event.source}</Badge>
                      <span className="text-sm font-semibold first-letter:uppercase">{event.title}</span>
                    </div>
                    {event.description && <p className="mt-1 text-sm text-text-2">{event.description}</p>}
                    {event.intentId && (
                      <Link href={`/orders/${encodeURIComponent(event.intentId)}`} className="mt-1 inline-block text-xs text-accent hover:underline">View order</Link>
                    )}
                  </div>
                  <time dateTime={event.time} className="text-xs text-text-3">{dateTime(event.time)}</time>
                </li>
              ))}
            </ol>
          ) : <EmptyState icon={<Activity aria-hidden />} title="No activity yet" />}
      </Card>
    </div>
  );
}
