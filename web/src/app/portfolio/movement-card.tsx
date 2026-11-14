import Link from "next/link";
import { SourceLine, StatusChip } from "@/components/market/DataChips";
import { Card, CardHeader } from "@/components/ui/Card";
import { ButtonLink } from "@/components/ui/Button";
import { EmptyState } from "@/components/ui/EmptyState";
import { signedMoney } from "@/lib/format";
import type { portfolioMovement } from "@/lib/portfolio-movement";
import { portfolioQuestionHref } from "@/lib/portfolio-question";

export function MovementCard({ movement, holdingCount, loading, aiEnabled }: {
  movement: ReturnType<typeof portfolioMovement>;
  holdingCount: number;
  loading: boolean;
  aiEnabled: boolean;
}) {
  return (
    <Card>
      <CardHeader title="Your Portfolio Intelligence" subtitle="Market moves applied to your current quantities. Equity quotes use the previous close and crypto quotes use the provider’s reference price."
        className="flex-wrap" actions={aiEnabled && <ButtonLink href={portfolioQuestionHref} size="sm">Ask what moved my portfolio</ButtonLink>} />
      {movement.covered === 0 ? (
        <EmptyState title={loading ? "Loading position prices" : "Position moves are unavailable"} />
      ) : (
        <>
          <dl className="flex flex-wrap gap-x-8 gap-y-2 border-t border-border px-4 py-3">
            {movement.totals.map(([currency, value]) => (
              <div key={currency}>
                <dt className="text-xs text-text-3">{currency} move</dt>
                <dd className="tabular text-xl font-semibold">{signedMoney(value, currency)}</dd>
              </div>
            ))}
          </dl>
          <p className="px-4 pb-3 text-xs text-text-3">{movement.covered} of {holdingCount} displayed positions have usable quotes and reference prices.</p>
          <ul className="divide-y divide-border border-t border-border">
            {movement.contributions.slice(0, 5).map(({ id, quote, value }) => (
              <li key={id} className="flex flex-wrap items-start justify-between gap-2 px-4 py-3">
                <div>
                  <Link href={`/markets/${encodeURIComponent(id)}`} className="text-sm font-medium hover:underline">{id.slice(id.indexOf(":") + 1)}</Link>
                  <div className="mt-1"><SourceLine {...quote} /></div>
                </div>
                <div className="flex items-center gap-2">
                  <StatusChip status={quote.status} delayMinutes={quote.delayMinutes} />
                  <span className="tabular text-sm font-medium">{signedMoney(value, quote.currency)}</span>
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </Card>
  );
}
