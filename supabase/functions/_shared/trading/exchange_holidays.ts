// Full-day closures and early closes for the international venues, from each exchange's
// published calendar. A port of TradingCore/Sources/TradingCore/ExchangeHolidays.swift:
// the same days, early closes and covered years (the shared calendar vectors fail if they
// drift). Outside the covered years a venue still knows its weekly hours, and an unlisted
// holiday fails safe (no fresh quotes arrive, so nothing trades). Euronext has closures
// but no covered years: its December half-day times are unpublished.

import type { Venue } from "./market.ts";

export const ExchangeHolidays: {
  /** Venue → full-day closures, "yyyy-MM-dd" in the exchange's own time zone. */
  closures: Partial<Record<Venue, string[]>>;
  /**
   * Venue → early-close days, "yyyy-MM-dd" → last trading time "HH:mm" local (the end of
   * continuous trading that day; for a morning-only Asian half day, the end of the morning).
   */
  earlyCloses: Partial<Record<Venue, Record<string, string>>>;
  /** Venue → the years the tables above are complete for. */
  coveredYears: Partial<Record<Venue, { lowerBound: number; upperBound: number }>>;
} = {
  closures: {
    // https://www.londonstockexchange.com/equities-trading/business-days + https://www.londonstockexchange.com/content/dam/lse/en_us/documents/guides/settlement-calendar.xlsx
    lse: [
      "2026-01-01", "2026-04-03", "2026-04-06", "2026-05-04", "2026-05-25", "2026-08-31", "2026-12-25",
      "2026-12-28", "2027-01-01", "2027-03-26", "2027-03-29", "2027-05-03", "2027-05-31", "2027-08-30",
      "2027-12-27", "2027-12-28",
    ],
    // https://www.cashmarket.deutsche-boerse.com/cash-en/trading/trading-calendar-and-trading-hours
    xetra: [
      "2026-01-01", "2026-04-03", "2026-04-06", "2026-05-01", "2026-12-24", "2026-12-25", "2026-12-31",
      "2027-01-01", "2027-03-26", "2027-03-29", "2027-12-24", "2027-12-31",
    ],
    // https://www.euronext.com/en/trade/trading-hours-holidays
    euronextParis: [
      "2026-01-01", "2026-04-03", "2026-04-06", "2026-05-01", "2026-12-25", "2027-01-01", "2027-03-26",
      "2027-03-29",
    ],
    // https://www.euronext.com/en/trade/trading-hours-holidays
    euronextAmsterdam: [
      "2026-01-01", "2026-04-03", "2026-04-06", "2026-05-01", "2026-12-25", "2027-01-01", "2027-03-26",
      "2027-03-29",
    ],
    // https://www.six-group.com/en/products-services/the-swiss-stock-exchange/trading/trading-provisions/regulation.html
    six: [
      "2026-01-01", "2026-01-02", "2026-04-03", "2026-04-06", "2026-05-01", "2026-05-14", "2026-05-25",
      "2026-12-24", "2026-12-25", "2026-12-31", "2027-01-01", "2027-03-26", "2027-03-29", "2027-05-06",
      "2027-05-17", "2027-12-24", "2027-12-31",
    ],
    // https://www.jpx.co.jp/english/corporate/about-jpx/calendar/index.html
    tse: [
      "2026-01-01", "2026-01-02", "2026-01-12", "2026-02-11", "2026-02-23", "2026-03-20", "2026-04-29",
      "2026-05-04", "2026-05-05", "2026-05-06", "2026-07-20", "2026-08-11", "2026-09-21", "2026-09-22",
      "2026-09-23", "2026-10-12", "2026-11-03", "2026-11-23", "2026-12-31", "2027-01-01", "2027-01-11",
      "2027-02-11", "2027-02-23", "2027-03-22", "2027-04-29", "2027-05-03", "2027-05-04", "2027-05-05",
      "2027-07-19", "2027-08-11", "2027-09-20", "2027-09-23", "2027-10-11", "2027-11-03", "2027-11-23",
      "2027-12-31",
    ],
    // https://www.hkex.com.hk/Services/Circulars-and-Notices/Participant-and-Members-Circulars/SEHK/2025/SEHK_CT_075_2025 + SEHK/2026/SEHK_CT_077_2026
    hkex: [
      "2026-01-01", "2026-02-17", "2026-02-18", "2026-02-19", "2026-04-03", "2026-04-06", "2026-04-07",
      "2026-05-01", "2026-05-25", "2026-06-19", "2026-07-01", "2026-10-01", "2026-10-19", "2026-12-25",
      "2027-01-01", "2027-02-08", "2027-02-09", "2027-03-26", "2027-03-29", "2027-04-05", "2027-05-13",
      "2027-06-09", "2027-07-01", "2027-09-16", "2027-10-01", "2027-10-08", "2027-12-27",
    ],
    // https://www.sgx.com/securities/trading + https://www.mom.gov.sg/employment-practices/public-holidays
    sgx: [
      "2026-01-01", "2026-02-17", "2026-02-18", "2026-04-03", "2026-05-01", "2026-05-27", "2026-06-01",
      "2026-08-10", "2026-11-09", "2026-12-25",
    ],
    // https://global.krx.co.kr/contents/GLB/05/0501/0501110000/GLB0501110000.jsp
    krx: [
      "2026-01-01", "2026-02-16", "2026-02-17", "2026-02-18", "2026-03-02", "2026-05-01", "2026-05-05",
      "2026-05-25", "2026-06-03", "2026-07-17", "2026-08-17", "2026-09-24", "2026-09-25", "2026-10-05",
      "2026-10-09", "2026-12-25", "2026-12-31", "2027-01-01", "2027-02-08", "2027-02-09", "2027-03-01",
      "2027-05-03", "2027-05-05", "2027-05-13", "2027-07-19", "2027-08-16", "2027-09-14", "2027-09-15",
      "2027-09-16", "2027-10-04", "2027-10-11", "2027-12-27", "2027-12-31",
    ],
    // https://www.nseindia.com/resources/exchange-communication-holidays
    nse: [
      "2026-01-15", "2026-01-26", "2026-03-03", "2026-03-26", "2026-03-31", "2026-04-03", "2026-04-14",
      "2026-05-01", "2026-05-28", "2026-06-26", "2026-09-14", "2026-10-02", "2026-10-20", "2026-11-10",
      "2026-11-24", "2026-12-25",
    ],
  },
  earlyCloses: {
    // https://www.londonstockexchange.com/equities-trading/business-days
    lse: { "2026-12-24": "12:30", "2026-12-31": "12:30", "2027-12-24": "12:30", "2027-12-31": "12:30" },
    // https://www.cashmarket.deutsche-boerse.com/resource/blob/5673886/22764993c4b1617c5f465186066344e6/data/Final%20trading%20session%202026.pdf
    xetra: { "2026-12-30": "14:00" },
    // https://www.hkex.com.hk/Services/Trading-hours-and-Severe-Weather-Arrangements/Trading-Hours/Securities-Market?sc_lang=en
    hkex: { "2026-02-16": "12:00", "2026-12-24": "12:00", "2026-12-31": "12:00", "2027-02-05": "12:00", "2027-12-24": "12:00", "2027-12-31": "12:00" },
    // https://www.sgx.com/securities/trading
    sgx: { "2026-02-16": "12:00", "2026-12-24": "12:00", "2026-12-31": "12:00" },
  },
  coveredYears: {
    // https://www.londonstockexchange.com/equities-trading/business-days
    lse: { lowerBound: 2026, upperBound: 2027 },
    // https://www.cashmarket.deutsche-boerse.com/cash-en/trading/trading-calendar-and-trading-hours
    xetra: { lowerBound: 2026, upperBound: 2026 },
    // https://www.six-group.com/en/products-services/the-swiss-stock-exchange/trading/trading-provisions/regulation.html
    six: { lowerBound: 2026, upperBound: 2027 },
    // https://www.jpx.co.jp/english/corporate/about-jpx/calendar/index.html
    tse: { lowerBound: 2026, upperBound: 2027 },
    // https://www.hkex.com.hk/Services/Circulars-and-Notices/Participant-and-Members-Circulars/SEHK/2026/SEHK_CT_077_2026
    hkex: { lowerBound: 2026, upperBound: 2027 },
    // https://www.sgx.com/securities/trading
    sgx: { lowerBound: 2026, upperBound: 2026 },
    // https://global.krx.co.kr/contents/GLB/05/0501/0501110000/GLB0501110000.jsp
    krx: { lowerBound: 2026, upperBound: 2027 },
    // https://www.nseindia.com/resources/exchange-communication-holidays
    nse: { lowerBound: 2026, upperBound: 2026 },
  },
};
