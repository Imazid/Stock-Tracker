# International markets — sessions, lots, ticks, taxes, Yahoo symbols

Engineering reference for the practice-trading simulator, not legal or tax advice. Read 2026-11-13; every value comes from the source cited.
"Unconfirmed" means no official page confirmed it. Holiday tables are in `TradingCore/Sources/TradingCore/ExchangeHolidays.swift`.

## 1. Regular sessions (local time)

| Venue | Pre-open / opening auction | Continuous trading | Closing auction / after |
|---|---|---|---|
| LSE (SETS) | 07:50–08:00 [3] | 08:00–16:30 | 16:30–16:35 (+random); closing-price crossing to ~16:40 [3] |
| Xetra | 08:55–09:00 (DAX; other shares 09:02/09:04) [6][7] | 09:00–17:30; intraday auction 13:00–13:02 (DAX) | 17:30–17:35; DAX/MDAX/SDAX trade-at-close to 17:40 [6][7] |
| Euronext Paris / Amsterdam | pre-opening call, uncrossing ~09:00:30 (call start unconfirmed) [10] | 09:00–17:30 | pre-close 17:30, uncrossing ~17:35:30, trading-at-last to 17:40 [10][11] |
| SIX | pre-opening from 06:00; open 09:00, 2-min random [12] | 09:00–17:20 | 17:20–17:30 auction; trading-at-last to 17:40 (blue/mid caps) [12] |
| TSE | orders from 08:00 / 12:05 [15] | 09:00–11:30, 12:30–15:25 | pre-closing 15:25–15:30, closing auction (Itayose) at 15:30 [15] |
| HKEX | 09:00–09:30 pre-opening [16] | 09:30–12:00, 13:00–16:00 | CAS 16:00 to random 16:08–16:10 [16] |
| SGX | 08:30–08:58/59 pre-open, non-cancel to 09:00 [21][22] | 09:00–12:00, 13:00–17:00 (12:00–13:00 = pre-open break) | closing routine 17:00–17:06; trade-at-close 17:06–17:16 [21] |
| KRX (KOSPI) | quotes from 08:30 [25] | 09:00–15:20 | closing auction 15:20–15:30 [26]; after-hours sessions to 20:00 [25] |
| NSE (equity) | pre-open 09:00–09:08 [28] | 09:15–15:30 | closing session (at close price) 15:40–16:00 [28] |

Notes and changes:
- **TSE** afternoon now runs to 15:30 with a 15:25–15:30 closing auction; JPX page updated 2024-11-04 [15].
- **HKEX** "Extended Morning Session" 12:00–13:00 applies only to designated *Extended Trading Securities* (Rules 501A–501F). Ordinary shares break for lunch: Rule 501(1) Morning 09:30–12:00, Afternoon 13:00–16:00 [17].
- **SGX** has had a mid-day break again since 2017; the current rulebook and sgx.com both show it [21][22].
- **Xetra** also has retail early trading from 08:00 and retail late trading 17:35/17:40–22:00 (retail auctions) [6]. These are outside the continuous session.
- **KRX** closes on 31 Dec (or the last business day before it) and on election days; "temporary" closures are announced ad hoc [25]. The KRX table lists 2026-06-03 (temporary holiday) and 2026-07-17 [24].
- **Half days:** LSE 24 and 31 Dec close from 12:30 [1]. Xetra's last session, 2026-12-30, has its closing auction call at 14:00 (24 and 31 Dec are closed) [5]. HKEX eves of Lunar New Year, Christmas and New Year are morning only, with CAS from 12:00 [16][18][19]. SGX half days run 09:00–12:00 [21].
- **Euronext half days** on 24 and 31 Dec (2026 and 2027) are confirmed [8], but their times are not. Euronext says 2026–27 half-day hours come in an end-of-year appendix to its trading manuals. Only the 2019–21 notes say "close by 14:05 CET". The timetable file (`/media/1927/download`) returned HTTP 503 [8][9].
- **Not modelled:** NSE Muhurat session (Sun 2026-11-08, times by later circular) [28]. KRX late open on the first trading day and on CSAT day (no official page read).

## 2. Trading units, fractional shares

