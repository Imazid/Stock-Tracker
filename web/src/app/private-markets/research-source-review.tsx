import { Badge } from "@/components/ui/Badge";
import { Notice } from "@/components/ui/Notice";
import { CompareRounds, SourceLink } from "./catalog";
import { dateLabel, type ResearchRefresh } from "./private-data";

function sourceValue(field: string, value: string | null) {
  if (value == null) return "Undisclosed";
  return field === "Published deadline" ? dateLabel(value, "time") : value;
}

export function ResearchSourceReview({ review, selected, asOf, disabled, onToggle }: {
  review: ResearchRefresh; selected: string[]; asOf: number; disabled: boolean;
  onToggle: (id: string, checked: boolean) => void;
}) {
  const groups = [
    {
      title: "Original public sources",
      items: [
        ...review.deals.map((deal) => ({
          id: deal.id, title: `${deal.round.company.name} · ${deal.round.stage}`,
          url: deal.source_url, detail: null, revised: review.changed_deal_ids.includes(deal.id),
        })),
        ...review.announcements.map((item) => ({
          id: item.id, title: `${item.company.name} · ${item.title}`, url: item.source_url,
          detail: item.significance, revised: review.changed_announcement_ids.includes(item.id),
        })),
      ],
    },
    {
      title: "Published or revised since the previous report",
      items: review.newer_announcements.map((item) => ({
        id: item.id, title: `${item.company.name} · ${item.title}`, url: item.source_url, revised: false,
        detail: `${dateLabel(item.revised_at ?? item.published_at)} · ${item.significance}`,
      })),
    },
  ];

  return <div className="space-y-4">
    {review.unavailable_sources > 0 && <Notice tone="warn">
      {review.unavailable_sources} original {review.unavailable_sources === 1 ? "source is" : "sources are"} unavailable.
    </Notice>}
    {!review.revision_tracking_available && <Notice>This report predates revision tracking. Review the current sources for changes.</Notice>}
    {review.source_changes.length > 0 && <section className="space-y-2">
      <h3 className="text-sm font-semibold text-text">What changed</h3>
      {review.source_changes.map(({ source_id, title, fields }) => <div key={source_id}
        className="space-y-2 rounded-lg border border-border p-3 text-sm">
        <p className="font-medium text-text">{title}</p>
        {fields.map(({ field, previous, current }) => <details key={field} className="text-text-2">
          <summary className="cursor-pointer">{field}</summary>
          <dl className="mt-1 grid gap-2 break-words sm:grid-cols-2">
            <div><dt className="font-medium text-text">Previous</dt><dd>{sourceValue(field, previous)}</dd></div>
            <div><dt className="font-medium text-text">Current</dt><dd>{sourceValue(field, current)}</dd></div>
          </dl>
        </details>)}
      </div>)}
    </section>}
    {groups.map(({ title, items }) => items.length > 0 && <fieldset key={title} className="min-w-0 space-y-2">
      <legend className="mb-2 text-sm font-semibold text-text">{title}</legend>
      {items.map((item) => {
        const checked = selected.includes(item.id);
        return <div key={item.id} className="space-y-1 rounded-lg border border-border p-3 text-sm text-text-2">
          <label className="flex min-w-0 items-start gap-2">
            <input className="mt-0.5" type="checkbox" checked={checked} disabled={disabled || (!checked && selected.length >= 3)}
              onChange={(event) => onToggle(item.id, event.target.checked)} />
            <span className="min-w-0 break-words">{item.title}{item.revised && <span className="ml-2"><Badge>Revised</Badge></span>}</span>
          </label>
          {item.detail && <p className="break-words">{item.detail}</p>}
          <SourceLink url={item.url}>Read original source</SourceLink>
        </div>;
      })}
    </fieldset>)}
    {review.deals.length > 0 && <CompareRounds deals={review.deals} asOf={asOf} />}
    {!groups.some(({ items }) => items.length) && <p className="text-sm text-text-2">No published sources are available for this report.</p>}
  </div>;
}
