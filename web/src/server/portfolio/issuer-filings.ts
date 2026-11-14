// Dated SEC filing references used when a live EDGAR lookup is unavailable.
// Each venue:ticker is tied to the legal issuer shown in the linked filing.
export const issuerFilings: Record<string, readonly [issuer: string, sic: string, incorporation: string, filedOn: string, filing: string]> = {
  "asx:BHP": ["BHP Group", "1000", "C3", "2026-08-18", "811809/000119312526354647/0001193125-26-354647-index.htm"],
  "us:BHP": ["BHP Group", "1000", "C3", "2026-08-18", "811809/000119312526354647/0001193125-26-354647-index.htm"],
  "asx:CBA": ["Commonwealth Bank of Australia", "6029", "C3", "2026-08-13", "8565/000119312526347772/0001193125-26-347772-index.htm"],
  "us:AAPL": ["Apple", "3571", "CA", "2026-11-03", "320193/000032019326000026/0000320193-26-000026-index.html"],
  "us:ASML": ["ASML Holding", "3559", "P7", "2026-02-25", "937966/000162828026011378/0001628280-26-011378-index.htm"],
  "euronextAmsterdam:ASML": ["ASML Holding", "3559", "P7", "2026-02-25", "937966/000162828026011378/0001628280-26-011378-index.htm"],
  "us:GOOG": ["Alphabet", "7370", "DE", "2026-10-29", "1652044/000165204426000084/0001652044-26-000084-index.html"],
  "us:GOOGL": ["Alphabet", "7370", "DE", "2026-10-29", "1652044/000165204426000084/0001652044-26-000084-index.html"],
  "us:JPM": ["JPMorgan Chase", "6021", "DE", "2026-11-03", "19617/000162828026069523/0001628280-26-069523-index.htm"],
  "us:META": ["Meta Platforms", "7370", "DE", "2026-10-22", "1326801/000162828026066773/0001628280-26-066773-index.html"],
  "us:MSFT": ["Microsoft", "7372", "WA", "2026-10-28", "789019/000119312526436133/0001193125-26-436133-index.htm"],
  "us:NVDA": ["NVIDIA", "3674", "DE", "2026-08-26", "1045810/000104581026000075/0001045810-26-000075-index.htm"],
  "us:TSLA": ["Tesla", "3711", "TX", "2026-07-23", "1318605/000162828026049270/0001628280-26-049270-index.htm"],
  "us:TSM": ["Taiwan Semiconductor Manufacturing", "3674", "F5", "2026-04-16", "1046179/000162828026025362/0001628280-26-025362-index.html"],
  "us:VOD": ["Vodafone Group", "4812", "X0", "2026-05-22", "839923/000119312526235425/0001193125-26-235425-index.htm"],
  "lse:VOD": ["Vodafone Group", "4812", "X0", "2026-05-22", "839923/000119312526235425/0001193125-26-235425-index.htm"],
};