- **LSE / Euronext / SIX:** no exchange board-lot rule was found in the documents read. Minimum 1 share is assumed (unconfirmed).
- **Xetra:** round lot 1 [6].
- **TSE:** domestic stocks trade in 100-share units, standardised on 2018-10-01 [15]. ETFs differ: 1306 (TOPIX ETF) trades in units of 10 after its 1:10 split on 2026-04-01 [46].
- **HKEX:** the issuer sets the board lot per security. Odd lots go to a separate odd-lot facility, not auto-matched [20]. Look lots up on HKEX securities search ([20] links it); there is no uniform rule.
- **SGX:** the standard board lot was 100. **From 5 Oct 2026** it depends on price: ≤S$10 keeps the existing lot, >S$10–100 trades in 10 units, >S$100 in 1 unit [21]. Reductions are applied by quarterly review: the first batch of 11 stocks (DBS, OCBC, UOB, SGX, Keppel…) moved to 10 shares; the next round is announced Jan 2027 and applied Feb 2027 [21]. ETFs differ, e.g. ES3 board lot = 1 [48].
- **KRX:** 1 share for stocks and ETFs; ELWs 10 [25].
- **NSE:** no official statement on the equity market lot was read (unconfirmed; believed 1 share).
- **Fractional shares:** none of the sources show any of these exchanges matching fractional shares on the order book.

## 3. Tick sizes (one line each)

- LSE: tick tables `TP_n`, assigned per segment/sector in the Business Parameters workbook (Sector Breakdown / Price Format tabs) [3].
- Xetra: ESMA liquidity-band tick regime (bands 1–6 for EU/CH equities); per-ISIN values in "All tradeable instruments" [6].
- Euronext: tick-size controls exist per instrument [10]; the table was not confirmed (presumably ESMA bands, unconfirmed).
- SIX: not confirmed. The Trading Guide was not read for ticks.
- TSE: JPX "Tick Size" tables (TOPIX500 constituents / ETFs with unit 1 / other issues) [15]. **From 1 Mar 2027** ticks follow liquidity (Spread-to-Tick Ratio) instead of TOPIX500 membership [15].
- HKEX: Spread Table, Second Schedule of the Rules of the Exchange [20].
- SGX: Minimum Bid Size table for stocks/REITs/trusts: <S$0.20 → 0.001; 0.20–0.995 → 0.005; ≥1.00 → 0.01 [21].
- KRX: one table for all stocks: <2,000 ₩1; <5,000 ₩5; <20,000 ₩10; <50,000 ₩50; <200,000 ₩100; <500,000 ₩500; ≥500,000 ₩1,000 [25]. KRX's English PDF guide [26] still shows the pre-2023 table.
- NSE: circular 33/2025: <₹250 → 0.01; 250–1,000 → 0.05; >1,000 → 0.10; >5,000 → 0.50; >10,000 → 1.00; >20,000 → 5.00. Reviewed monthly; ETFs excluded [29].

## 4. Transaction taxes on ordinary shares

- **UK:** SDRT 0.5% on electronic purchases, paid by the buyer. Applies to shares in UK-incorporated companies and in foreign companies with a UK share register [31]. AIM and ETF treatment were not covered by that page (unconfirmed).
- **France:** FTT 0.4% on purchases of listed shares of companies with a French head office and market cap >€1bn on 1 Dec of the prior year. Collected by the investment service provider and economically borne by the buyer. Text in force since 2026-01-01 (Loi 2026-103) [32]. DGFiP publishes the company list; the update as of 1 Dec 2025 was published 2025-12-17 [33].
- **Switzerland:** securities transfer tax is 1.5‰ (Swiss securities) / 3‰ (foreign). It is due only when a **Swiss securities dealer** is a party or intermediary: half the tax per non-exempt side. Foreign banks and brokers acting as counterparty are exempt [34]. For a retail trade through a foreign broker it is **unclear**: it depends on whether a Swiss dealer is in the chain.
- **Hong Kong:** stamp duty 0.1% of consideration on every bought note and every sold note, so buyer and seller each pay. Rounded up to HK$1; rate in force since 2023-11-17 [35].
- **Singapore:** no stamp duty on scripless shares transferred electronically by CDP (Stamp Duties (Exempt Record) Rules 2018) [36]. Exchange fees are not taxes: trading fee 0.0075% and clearing fee 0.0325% of value, plus GST [21].
- **Korea (2026):** a KOSPI sale pays STT 0.05% (Enforcement Decree art. 5, in force 2026-01-02) [37] plus rural special tax 0.15% of the transfer value [38]. Total **0.20%, paid by the seller**. KOSDAQ STT is 0.20% [37].
- **India:** STT on delivery trades is 0.1% on the buy (purchaser) and 0.1% on the sell (seller), unchanged by Finance Act 2026. Intraday (non-delivery) sale 0.025%; equity-fund units (ETFs) 0.001% on sale only [30].

