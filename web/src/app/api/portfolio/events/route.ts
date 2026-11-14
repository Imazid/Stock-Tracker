import { portfolioEventGroup, type PortfolioEventsResponse } from "@/lib/portfolio-events";
import { portfolioInstrument } from "@/lib/portfolio-exposure";
import type { ResearchEvent } from "@/lib/research-types";
import { serverSupabase } from "@/lib/supabase/server";
import { json, jsonError } from "@/server/http/respond";
import { yahooTicker } from "@/server/market/yahoo";
import { fmpConfigured, fmpNews, fmpUpcomingEarnings } from "@/server/research/licensed";
import { findSecListing, secConfigured, secDirectory, secSubmissions } from "@/server/research/sec";
import { instrumentID, type Instrument } from "@engine/market.ts";

const listingLimit = 10;
const holdingLimit = 200;
const materialForms = /^(8-K|10-K|10-Q|6-K|20-F|40-F)(\/A)?$/;

async function readEvents(instruments: Instrument[], read: (instrument: Instrument) => Promise<ResearchEvent[] | undefined>) {
  const queue = instruments.slice(0, listingLimit);
  let next = 0;
  const results = [];
  for (let start = 0; start < Math.min(2, queue.length); start++) {
    results.push((async () => {
      const rows = [];
      while (next < queue.length) {
        const instrument = queue[next++];
        let events: ResearchEvent[] | undefined;
        try {
          events = await read(instrument);
        } catch {
          // An unavailable provider or listing must not hide other results.
        }
        rows.push({ instrumentId: instrumentID(instrument), symbol: instrument.symbol, events });
      }
      return rows;
    })());
  }
  return (await Promise.all(results)).flat();
}

export async function GET(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "unavailable", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser();
  if (!user) return jsonError(401, "unauthenticated", "Sign in to view holding events.");
  const { data, error } = await db.from("portfolio_holdings").select("asset_symbol,asset_name,asset_kind,asset_exchange")
    .eq("user_id", user.id).is("deleted_at", null).gt("shares", 0).order("asset_symbol").order("id").limit(holdingLimit + 1)
    .abortSignal(request.signal);
  if (error) return jsonError(503, "unavailable", "Couldn’t load the listings in your portfolio.");
  const equities = new Map<string, Instrument>();
  for (const row of data.slice(0, holdingLimit)) {
    const instrument = portfolioInstrument({ symbol: row.asset_symbol, name: row.asset_name, kind: row.asset_kind, exchange: row.asset_exchange });
    if (instrument?.assetClass === "equity" && /^[A-Z0-9][A-Z0-9.\-&]{0,19}$/.test(instrument.symbol)) {
      equities.set(instrumentID(instrument), instrument);
    }
  }
  const listings = [...equities.values()];
  const us = listings.filter(({ venue }) => venue === "us");
  const fmpAvailable = fmpConfigured();
  const filingsConfigured = secConfigured();
  const now = new Date();
  const asOf = now.toISOString();
  const today = asOf.slice(0, 10);
  const through = new Date(now.getTime() + 30 * 86_400_000).toISOString().slice(0, 10);
  const [earnings, news, filings] = await Promise.all([
    fmpAvailable ? readEvents(listings, (instrument) => fmpUpcomingEarnings(yahooTicker(instrument), today, through)) : [],
    fmpAvailable ? readEvents(listings, (instrument) => fmpNews(yahooTicker(instrument))) : [],
    filingsConfigured ? readEvents(us, async ({ symbol }) => {
      const listing = findSecListing(await secDirectory(), symbol);
      if (!listing) return;
      const { events } = await secSubmissions(listing);
      return events.filter(({ category }) => materialForms.test(category));
    }) : [],
  ]);
  const result: PortfolioEventsResponse = {
    owner: user.id, asOf, holdingsTruncated: data.length > holdingLimit,
    groups: {
      earnings: portfolioEventGroup("earnings", listings.length, fmpAvailable, earnings, asOf),
      news: portfolioEventGroup("news", listings.length, fmpAvailable, news, asOf),
      filings: portfolioEventGroup("filings", us.length, filingsConfigured, filings, asOf),
    },
  };
  return json(result);
}