## 5. Yahoo Finance identifiers and 6. local index ETF

Suffix and delay come from Yahoo's exchange list [39]. Currency and `exchangeName` come from Yahoo's chart API meta for each ETF below, read 2026-11-13 [40]. The ETF ticker is confirmed on the issuer or exchange page cited.

| Venue | Suffix | Yahoo delay | Currency | `exchangeName` | ETF (index) | Yahoo symbol |
|---|---|---|---|---|---|---|
| LSE | `.L` | 20 min | **`GBp` (pence)** | LSE | iShares Core FTSE 100, ticker ISF, GBP line, RIC ISF.L [41] | `ISF.L` |
| Xetra | `.DE` | 15 min | EUR | GER | iShares Core DAX (DE), Kürzel EXS1 [42] | `EXS1.DE` |
| Euronext Paris | `.PA` | 15 min | EUR | PAR | Amundi CAC 40 UCITS ETF Dist, symbol CAC [43] | `CAC.PA` |
| Euronext Amsterdam | `.AS` | 15 min | EUR | AMS | iShares AEX, symbol IAEX, IE00B0M62Y33 [44] | `IAEX.AS` |
| SIX | `.SW` | 30 min | CHF | EBS | iShares SMI ETF (CH), CSSMI (tracks SMIC, the 18%-capped SMI) [45] | `CSSMI.SW` |
| TSE | `.T` | 20 min | JPY | JPX | NEXT FUNDS TOPIX ETF, code 1306 [46] | `1306.T` |
| HKEX | `.HK` | 15 min | HKD | HKG | Tracker Fund of Hong Kong (HSI), 2800, lot 500 [47] | `2800.HK` |
| SGX | `.SI` | 20 min | SGD | SES | SPDR Straits Times Index ETF, ES3 [48] | `ES3.SI` |
| KRX | `.KS` | 20 min | KRW | KSC | KODEX 200 (KOSPI 200), 069500 [49] | `069500.KS` |
| NSE | `.NS` | real-time | INR | NSI | Nippon India ETF Nifty 50 BeES, NIFTYBEES [50] | `NIFTYBEES.NS` |

Yahoo's exchange list says nothing about pence; the `GBp` comes from the chart API. Yahoo types NIFTYBEES as `EQUITY`, not `ETF`. `C40.PA` is Amundi's CAC 40 **ESG** fund, so use `CAC.PA`.

## Implications for the app

1. **Hours already in `MarketCalendar` match the sources.** Each value is continuous trading through the closing auction: LSE 08:00–16:35, Xetra 09:00–17:35, Euronext 09:00–17:35 (trading-at-last to 17:40 is optional), SIX 09:00–17:30, TSE 09:00–11:30 + 12:30–15:30, HKEX 09:30–12:00 + 13:00–16:10, SGX 09:00–12:00 + 13:00–17:06, KRX 09:00–15:30, NSE 09:15–15:30. For fills at the "close", note that continuous trading actually ends earlier: TSE 15:25, SIX 17:20, KRX 15:20.
2. **Early closes** are stored as the end of continuous trading: LSE 12:30, Xetra 2026-12-30 14:00, HKEX and SGX 12:00. The closing auction after that is not simulated.
3. **Coverage.** LSE, SIX, TSE, HKEX and KRX are complete for 2026–27. Xetra, SGX and NSE are complete for 2026 only: Xetra's 2027-12-30 hours, SGX's 2027 half days (MOM's 2027 holidays exist) and NSE's 2027 list are unpublished. Euronext closures are complete for both years, but it is left out of `coveredYears` because the 24/31 Dec half-day times are unpublished. Re-check each December.
4. **Lot rules to enforce:** TSE 100 for domestic stocks (not ETFs). KRX and Xetra: 1. **SGX is no longer uniformly 100** since 5 Oct 2026; the current "SGX lots of 100" rule rejects valid 10-share DBS orders. Use per-security lots or relax to 1. HKEX lots vary by issuer and need per-security data. Do not enforce lots for LSE, Euronext, SIX or NSE beyond whole shares.
5. **Taxes definite enough to model:** UK 0.5% on buys of UK-incorporated shares; France 0.4% on buys of listed French companies over €1bn (needs the BOFiP list); HK 0.1% on both sides, rounded up to HK$1; Korea 0.20% on KOSPI sells; India 0.1% on both sides for delivery trades (0.001% on ETF sells); Singapore 0 tax (show SGX fees separately). Leave the Swiss transfer tax off, or make it a labelled option; it depends on the broker chain.
6. **Yahoo:** convert `GBp` to GBP (÷100) and check `currency` per listing. Show the stated delay (SIX 30 min; NSE real-time).

## Sources (all read 2026-11-13)

1. LSE business days — https://www.londonstockexchange.com/equities-trading/business-days
2. LSE settlement calendar (updated 28 Jan 2026; source for Jan–May 2026 holidays, cross-checked with gov.uk/bank-holidays.json) — https://www.londonstockexchange.com/content/dam/lse/en_us/documents/guides/settlement-calendar.xlsx
3. LSE Millennium Exchange & TRADEcho Business Parameters — https://www.londonstockexchange.com/content/dam/lse/en_us/documents/technical-library/millennium-exchange-and-tradecho-business-parameters.xlsx
4. GOV.UK bank holidays (England & Wales) — https://www.gov.uk/bank-holidays.json
5. Deutsche Börse trading calendar & hours, 2026/2027 calendar PDFs, "Final trading session 2026" PDF — https://www.cashmarket.deutsche-boerse.com/cash-en/trading/trading-calendar-and-trading-hours
6. Xetra trading parameters as of 1 Dec 2025 — https://www.cashmarket.deutsche-boerse.com/resource/blob/250890/43c50e657b0ff5fb58132fbf6e063517/data/trading-parameters-xetra.pdf
7. Xetra auction schedule — https://www.cashmarket.deutsche-boerse.com/resource/blob/4758656/53415ecf604c18ecf5486d49efcde431/data/Auction%20schedule-deutscheboerse-xetra.pdf
8. Euronext trading hours & holidays (2026 and 2027 tables) — https://www.euronext.com/en/trade/trading-hours-holidays
9. Euronext 2026 holiday calendar info-flash — https://connect2.euronext.com/sites/default/files/2025-11/IF251107CADE%202026%20Holiday%20Calendar%20for%20Euronexts%20Cash%20and%20Derivatives%20markets_1.pdf
10. Euronext AVD equities webinar, Oct 2025 (session timeline, slide 7) — https://www.euronext.com/en/media/14393/download
11. Euronext Market Outage Plan, Dec 2024 (closing auction 17:35) — https://connect2.euronext.com/en/media/1390/download
12. SIX trading hours — https://www.six-group.com/en/products-services/the-swiss-stock-exchange/trading/trading-provisions/trading-hours.html
13. SIX trading calendars 2026/2027 (via the regulation page) — https://www.six-group.com/en/products-services/the-swiss-stock-exchange/trading/trading-provisions/regulation.html
14. JPX market holidays — https://www.jpx.co.jp/english/corporate/about-jpx/calendar/index.html
15. JPX trading rules: hours `01.html`, unit `03.html`, methods `04.html`, tick size `07.html` — https://www.jpx.co.jp/english/equities/trading/domestic/01.html
16. HKEX securities trading hours — https://www.hkex.com.hk/Services/Trading-hours-and-Severe-Weather-Arrangements/Trading-Hours/Securities-Market?sc_lang=en
17. HKEX Rules, Chapter 5 — https://www.hkex.com.hk/-/media/HKEX-Market/Services/Rules-and-Forms-and-Fees/Rules/SEHK/Securities/Rules/Chap_5_eng.pdf
18. HKEX circular CT/075/25 (2026 holidays) — https://www.hkex.com.hk/-/media/HKEX-Market/Services/Circulars-and-Notices/Participant-and-Members-Circulars/SEHK/2025/ce_SEHK_CT_075_2025.pdf
19. HKEX circular CT/077/26 (2027 holidays) — https://www.hkex.com.hk/-/media/HKEX-Market/Services/Circulars-and-Notices/Participant-and-Members-Circulars/SEHK/2026/ce_SEHK_CT_077_2026.pdf
20. HKEX securities market FAQ — https://www.hkex.com.hk/Global/Exchange/FAQ/Securities-Market?sc_lang=en
21. SGX trading (hours, half days, board lot, MBS, fees) — https://www.sgx.com/securities/trading
22. SGX Regulatory Notice 8.2.1 — https://rulebook.sgx.com/rulebook/regulatory-notice-821-trading-hours-market-phases-application-market-phases-and-principles
23. MOM Singapore public holidays (SGX: "follows the Singapore holiday calendar") — https://www.mom.gov.sg/employment-practices/public-holidays
24. KRX market holidays — https://global.krx.co.kr/contents/GLB/05/0501/0501110000/GLB0501110000.jsp
25. KRX KOSPI trading rules (tabs T1 hours/holidays, T3 tick, T4 unit) — https://global.krx.co.kr/contents/GLB/06/0602/0602010201/GLB0602010201.jsp
26. KRX Guide to Trading in the Korean Stock Market — https://global.krx.co.kr/contents/GLB/01/0109/0109000000/guide_to_trading_in_the_korean_stock_market.pdf
27. NSE holidays (Equities, 2026) — https://www.nseindia.com/resources/exchange-communication-holidays
28. NSE market timings — https://www.nseindia.com/static/market-data/market-timings
29. NSE circular 33/2025, tick size — https://nsearchives.nseindia.com/content/circulars/CMTR67133.pdf
30. NSE circular 02/2026, STT rates — https://nsearchives.nseindia.com/content/circulars/FATAX73524.pdf
31. GOV.UK, Tax when you buy shares — https://www.gov.uk/tax-buy-shares
32. Légifrance, CGI art. 235 ter ZD — https://www.legifrance.gouv.fr/codes/id/LEGISCTA000025515885
33. BOFiP, FTT list update at 1 Dec 2025 — https://bofip.impots.gouv.fr/bofip/14873-PGP.html/ACTU-2025-00185
34. ESTV, Umsatzabgabe — https://www.estv.admin.ch/estv/de/home/bundesabgaben/stempelabgaben/sta-fachinformationen/umsatzabgabe.html
35. GovHK stamp duty rates — https://www.gov.hk/en/residents/taxes/stamp/stamp_duty_rates.htm
36. IRAS stamp duty basics for shares — https://www.iras.gov.sg/taxes/stamp-duty/for-shares/basics-of-stamp-duty-for-shares/learning-the-basics-for-shares
37. Korea STT Enforcement Decree art. 5 — https://www.law.go.kr/법령/증권거래세법시행령/제5조
38. Korea Rural Special Tax Act art. 5 — https://www.law.go.kr/법령/농어촌특별세법/제5조
39. Yahoo Finance exchanges and data providers — https://help.yahoo.com/kb/SLN2310.html
40. Yahoo chart API (meta.currency / exchangeName) — https://query2.finance.yahoo.com/v8/finance/chart/ISF.L
41. iShares Core FTSE 100 listings — https://www.ishares.com/uk/individual/en/products/251795/ishares-ftse-100-ucits-etf-inc-fund
42. Deutsche Börse, iShares Core DAX — https://live.deutsche-boerse.com/etf/ishares-core-dax-ucits-etf-de-eur-acc
43. Euronext, Amundi CAC 40 UCITS ETF Dist — https://live.euronext.com/en/product/etfs/FR0007052782-XPAR
44. Euronext instrument search "IAEX" — https://live.euronext.com/en/search_instruments/IAEX
45. iShares SMI ETF (CH) — https://www.ishares.com/ch/individual/en/products/261154/ishares-smi-ch-fund
46. NEXT FUNDS TOPIX ETF (1306) — https://nextfunds.jp/en/lineup/1306/
47. Tracker Fund of Hong Kong, Product Key Facts — https://www.trahk.com.hk/content/dam/hsvm/trahk/fund_docs/offering/trahk_eng.pdf
48. SSGA SPDR STI ETF (ES3) — https://www.ssga.com/sg/en/institutional/etfs/state-street-spdr-straits-times-index-etf-es3
49. Samsung KODEX 200 — https://www.samsungfund.com/eng/etf/product/view.do?id=2ETF01
50. Nippon India ETF Nifty 50 BeES — https://mf.nipponindiaim.com/FundsAndPerformance/Pages/NipponIndia-ETF-Nifty-50-BeES.aspx
