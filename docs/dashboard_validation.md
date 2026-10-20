# Dashboard validation (Phase 6)

The sign-off checklist for the four-page Data Studio report built from
[dashboard_spec.md](dashboard_spec.md). For every component it lists the value the report must
show, in the format Data Studio shows it, with an empty **Observed** and **Match?** cell for you to
fill in while you click through the report. The report is done when every row matches
(spec section 6).

Where the numbers come from: [`sql/07_dashboard_validation.sql`](../sql/07_dashboard_validation.sql)
computes each component from the **same MART table**, with the **same aggregation, card filter
and `SUM(x) / SUM(y)` calculated field** as the spec (section 0.5), under the same filter. It then
checks every figure against an independent reference: the dbt seeds made from the raw CSV files
without Snowflake, the publisher's channel totals, the Phase 4 evidence numbers, or a
recomputation from the STAGING views. Its output is
[`evidence/07_dashboard_validation.txt`](evidence/07_dashboard_validation.txt) (cited as `07 [n]`,
statement n), and every expected value below is copied from that file.

Component IDs (P1-01, P2-06, ...), data source codes (`MM`, `COH`, `CH`, `CAMP`, `LQ`, `FUN`, `DAILY`)
and the spot-check states (2024, video, the campaign `Affiliate 2024 080`) are those of the spec, so
one set of filter settings checks both documents.

Status (2026-10-14): the SQL ran as `CRM_TRANSFORMER` on the deployed dbt build (the Phase 5
full build plus the Phase 6 funnel mart, the tables exported to [exports/](../exports/README.md)): 27 statements,
359 PASS rows, 0 FAIL, 5 INFO rows (diagnostics without a reference) and 3 NOTE
rows (cells on a rounding midpoint, see [Rounding](#rounding-the-last-digit)). Every Expect value
in dashboard_spec.md equals the SQL result. The one display caveat is a rounding midpoint: the
cost per purchase of `Affiliate 2024 045` (P4-11 row 5, P4-12 row 10) may show 119.81 instead of
119.82.

Both passes are done (2026-10-18): pass 1 on the live Snowflake report and pass 2 on the public
Google Sheets copy; every value read matched. What was read in each pass is recorded in the build
logs and summarised in the [sign-off](#sign-off); the per-component Observed columns were not
filled cell by cell.

## Contents

- [How to use this checklist](#how-to-use-this-checklist)
- [Display formats](#display-formats)
- [Gate tests](#gate-tests)
- [Page 1: Marketing Overview](#page-1-marketing-overview)
- [Page 2: Conversion Funnel](#page-2-conversion-funnel)
- [Page 3: Lead Quality & CRM](#page-3-lead-quality--crm)
- [Page 4: Marketing Efficiency & ROAS](#page-4-marketing-efficiency--roas)
- [Build log, pass 1 (live Snowflake)](#build-log-pass-1-live-snowflake)
- [Build log, pass 1b: polish on the final report](#build-log-pass-1b-polish-on-the-final-report-live-snowflake)
- [Build log, pass 2: the Google Sheets copy](#build-log-pass-2-the-google-sheets-copy)
- [Sign-off](#sign-off)
- [Reproduce the expected values](#reproduce-the-expected-values)

## How to use this checklist

1. Build the report from the spec, then open it in **View** mode. Reloading the report link
   resets every filter.
2. Check each section in the **default** state first, then set each filter state, check, and
   reset it. The states are the spot checks of the spec:

   | State | How to set it | What must change |
   |---|---|---|
   | default | Nothing: date range 2023-01-01 to 2025-12-31 (the report default), all channels, no campaign, no cross-filter. | |
   | video | Channel drop-down: tick **video** only. | Every chart, on every page (if gate G2 passed). |
   | 2024 | Date range control: **Fixed**, Jan 1, 2024 to Dec 31, 2024. | Only charts on a source with a date field: `MM`, `COH`, `DAILY`. |
   | 2025 | Date range control: Jan 1, 2025 to Dec 31, 2025. Used only where a row says 2025. | As 2024. |
   | campaign | The page's Campaign drop-down: `Affiliate 2024 080`. | Only the campaign charts of that page (`CAMP`). |

   A line marked **unchanged** expects the default value in that state: the chart's source has no
   date field (`CH`, `CAMP`, `LQ`, `FUN`). In Snowflake, `CH`, `LQ` and `FUN` have no date column at
   all, and `CAMP`'s three become Text in the data source (spec 0.4, D3; checked in `07 [6]`). A value
   that moves there means a date dimension slipped in (for `CAMP`: spec decision D3 was missed, see
   [P1-11](#p1-11-campaign-performance-table)).
3. Write what Data Studio shows in **Observed** and `yes` or `no` in **Match?**. A value matches when
   it is equal at the precision shown. For the few cells listed under
   [Rounding](#rounding-the-last-digit), either of two values matches.
4. On a mismatch, work through the usual causes in the spec (section 6, "If a value differs"). Do not
   change a formula to make a number fit. Record the mismatch, and Claude checks the SQL side.

## Display formats

The **Expected** columns use the formats the spec sets (section 1.6):

- **Counts:** 0 decimals with thousands separators, e.g. `261,684`.
- **Money:** 2 decimals, no currency symbol (decision D8), e.g. `4,523,050.02`.
- **Ratios, scores and days:** 2 decimals, e.g. ROAS `4.77`, cost per lead `17.28`.
- **Percent fields:** 2 decimals, e.g. `0.151694` shows as `15.17%`.

### Compact numbers and full precision

New scorecards may start with **Compact numbers** on. The spec turns it off, so every KPI card
shows the exact value. With it on, the same card shows an abbreviation:

| Card | Exact (Compact numbers off) | Compact numbers on, default precision | Compact, Decimal precision 2 |
|---|---:|---:|---:|
| P1-02 Total spend | 4,523,050.02 | 4.5M | 4.52M |
| P1-03 Total impressions | 436,844,819 | 436.8M | 436.84M |
| P1-04 Total clicks | 7,102,319 | 7.1M | 7.10M |
| P1-05 Total leads | 261,684 | 261.7K | 261.68K |
| P1-06 Conversions (booked) | 39,696 | 39.7K | 39.70K |

Both compact columns are printed by `07 [8]` (`COMPACT`, `COMPACT_2DP`); `07 [24]` prints them for
P4-01 and P4-02.
With **Currency (USD)** as the field type, Data Studio adds a dollar sign (`$4.5M`). The spec
keeps money as *Number* (D8), so no symbol is expected.

To compare a card at full precision, select it, then open **STYLE**:

1. Untick **Compact numbers**.
2. Set **Decimal precision** to the value in the spec (0 for counts, 2 otherwise). Set it to 4 for a
   stricter check against the `VALUE` column of the evidence: for example, the conversion rate then
   shows `15.1694%`, and the evidence prints `0.151694`.

The 6-decimal `VALUE` and `REFERENCE` columns of the evidence are the exact figures. Data Studio's
**Auto** precision may show fewer digits than the Expected column; that is a display setting, not
a mismatch.

### Rounding: the last digit

Data Studio, like most BI tools, calculates with binary floating-point numbers and rounds what it
shows. This checklist rounds the exact decimal half away from zero. The two agree except when a
value lies exactly on a midpoint, such as `x.xx5`. Block 18 (`07 [27]`) tested all 813 table and
chart cells for this. The `NEAR_HALF` columns of the card blocks tested every KPI card, including
both years, the change and the absolute change of the 2025 vs 2024 strip (`07 [9]`). They found
five midpoint cells and no card:

| Cell | Exact value | Expected (half up) | Data Studio may show | Where it appears |
|---|---:|---:|---:|---|
| Cost per purchase of `Affiliate 2024 045` (CMP0045) | 10,543.72 / 88 = 119.815 | 119.82 | 119.81 | P4-11 row 5 (default); P4-12 row 10 (default) |
| Cost per purchase of `Video 2024 024` (CMP0024) | 66,524.17 / 146 = 455.645 | 455.65 | 455.64 | P4-11 row 8 (video); P4-12 row 7 (video) |
| Cost per purchase of `Paid Social 2024 092` (CMP0092) | 49,872.48 / 224 = 222.645 | 222.65 | 222.64 | not in the rows listed below (further down P4-11/P4-12) |
| Lead conversion rate of `Display 2024 003` (CMP0003) | 240 / 1,536 = 15.625% | 15.63% | 15.62% | not in the rows listed below (further down P1-11/P2-14) |
| Lead conversion rate, video cohort 2025-07 | 75 / 480 = 15.625% | 15.63% | 15.62% | P2-09 in state video |

Which neighbour Data Studio shows depends on how its display rounds, which Google does not
document:

- **The three costs.** The stored binary double of 119.815 is 119.81499999999999773, and that of
  455.645 is 455.64499999999998181: a display that rounds the double shows 119.81 and 455.64. The
  double of 222.645 is 222.64500000000001023, which rounds up. A display that first takes the
  shortest decimal form (`119.815`) and rounds it half up shows the three Expected values; one that
  rounds it half to even shows 119.82, 455.64 and 222.64.
- **The two percent cells are exact ties.** 0.15625 is exact in binary, so 15.625% sits exactly
  on the midpoint and the result depends only on the tie rule: half up gives 15.63%, half to even
  (the default of Java's `DecimalFormat` and of Python) gives 15.62%.

For these five cells, both values in the table count as a match. The spec's Expect line for P4-12
row 10 says 119.82, which is the exact value rounded half up. P1-11 shows CMP0024 too, but it has
no cost per purchase column.

### Other display notes

- **Comparison cards** (P1-K1..P1-K5) show the change with one decimal next to an arrow, for example
  `-44.5%` or a down arrow and `44.5%`. The sign may be the arrow alone.
- **No previous stage.** The first funnel stage has no stage conversion. The funnel label may show
  `100%` or nothing, and the stage table shows `-` (null).
- **Months without video leads** (P2-09, state video) are line breaks, not 0% (spec: Missing data
  = Line Breaks).
- **Month labels.** Month axes show *Year Month* labels (e.g. `Oct 2024`). The tables below give the
  month as `2024-10` and the label.

## Gate tests

### G2: one channel control across the seven sources

On the spec's `TEST` page (section 1.4), each scorecard shows `SUM(LEADS)` of one data source
(`FUN`: the `Leads` row of a `STAGE` table). Select **video** in the drop-down: all seven must
change. Evidence `07 [7]`.

| Check | Source | All channels | video | Observed (all) | Observed (video) | Match? |
|---|---|---:|---:|---|---|---|
| a | `MM` | 261,684 | 25,799 | reported OK by the user | 25,799 | yes |
| b | `COH` | 261,684 | 25,799 | reported OK by the user | 25,799 | yes |
| c | `CAMP` | 261,684 | 25,799 | reported OK by the user | 25,799 | yes |
| d | `LQ` | 261,684 | 25,799 | reported OK by the user | 25,799 | yes |
| e | `DAILY` | 261,684 | 25,799 | reported OK by the user | 25,799 | yes |
| f | `FUN (row Leads)` | 261,684 | 25,799 | reported OK by the user | 25,799 | yes |
| g | `CH` | 261,684 | 25,799 | reported OK by the user | 25,799 | yes |

Record the outcome here and in the sign-off: G2 passed without overrides / passed after the
`CHANNEL` ID overrides / failed (fallback page-level controls, spec 1.5).

**Result, 2026-10-14 (pass 1, live Snowflake): G2 passed without overrides.** With **video**
selected in a drop-down bound to `CH.CHANNEL`, all six scorecards (`MM`, `COH`, `CAMP`, `LQ`,
`DAILY`, `CH`) showed 25,799 and the `FUN` table's `Leads` row showed 25,799 (screenshot seen in
the build session). The same `FUN` table also showed the full video funnel: Impressions
55,205,469, Clicks 492,490, Leads 25,799, Converted leads 3,933, Purchases 1,638, which equal the
video row of `MART_CHANNEL_PERFORMANCE`. So the Snowflake connector gives `CHANNEL` the same field
ID in every source, and the spec's single report-level channel drop-down (D5) applies.

**Result, 2026-10-18 (pass 2, Google Sheets snapshot): G2 passed without overrides.** No `CHANNEL`
field-ID override was added. With **video** ticked in the report-level drop-down (bound to
`CH.CHANNEL`), every source changed: P1-01 24 (`CH`), P1-02..P1-06 (`MM`), P1-07 15.24% (`COH`),
the P1-11 summary 828,094.54 / 25,799 / 3,933 (`CAMP`), the P2-07 funnel rows 55,205,469 ... 1,638
(`FUN`), P2-12 406 (`DAILY`) and P3-01..P3-05 (`LQ`). The Sheets connector gives a field the same ID
in every Sheets source with the same column (its IDs look derived from the column name, e.g.
`LEADS` = `_72307831_`), so `CHANNEL` matches across the seven sources.

### G1: the report-level date control on other pages

Set the date range on page 1 to 2025-01-01..2025-12-31, then open page 2. P2-09 must show only the
12 months of 2025: the first is `Jan 2025` at 15.36%, the last `Dec 2025` at 16.92%
(`07 [18]`). If it still shows 36 months, use the spec's fallback (page-level copies of the control).

## Page 1: Marketing Overview

### KPI cards P1-01..P1-07

Sources `DAILY`, `MM`, `COH`; filters date, channel. Evidence `07 [8]`: each value equals the seed
totals (default), the seed roll-up and the publisher's spend (video), and the Phase 4 year values
(2024).

| ID | Card | State | Expected | Compact on | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- |
| P1-01 | Total campaigns | default | 120 |  |  |  |
| P1-01 | Total campaigns | video | 24 |  |  |  |
| P1-01 | Total campaigns | 2024 | 60 |  |  |  |
| P1-02 | Total spend | default | 4,523,050.02 | 4.5M |  |  |
| P1-02 | Total spend | video | 828,094.54 | 828.1K |  |  |
| P1-02 | Total spend | 2024 | 1,971,198.34 | 2.0M |  |  |
| P1-03 | Total impressions | default | 436,844,819 | 436.8M |  |  |
| P1-03 | Total impressions | video | 55,205,469 | 55.2M |  |  |
| P1-03 | Total impressions | 2024 | 175,148,406 | 175.1M |  |  |
| P1-04 | Total clicks | default | 7,102,319 | 7.1M |  |  |
| P1-04 | Total clicks | video | 492,490 | 492.5K |  |  |
| P1-04 | Total clicks | 2024 | 3,092,049 | 3.1M |  |  |
| P1-05 | Total leads | default | 261,684 | 261.7K |  |  |
| P1-05 | Total leads | video | 25,799 | 25.8K |  |  |
| P1-05 | Total leads | 2024 | 107,371 | 107.4K |  |  |
| P1-06 | Conversions (booked) | default | 39,696 | 39.7K |  |  |
| P1-06 | Conversions (booked) | video | 3,933 | 3.9K |  |  |
| P1-06 | Conversions (booked) | 2024 | 16,148 | 16.1K |  |  |
| P1-07 | Conversion rate | default | 15.17% |  |  |  |
| P1-07 | Conversion rate | video | 15.24% |  |  |  |
| P1-07 | Conversion rate | 2024 | 15.20% |  |  |  |

### P1-K1..P1-K5: "2025 vs 2024" strip

Fixed date range 2025, comparison **Previous year**; follows the channel control only. Evidence
`07 [9]`. *Change* is the comparison label; *Absolute* is what **Show absolute change** shows
instead.

| ID | Card | Channels | 2025 (card) | 2024 | Change | Absolute | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P1-K1 | Active campaigns | all channels | 35 | 60 | -41.7% | -25 |  |  |
| P1-K1 | Active campaigns | video | 8 | 12 | -33.3% | -4 |  |  |
| P1-K2 | Spend | all channels | 1,093,589.27 | 1,971,198.34 | -44.5% | -877,609.07 |  |  |
| P1-K2 | Spend | video | 129,218.74 | 503,790.97 | -74.4% | -374,572.23 |  |  |
| P1-K3 | Leads | all channels | 66,764 | 107,371 | -37.8% | -40,607 |  |  |
| P1-K3 | Leads | video | 3,889 | 15,733 | -75.3% | -11,844 |  |  |
| P1-K4 | Conversions (booked) | all channels | 10,769 | 16,148 | -33.3% | -5,379 |  |  |
| P1-K4 | Conversions (booked) | video | 638 | 2,435 | -73.8% | -1,797 |  |  |
| P1-K5 | Lead conversion rate | all channels | 15.18% | 15.20% | -0.1% | -0.02% |  |  |
| P1-K5 | Lead conversion rate | video | 15.61% | 15.43% | 1.1% | 0.18% |  |  |

**Trap:** the comparison must be **Previous year**. *Previous period* would compare with the 365
days before the range, 2024-01-02..2024-12-31 (2024 has 366 days). Monthly data is keyed on the
1st, so January 2024 drops out, and the cards would show spend -40.8%, leads -33.8% and
conversions -28.2% instead.

### P1-08 Monthly marketing spend trend

Combo chart on `MM`: bars `Spend`, line `Campaigns in flight`, 36 months. Evidence `07 [10]` (all 36
months, both states), totals `07 [11]`.

Default:

| Month | Spend | Campaigns in flight | Observed | Match? |
| --- | --- | --- | --- | --- |
| 2023-01 (Jan 2023) | 23,686.55 | 3 |  |  |
| 2024-09 (Sep 2024) | 205,363.34 | 20 |  |  |
| 2024-10 (Oct 2024) | 219,378.73 | 18 |  |  |
| 2025-12 (Dec 2025) | 807.04 | 1 |  |  |

- 36 bars, `Jan 2023` to `Dec 2025` (36 months). Peak spend `Oct 2024`; most campaigns in
  flight `Sep 2024` (20).
- **video:** still 36 months; 31 have video spend, the others show 0. Spot checks:

| Month | Spend (video) | Campaigns in flight (video) | Observed | Match? |
| --- | --- | --- | --- | --- |
| 2023-01 (Jan 2023) | 0.00 | 0 |  |  |
| 2024-05 (May 2024) | 82,295.40 | 6 |  |  |
| 2025-10 (Oct 2025) | 0.00 | 0 |  |  |

- **2024:** 12 bars, `Jan 2024` to `Dec 2024`, the same values as in the default state. The bars
  add up to 1,971,198.34.

### P1-09 Leads by channel

Horizontal bars on `MM`, sorted by leads descending. Evidence `07 [12]`.

| Channel | Default (bar order) | 2024 (bar order) | Observed | Match? |
| --- | --- | --- | --- | --- |
| affiliate | 67,849 (1) | 28,727 (2) |  |  |
| paid_search | 65,268 (2) | 29,566 (1) |  |  |
| paid_social | 57,619 (3) | 21,435 (3) |  |  |
| display | 45,149 (4) | 11,910 (5) |  |  |
| video | 25,799 (5) | 15,733 (4) |  |  |

**video:** a single bar, video 25,799.

### P1-10 Monthly conversion trend

Time series on `MM`: `Conversions (trial or purchase)` and `of which purchases`, booked by
conversion date. Evidence `07 [10]`, totals `07 [11]`.

| Month | Conversions | of which purchases | Observed | Match? |
| --- | --- | --- | --- | --- |
| 2023-01 (Jan 2023) | 110 | 48 |  |  |
| 2024-10 (Oct 2024) | 1,830 | 749 |  |  |
| 2025-12 (Dec 2025) | 61 | 22 |  |  |

- **video:** e.g. `May 2024` 429 / 173; the series add up to
  3,933 / 1,638.
- **2024:** 12 points; they add up to 16,148 / 6,746 (P1-06 in state 2024).

### P1-11 Campaign performance table

Table on `CAMP`, sorted by `SPEND` descending, 10 rows per page, summary row on. Evidence `07 [13]`
(`P1-11`), checks `07 [14]`. Each row equals the seed campaign at the same position.

Default (120 campaigns, 12 pages):

| Row | Campaign | Channel | Objective | Spend | Leads | Converted | Attributed revenue | Cost/lead | Lead conv. rate | ROAS | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `Display 2024 093` | display | awareness | 72,153.85 | 3,273 | 478 | 250,142.87 | 22.05 | 14.60% | 3.47 |  |  |
| 2 | `Paid Search 2024 021` | paid_search | awareness | 71,337.50 | 4,727 | 691 | 380,892.89 | 15.09 | 14.62% | 5.34 |  |  |
| 3 | `Paid Social 2025 102` | paid_social | awareness | 67,070.47 | 3,836 | 571 | 270,077.02 | 17.48 | 14.89% | 4.03 |  |  |
| 4 | `Paid Social 2024 107` | paid_social | awareness | 66,794.72 | 4,138 | 611 | 316,085.27 | 16.14 | 14.77% | 4.73 |  |  |
| 5 | `Paid Search 2024 041` | paid_search | acquisition | 66,691.10 | 1,960 | 307 | 176,741.68 | 34.03 | 15.66% | 2.65 |  |  |
| 6 | `Video 2024 024` | video | acquisition | 66,524.17 | 2,111 | 319 | 179,567.16 | 31.51 | 15.11% | 2.70 |  |  |
| 7 | `Display 2023 073` | display | awareness | 64,824.15 | 3,112 | 487 | 289,502.55 | 20.83 | 15.65% | 4.47 |  |  |
| 8 | `Paid Social 2023 117` | paid_social | awareness | 64,353.11 | 3,912 | 568 | 315,925.45 | 16.45 | 14.52% | 4.91 |  |  |
| 9 | `Display 2023 008` | display | lead_gen | 62,684.63 | 2,969 | 462 | 251,896.65 | 21.11 | 15.56% | 4.02 |  |  |
| 10 | `Affiliate 2024 060` | affiliate | acquisition | 62,309.32 | 5,104 | 768 | 417,738.92 | 12.21 | 15.05% | 6.70 |  |  |
| summary | Summary row |  |  | 4,523,050.02 | 261,684 | 39,696 | 21,561,839.01 | 17.28 | 15.17% | 4.77 |  |  |

video (24 campaigns, 3 pages), first rows and summary:

| Row | Campaign | Channel | Objective | Spend | Leads | Converted | Attributed revenue | Cost/lead | Lead conv. rate | ROAS | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `Video 2024 024` | video | acquisition | 66,524.17 | 2,111 | 319 | 179,567.16 | 31.51 | 15.11% | 2.70 |  |  |
| 2 | `Video 2024 079` | video | lead_gen | 62,230.93 | 1,932 | 292 | 137,737.16 | 32.21 | 15.11% | 2.21 |  |  |
| 3 | `Video 2024 064` | video | lead_gen | 55,178.97 | 1,687 | 247 | 128,190.29 | 32.71 | 14.64% | 2.32 |  |  |
| summary | Summary row |  |  | 828,094.54 | 25,799 | 3,933 | 2,087,554.22 | 32.10 | 15.24% | 2.52 |  |  |

- **2024: unchanged** (all 120 campaigns): `CAMP` has no date field (D3). If the table shows
  50 campaigns in 2024, the date fields of `CAMP` are still *Date*: the table then
  shows the campaigns *started* in 2024 (not the 60 that ran). Fix the types (spec 0.4).
- **Summary row trap:** if the summary row shows a ROAS of 626.44 (a sum) or
  5.22 (an average), the column is the stored `ROAS`, not the calculated
  *ROAS (attributed)*. The right summary is 4.77.

### P1-12 Campaign drop-down

Select `Affiliate 2024 080`. P1-11 shows one row, and the summary row shows the same values. P1-01 to
P1-10 do not change. Evidence `07 [26]`:

| Column | Expected | Observed | Match? |
| --- | --- | --- | --- |
| SPEND | 17,904.18 |  |  |
| LEADS | 2,644 |  |  |
| CONVERTED_LEADS | 394 |  |  |
| REVENUE | 232,990.96 |  |  |
| Cost per lead | 6.77 |  |  |
| Lead conversion rate | 14.90% |  |  |
| ROAS (attributed) | 13.01 |  |  |
| P1-01..P1-10 (the rest of the page) | unchanged: the default values above |  |  |

## Page 2: Conversion Funnel

### KPI cards P2-01..P2-05

Source `CH` (full range); filter channel. Evidence `07 [15]`.

| ID | Card | State | Expected | Observed | Match? |
| --- | --- | --- | --- | --- | --- |
| P2-01 | CTR | default | 1.63% |  |  |
| P2-01 | CTR | video | 0.89% |  |  |
| P2-02 | Click-to-lead rate | default | 3.68% |  |  |
| P2-02 | Click-to-lead rate | video | 5.24% |  |  |
| P2-03 | Lead conversion rate | default | 15.17% |  |  |
| P2-03 | Lead conversion rate | video | 15.24% |  |  |
| P2-04 | Cost per lead | default | 17.28 |  |  |
| P2-04 | Cost per lead | video | 32.10 |  |  |
| P2-05 | Cost per conversion | default | 113.94 |  |  |
| P2-05 | Cost per conversion | video | 210.55 |  |  |

**2024: unchanged.** Every card keeps its default value: `CH` has no date column (`07 [6]`).

### P2-06 Funnel chart and P2-07 Funnel stage table

Source `FUN`, stages sorted by `STAGE_ORDER`. The funnel label "% of previous" and the table's
`% of previous stage` are the same value. Evidence `07 [16]`: the stage values and both
denominators (`PREV_STAGE_VALUE`, `TOP_OF_FUNNEL_VALUE`) equal the seed totals, for all channels
and for video.

| Stage | Value | % of previous stage | % of impressions (2 dp) | % of impressions (4 dp) | video: value | video: % of previous | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Impressions | 436,844,819 | - (none) | 100.00% | 100.0000% | 55,205,469 | - (none) |  |  |
| Clicks | 7,102,319 | 1.63% | 1.63% | 1.6258% | 492,490 | 0.89% |  |  |
| Leads | 261,684 | 3.68% | 0.06% | 0.0599% | 25,799 | 5.24% |  |  |
| Converted leads | 39,696 | 15.17% | 0.01% | 0.0091% | 3,933 | 15.24% |  |  |
| Purchases | 16,691 | 42.05% | 0.00% | 0.0038% | 1,638 | 41.65% |  |  |

- **2024: unchanged** (`FUN` has no date field).
- If the funnel's percentage type is set to *% of max* instead, the labels are the "% of
  impressions (2 dp)" column. The spec uses *% of previous*.

### P2-08 Channel funnel comparison

Table on `CH`, sorted by *Lead conversion rate* descending, no summary row. The 95% bounds are the
stored `LCR_CI_LOW` / `LCR_CI_HIGH`. Evidence `07 [17]`.

| Channel | Impressions | Clicks | CTR | Leads | Click-to-lead | Converted | Lead conv. rate | 95% CI | Cost/lead | Cost/conv. | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| paid_search | 49,837,405 | 1,740,314 | 3.49% | 65,268 | 3.75% | 10,019 | 15.35% | 15.08% to 15.63% | 13.74 | 89.54 |  |  |
| affiliate | 95,314,042 | 2,386,856 | 2.50% | 67,849 | 2.84% | 10,352 | 15.26% | 14.99% to 15.53% | 12.64 | 82.87 |  |  |
| video | 55,205,469 | 492,490 | 0.89% | 25,799 | 5.24% | 3,933 | 15.24% | 14.81% to 15.69% | 32.10 | 210.55 |  |  |
| paid_social | 89,520,215 | 1,602,785 | 1.79% | 57,619 | 3.59% | 8,648 | 15.01% | 14.72% to 15.30% | 17.09 | 113.87 |  |  |
| display | 146,967,688 | 879,874 | 0.60% | 45,149 | 5.13% | 6,744 | 14.94% | 14.61% to 15.27% | 21.16 | 141.65 |  |  |

**video:** only the video row. **2024: unchanged.**

### P2-09 Lead conversion rate by lead cohort month

Time series on `COH`, dimension `COHORT_MONTH` (the month the leads were created). Evidence `07 [18]`
(all 36 months, both channel states).

| Month | Default | video | Observed | Match? |
| --- | --- | --- | --- | --- |
| 2023-01 (Jan 2023) | 16.00% | blank (line break) |  |  |
| 2023-04 (Apr 2023) | 15.31% | 11.03% |  |  |
| 2024-08 (Aug 2024) | 14.99% | 17.06% |  |  |
| 2025-01 (Jan 2025) | 15.36% | 16.18% |  |  |
| 2025-09 (Sep 2025) | 13.94% | 14.89% |  |  |
| 2025-12 (Dec 2025) | 16.92% | blank (line break) |  |  |

- Default: 36 points between 13.94% (`Sep 2025`, the lowest) and 16.92% (`Dec 2025`, the highest:
  11 of 65 leads).
- **video:** 31 points between 11.03% (`Apr 2023`) and 17.06% (`Aug 2024`); line breaks at
  `Jan 2023`, `Feb 2023`, `Oct 2025`, `Nov 2025`, `Dec 2025` (no video leads).
- **2024:** 12 points, `Jan 2024` 15.02% to `Dec 2024` 15.62%. **2025:** 12 points, `Jan 2025`
  15.36% to `Dec 2025` 16.92% (gate G1).

### P2-10..P2-12 Conversion time cards

P2-10 and P2-11 on `COH` (by lead cohort month), P2-12 on `DAILY` with the card filter
`After flight` (by conversion date). Evidence `07 [19]`.

| ID | Card | State | Expected | Observed | Match? |
| --- | --- | --- | --- | --- | --- |
| P2-10 | Mean days to convert | default | 10.51 |  |  |
| P2-10 | Mean days to convert | video | 10.38 |  |  |
| P2-10 | Mean days to convert | 2024 | 10.51 |  |  |
| P2-10 | Mean days to convert | 2025 | 10.51 |  |  |
| P2-11 | Converted in later mth | default | 34.45% |  |  |
| P2-11 | Converted in later mth | video | 34.05% |  |  |
| P2-11 | Converted in later mth | 2024 | 35.12% |  |  |
| P2-11 | Converted in later mth | 2025 | 32.85% |  |  |
| P2-12 | Conversions after end | default | 4,716 |  |  |
| P2-12 | Conversions after end | video | 406 |  |  |
| P2-12 | Conversions after end | 2024 | 2,065 |  |  |
| P2-12 | Conversions after end | 2025 | 1,392 |  |  |

### P2-13 Campaign drop-down

Select `Affiliate 2024 080` in the page-2 drop-down. P2-14 shows one row, and its summary row shows
the same values. P2-01 to P2-12 do not change. Evidence `07 [26]`:

| Column | Expected | Observed | Match? |
| --- | --- | --- | --- |
| P2-14 LEADS | 2,644 |  |  |
| P2-14 CONVERTED_LEADS | 394 |  |  |
| P2-14 Lead conversion rate | 14.90% |  |  |
| P2-01..P2-12 (the rest of the page) | unchanged: the default values above |  |  |

### P2-14 Campaign conversion rate table

Table on `CAMP`, sorted by *Lead conversion rate* descending, summary row on. Evidence `07 [13]`
(`P2-14`).

Default, rows 1-10 and summary:

| Row | Campaign | Channel | Objective | Leads | Converted | Lead conv. rate | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `Video 2024 054` | video | awareness | 459 | 86 | 18.74% |  |  |
| 2 | `Video 2024 029` | video | awareness | 1,142 | 201 | 17.60% |  |  |
| 3 | `Affiliate 2024 030` | affiliate | acquisition | 2,205 | 366 | 16.60% |  |  |
| 4 | `Paid Search 2023 086` | paid_search | awareness | 1,277 | 211 | 16.52% |  |  |
| 5 | `Display 2023 058` | display | lead_gen | 1,246 | 203 | 16.29% |  |  |
| 6 | `Affiliate 2025 115` | affiliate | lead_gen | 1,925 | 313 | 16.26% |  |  |
| 7 | `Paid Search 2023 061` | paid_search | lead_gen | 4,239 | 688 | 16.23% |  |  |
| 8 | `Paid Social 2023 002` | paid_social | awareness | 1,849 | 300 | 16.22% |  |  |
| 9 | `Display 2023 028` | display | lead_gen | 272 | 44 | 16.18% |  |  |
| 10 | `Paid Search 2025 026` | paid_search | acquisition | 3,653 | 590 | 16.15% |  |  |
| summary | Summary row |  |  | 261,684 | 39,696 | 15.17% |  |  |

Re-sorted ascending (click the column header): rows 1-3 are the last rows of the descending order:

| Row | Campaign | Channel | Objective | Leads | Converted | Lead conv. rate | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 118 | `Video 2024 034` | video | awareness | 1,044 | 140 | 13.41% |  |  |
| 119 | `Video 2023 074` | video | awareness | 934 | 119 | 12.74% |  |  |
| 120 | `Video 2023 084` | video | awareness | 145 | 14 | 9.66% |  |  |

video, rows 1-3 and summary:

| Row | Campaign | Channel | Objective | Leads | Converted | Lead conv. rate | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `Video 2024 054` | video | awareness | 459 | 86 | 18.74% |  |  |
| 2 | `Video 2024 029` | video | awareness | 1,142 | 201 | 17.60% |  |  |
| 3 | `Video 2024 069` | video | awareness | 677 | 109 | 16.10% |  |  |
| summary | Summary row |  |  | 25,799 | 3,933 | 15.24% |  |  |

**2024: unchanged.** **Campaign** `Affiliate 2024 080`: see [P2-13](#p2-13-campaign-drop-down).

## Page 3: Lead Quality & CRM

Every source on this page is `LQ`, which has no date column (`07 [6]`): in state **2024** nothing on
the page changes.

### KPI cards P3-01..P3-05

Evidence `07 [20]`.

| ID | Card | State | Expected | Observed | Match? |
| --- | --- | --- | --- | --- | --- |
| P3-01 | Total leads | default | 261,684 |  |  |
| P3-01 | Total leads | video | 25,799 |  |  |
| P3-02 | Average lead score | default | 50.57 |  |  |
| P3-02 | Average lead score | video | 50.64 |  |  |
| P3-03 | Lead conversion rate | default | 15.17% |  |  |
| P3-03 | Lead conversion rate | video | 15.24% |  |  |
| P3-04 | Purchase rate | default | 6.38% |  |  |
| P3-04 | Purchase rate | video | 6.35% |  |  |
| P3-05 | Mean days to convert | default | 10.51 |  |  |
| P3-05 | Mean days to convert | video | 10.38 |  |  |

**2024: unchanged.** Every card keeps its default value.

### P3-06 Conversion by lead score segment and P3-07 Score segment table

Sorted by `SCORE_BAND_MIN` (Min) ascending: Low, Medium, High. Evidence `07 [21]`.

| Segment | Leads | Share of leads | Converted | Lead conv. rate | Purchase rate | Avg score | Mean days | video: lead conv. rate | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Low | 104,245 | 39.84% | 9,505 | 9.12% | 3.80% | 20.48 | 10.61 | 8.95% |  |  |
| Medium | 78,862 | 30.14% | 12,758 | 16.18% | 6.78% | 55.52 | 10.46 | 16.37% |  |  |
| High | 78,577 | 30.03% | 17,433 | 22.19% | 9.39% | 85.52 | 10.48 | 22.41% |  |  |
| Summary row | 261,684 | 100.00% | 39,696 | 15.17% | 6.38% | 50.57 | 10.51 | 15.24% |  |  |

P3-06, the column chart, shows the *Lead conversion rate* column; in state video it shows the last
column. In state video, P3-07 covers the 25,799 video leads: its *Share of leads* is then
39.58% / 30.43% / 29.99% (the video row of P3-11), and its summary row shows the video
values of P3-10 and P3-09.

### P3-08 Leads and conversion by 10-point score band

Combo chart on `LQ`: bars `LEADS`, line *Lead conversion rate*, bands `01-10` to `91-100`.
Evidence `07 [22]`.

| Band | Leads | Lead conv. rate | video: leads | video: rate | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- |
| 01-10 | 26,193 | 6.27% | 2,625 | 6.21% |  |  |
| 11-20 | 26,058 | 7.95% | 2,457 | 8.47% |  |  |
| 21-30 | 25,748 | 10.19% | 2,593 | 10.41% |  |  |
| 31-40 | 26,246 | 12.07% | 2,536 | 10.76% |  |  |
| 41-50 | 26,293 | 14.16% | 2,534 | 14.25% |  |  |
| 51-60 | 26,173 | 16.03% | 2,657 | 16.30% |  |  |
| 61-70 | 26,396 | 18.33% | 2,660 | 18.46% |  |  |
| 71-80 | 26,184 | 20.30% | 2,631 | 20.45% |  |  |
| 81-90 | 26,068 | 22.23% | 2,539 | 22.33% |  |  |
| 91-100 | 26,325 | 24.02% | 2,567 | 24.50% |  |  |

### P3-09 Days to convert by channel, P3-10 Channel lead quality, P3-11 Score mix by channel

All on `LQ` by `CHANNEL`. P3-10 is sorted by `LEADS` descending and has a summary row. P3-09 is
sorted by channel name, so read it by channel. Evidence `07 [23]`.

| Channel | Leads | Avg score | Lead conv. rate | Purchase rate | Mean days (P3-09) | Low / Medium / High (P3-11) | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| affiliate | 67,849 | 50.56 | 15.26% | 6.38% | 10.50 | 39.88% / 30.18% / 29.93% |  |  |
| paid_search | 65,268 | 50.66 | 15.35% | 6.44% | 10.50 | 39.60% / 30.25% / 30.16% |  |  |
| paid_social | 57,619 | 50.47 | 15.01% | 6.33% | 10.58 | 40.14% / 29.78% / 30.08% |  |  |
| display | 45,149 | 50.54 | 14.94% | 6.36% | 10.51 | 39.87% / 30.19% / 29.94% |  |  |
| video | 25,799 | 50.64 | 15.24% | 6.35% | 10.38 | 39.58% / 30.43% / 29.99% |  |  |
| Summary row | 261,684 | 50.57 | 15.17% | 6.38% | 10.51 | (39.84% / 30.14% / 30.03%) |  |  |

**video:** each chart shows only the video row. P3-11 has no summary: the shares in brackets are
those of all leads, for reference (P3-07).

## Page 4: Marketing Efficiency & ROAS

### KPI cards P4-01..P4-06

Source `CH` (whole campaigns, full range); filter channel. Evidence `07 [24]`.

| ID | Card | State | Expected | Compact on | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- |
| P4-01 | Total spend | default | 4,523,050.02 | 4.5M |  |  |
| P4-01 | Total spend | video | 828,094.54 | 828.1K |  |  |
| P4-02 | Attributed revenue | default | 21,561,839.01 | 21.6M |  |  |
| P4-02 | Attributed revenue | video | 2,087,554.22 | 2.1M |  |  |
| P4-03 | ROAS (attributed) | default | 4.77 |  |  |  |
| P4-03 | ROAS (attributed) | video | 2.52 |  |  |  |
| P4-04 | Cost per lead | default | 17.28 |  |  |  |
| P4-04 | Cost per lead | video | 32.10 |  |  |  |
| P4-05 | Cost per conversion | default | 113.94 |  |  |  |
| P4-05 | Cost per conversion | video | 210.55 |  |  |  |
| P4-06 | Budget utilisation | default | 83.47% |  |  |  |
| P4-06 | Budget utilisation | video | 83.24% |  |  |  |

**2024: unchanged.** Every card keeps its default value: `CH` has no date column (`07 [6]`).

### P4-07 Monthly spend vs attributed revenue

Combo chart on `MM`, bars `Spend`, line `Attributed revenue (booked)`, both on the left axis.
Evidence `07 [10]`, totals `07 [11]`.

| Month | Spend | Attributed revenue (booked) | Observed | Match? |
| --- | --- | --- | --- | --- |
| 2023-01 (Jan 2023) | 23,686.55 | 52,800.58 |  |  |
| 2024-10 (Oct 2024) | 219,378.73 | 961,348.25 |  |  |
| 2025-12 (Dec 2025) | 807.04 | 31,085.00 |  |  |

- Sums over the 36 months: 4,523,050.02 / 21,561,839.01 (the cards P4-01 / P4-02).
- **video:** `May 2024` 82,295.40 / 210,850.26; sums 828,094.54 /
  2,087,554.22.
- **2024:** 12 months; sums 1,971,198.34 / 8,677,647.82.

### P4-08 Channel efficiency comparison and P4-09 Spend share vs revenue share

P4-08 is a table on `CH`, sorted by *ROAS (attributed)* descending, with a summary row. P4-09 is
a column chart of the stored `SPEND_SHARE` / `REVENUE_SHARE`. Evidence `07 [25]`.

| Channel | Budget | Spend | Attributed revenue | ROAS | Cost/lead | Cost/conv. | Cost/purchase | Budget util. | P4-09 spend / revenue share | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| affiliate | 1,025,491.41 | 857,835.07 | 5,610,700.73 | 6.54 | 12.64 | 82.87 | 198.02 | 83.65% | 18.97% / 26.02% |  |  |
| paid_search | 1,079,299.66 | 897,091.53 | 5,439,329.35 | 6.06 | 13.74 | 89.54 | 213.39 | 83.12% | 19.83% / 25.23% |  |  |
| paid_social | 1,180,823.70 | 984,731.88 | 4,690,137.28 | 4.76 | 17.09 | 113.87 | 270.09 | 83.39% | 21.77% / 21.75% |  |  |
| display | 1,138,158.37 | 955,297.00 | 3,734,117.43 | 3.91 | 21.16 | 141.65 | 332.74 | 83.93% | 21.12% / 17.32% |  |  |
| video | 994,869.02 | 828,094.54 | 2,087,554.22 | 2.52 | 32.10 | 210.55 | 505.55 | 83.24% | 18.31% / 9.68% |  |  |
| Summary row | 5,418,642.16 | 4,523,050.02 | 21,561,839.01 | 4.77 | 17.28 | 113.94 | 270.99 | 83.47% |  |  |  |

- **video:** only the video row. P4-09 still shows 18.31% / 9.68%: the stored shares are shares of
  all five channels. A *Percent of total* comparison of `SUM(SPEND)` would show 100.00% instead.
- **2024: unchanged.**

### P4-10 Campaign drop-down

Select `Affiliate 2024 080` in the page-4 drop-down. P4-11 shows one row, and its summary row shows
the same values; P4-12 shows one bar. P4-01 to P4-09 do not change. Evidence `07 [26]`:

| Column | Expected | Observed | Match? |
| --- | --- | --- | --- |
| P4-11 SPEND | 17,904.18 |  |  |
| P4-11 REVENUE | 232,990.96 |  |  |
| P4-11 PURCHASES | 172 |  |  |
| P4-11 ROAS (attributed) | 13.01 |  |  |
| P4-11 Cost per purchase | 104.09 |  |  |
| P4-11 BUDGET | 20,903.18 |  |  |
| P4-11 Budget utilisation | 85.65% |  |  |
| P4-12 Cost per purchase (one bar) | 104.09 |  |  |
| P4-01..P4-09 (the rest of the page) | unchanged: the default values above |  |  |

### P4-11 Campaign ROAS ranking

Table on `CAMP`, sorted by *ROAS (attributed)* descending, 15 rows per page, summary row on.
Evidence `07 [13]` (`P4-11`), re-sort checks `07 [14]`.

| Row | Campaign | Channel | Spend | Attributed revenue | Purchases | ROAS | Cost/purchase | Budget | Budget util. | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `Affiliate 2024 080` | affiliate | 17,904.18 | 232,990.96 | 172 | 13.01 | 104.09 | 20,903.18 | 85.65% |  |  |
| 2 | `Affiliate 2024 070` | affiliate | 17,318.50 | 218,374.17 | 167 | 12.61 | 103.70 | 18,386.12 | 94.19% |  |  |
| 3 | `Affiliate 2023 040` | affiliate | 14,920.90 | 183,150.82 | 146 | 12.27 | 102.20 | 15,821.08 | 94.31% |  |  |
| 4 | `Affiliate 2025 035` | affiliate | 15,913.35 | 191,083.78 | 142 | 12.01 | 112.07 | 22,324.72 | 71.28% |  |  |
| 5 | `Affiliate 2024 045` | affiliate | 10,543.72 | 120,094.29 | 88 | 11.39 | 119.82 | 11,542.55 | 91.35% |  |  |
| 6 | `Affiliate 2025 095` | affiliate | 17,881.69 | 203,419.10 | 166 | 11.38 | 107.72 | 23,477.18 | 76.17% |  |  |
| 7 | `Affiliate 2024 005` | affiliate | 17,057.46 | 189,914.53 | 143 | 11.13 | 119.28 | 18,614.72 | 91.63% |  |  |
| 8 | `Affiliate 2023 050` | affiliate | 35,219.40 | 388,919.88 | 299 | 11.04 | 117.79 | 37,882.58 | 92.97% |  |  |
| 9 | `Affiliate 2025 110` | affiliate | 30,384.26 | 330,555.85 | 257 | 10.88 | 118.23 | 37,632.26 | 80.74% |  |  |
| 10 | `Paid Search 2023 086` | paid_search | 11,691.91 | 126,855.40 | 101 | 10.85 | 115.76 | 13,698.33 | 85.35% |  |  |
| 120 | `Video 2023 084` | video | 6,105.33 | 11,132.24 | 7 | 1.82 | 872.19 | 8,102.32 | 75.35% |  |  |
| summary | Summary row |  | 4,523,050.02 | 21,561,839.01 | 16,691 | 4.77 | 270.99 | 5,418,642.16 | 83.47% |  |  |

Row 5: Data Studio may show 119.81 for the cost per purchase ([Rounding](#rounding-the-last-digit)).

- Re-sorted by *Budget utilisation* ascending: row 1 is CMP0100 `Affiliate 2023 100`, 69.88%.
  Descending: row 1 is CMP0115 `Affiliate 2025 115`, 98.68%.
- **video**, rows 1-3 and summary:

| Row | Campaign | Channel | Spend | Attributed revenue | Purchases | ROAS | Cost/purchase | Budget | Budget util. | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `Video 2024 054` | video | 14,158.05 | 49,365.00 | 37 | 3.49 | 382.65 | 16,931.72 | 83.62% |  |  |
| 2 | `Video 2023 094` | video | 49,539.43 | 146,756.00 | 117 | 2.96 | 423.41 | 66,477.07 | 74.52% |  |  |
| 3 | `Video 2024 004` | video | 27,494.98 | 80,962.12 | 64 | 2.94 | 429.61 | 29,625.96 | 92.81% |  |  |
| summary | Summary row |  | 828,094.54 | 2,087,554.22 | 1,638 | 2.52 | 505.55 | 994,869.02 | 83.24% |  |  |

- **2024: unchanged.** **Campaign** `Affiliate 2024 080`: see [P4-10](#p4-10-campaign-drop-down).

### P4-12 Top performing campaigns: lowest cost per purchase

Horizontal bars on `CAMP`, *Cost per purchase* ascending, 10 bars. Evidence `07 [13]` (`P4-12`).

| Row | Campaign | Channel | Purchases | Cost per purchase | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Affiliate 2023 040` | affiliate | 146 | 102.20 |  |  |
| 2 | `Affiliate 2024 070` | affiliate | 167 | 103.70 |  |  |
| 3 | `Affiliate 2024 080` | affiliate | 172 | 104.09 |  |  |
| 4 | `Affiliate 2025 095` | affiliate | 166 | 107.72 |  |  |
| 5 | `Affiliate 2025 035` | affiliate | 142 | 112.07 |  |  |
| 6 | `Paid Search 2023 086` | paid_search | 101 | 115.76 |  |  |
| 7 | `Affiliate 2023 050` | affiliate | 299 | 117.79 |  |  |
| 8 | `Affiliate 2025 110` | affiliate | 257 | 118.23 |  |  |
| 9 | `Affiliate 2024 005` | affiliate | 143 | 119.28 |  |  |
| 10 | `Affiliate 2024 045` | affiliate | 88 | 119.82 |  |  |

Row 10: Data Studio may show 119.81 ([Rounding](#rounding-the-last-digit)); both count as a match.

**video**, bars 1-3:

| Row | Campaign | Channel | Purchases | Cost per purchase | Observed | Match? |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Video 2024 054` | video | 37 | 382.65 |  |  |
| 2 | `Video 2023 019` | video | 53 | 405.64 |  |  |
| 3 | `Video 2023 094` | video | 117 | 423.41 |  |  |

**2024: unchanged.** **Campaign** `Affiliate 2024 080`: see [P4-10](#p4-10-campaign-drop-down).

P4-13 is a text box: check its numbers against
[business_insights.md](business_insights.md#q7-where-should-the-budget-go-first-hypotheses-and-tests), not here.

## Build log, pass 1 (live Snowflake)

Observed in the report while it was built; each line was compared with the expected values above.

- **2026-10-15, page 1 (Marketing Overview): all checked values match.**
  - KPI cards (default): 120 / 4,523,050.02 / 436,844,819 / 7,102,319 / 261,684 / 39,696 / 15.17%.
    P1-01 is built on `CH.CAMPAIGNS` (see the build note in the spec: Count Distinct on `DAILY`
    returned campaign-days).
  - KPI cards with channel = video: 24 / 828,094.54 / 55,205,469 / 492,490 / 25,799 / 3,933 / 15.24%.
  - "2025 vs 2024" strip (P1-K1 dropped): 1,093,589.27 (-44.5%), 66,764 (-37.8%), 10,769 (-33.3%),
    15.18% (-0.1%).
  - P1-08: 36 months, spend peak in October 2024, campaigns-in-flight peak 20. P1-09: 67,849 /
    65,268 / 57,619 / 45,149 / 25,799 in that order. P1-10: 36 months, peak October 2024.
  - P1-11: rows 1-3 and the summary row (39,696 / 17.28 / 15.17% / 4.77) as expected; 120 rows.
    P1-12 with `Affiliate 2024 080`: one row 17,904.18 / 2,644 / 394 / 232,990.96 / 6.77 / 14.90% /
    13.01.
  - Lesson: a click on a time-axis bar applied a cross-filter (`MONTH_START = Nov 2025`) to the
    whole page; cross-filtering was then switched off on P1-08 and P1-10, as D10 prescribes.
- **2026-10-16, page 2 (Conversion Funnel): all checked values match.**
  - KPI cards: 1.63% / 3.68% / 15.17% / 17.28 / 113.94.
  - P2-06 funnel: 436,844,819 (100%) → 7,102,319 (1.63%) → 261,684 (3.68%) → 39,696 (15.17%) →
    16,691 (42.05%). The proportional "stepped bar" shape left the later stages as hairlines (the
    stages span 436.8 million to 16,691), so the funnel uses the **Inverted triangle** shape;
    the labels still carry the exact values and "% of previous" (a deviation from the spec's
    style choice, not from its numbers).
  - P2-07: the five stage rows as expected (Impressions % of previous = null).
  - P2-08: all 5 channels × 11 columns as expected, incl. the Wilson bounds; sorted by lead
    conversion rate (paid_search, affiliate, video, paid_social, display).
  - P2-09: 36 points, flat near 15% on an axis from 0, low 2025-09, high 2025-12. P2-10..P2-12:
    10.51 / 34.45% / 4,716 (the `After flight` filter on `DAILY` with `SUM(CONVERSIONS)` works;
    only Count Distinct was affected).
  - P2-14: rows 1-3 Video 2024 054 459 / 86 / 18.74%, Video 2024 029 1,142 / 201 / 17.6%,
    Affiliate 2024 030 2,205 / 366 / 16.6%; summary 261,684 / 39,696 / 15.17%.
  - UI lessons: a filter value must be picked from the suggestion list so it becomes a chip, or
    *Save* stays disabled; clicking a table header applies a temporary sort that overrides the
    Setup sort.
- **2026-10-16, page 3 (Lead Quality & CRM): all checked values match.**
  - KPI cards: 261,684 / 50.57 / 15.17% / 6.38% / 10.51.
  - P3-06: Low 9.12%, Medium 16.18%, High 22.19% (sorted by `SCORE_BAND_MIN` Min ascending).
    This version's bar chart offers only a single *Bar color*, so the segment colours were skipped.
  - P3-07: the three segment rows and the summary 261,684 / 100% / 39,696 / 15.17% / 6.38% /
    50.57 / 10.51 as expected.
  - P3-08: ten bands of about 26,000 leads; rate 6.27%, 7.95%, 10.19%, 12.07%, 14.16%, 16.03%,
    18.33%, 20.3%, 22.23%, 24.02%.
  - P3-09: 10.5 / 10.51 / 10.5 / 10.58 / 10.38. P3-10: all five channel rows and the summary as
    expected. P3-11: 100% stacked, about 40/30/30 in every channel.
  - A click on the High bar cross-filtered the page (`LEAD_SCORE_SEGMENT = High`), which is the
    intended interaction (D10); it was reset before checking the default values.
- **2026-10-16, page 4 (Marketing Efficiency & ROAS): all checked values match.**
  - KPI cards: 4.5M / 21.6M (compact numbers kept on these two because the full values overflow
    the card; the same totals were checked exactly on page 1) / 4.77 / 17.28 / 113.94 / 83.47%.
  - P4-07: 36 months on one money axis; peak revenue in October 2024 (about 0.96 M).
  - P4-08: summary ROAS 4.77 and budget utilisation 83.47% (confirmed by the user).
  - P4-09: spend / revenue shares as expected for all five channels. It first rendered the revenue
    share on a second (right) axis with a different scale, which made the paired bars misleading;
    both series were put on the left axis.
  - P4-11: rows 1-5 (13.01 / 12.61 / 12.27 / 12.01 / 11.39) and the summary (4.77 / 270.99 /
    83.47%) as expected; 5 rows per page instead of 15. P4-12: 102.2 ... 119.82 in order, after
    switching "Group the rest as Others" off again (changing the chart type re-enabled it).
  - P4-10 with `Affiliate 2024 080` leaves one row in P4-11 and one bar (104.09) in P4-12
    (confirmed by the user).
  - Layout differs from the spec: P4-08 and P4-11 full width; P4-12 and P4-09 side by side; the
    P4-13 insight text full width under P4-09.

## Build log, pass 1b: polish on the final report (live Snowflake)

The pass-1 report was copied and the copy, renamed `Marketing CRM & Conversion Funnel Analytics
Report`, is the final report. The original is kept unchanged. A PDF review on 2026-10-17 found no
wrong numbers; the changes below are display only (no data source, calculated field or filter was
touched), and every value was re-read after the change.

- **Fixed defect.** The report-level date control had a default of Jan 1, 2023 to **Dec 25**, 2025;
  it is now Dec 31, 2025 (D4). No value changed: daily activity ends 2025-12-23 and the monthly
  sources are keyed on the 1st.
- **Sorts.** Most mis-sorted charts in the first PDF were temporary header-click sorts; the Setup
  sorts were already right. P3-07 now sorts on `SCORE_BAND_MIN` (Min) ascending, so Low, Medium,
  High stays in order under any channel filter. Reload (⌘R) before exporting a PDF.
- **Labels.** Field names shown to viewers are now plain English: the channel and campaign
  drop-downs read `Channel` / `Campaign`, and the table headers `Channel`, `Objective`, `Stage`
  (renamed per chart; the field IDs that the report-level control matches on are unchanged).
  KPI labels were shortened where they were clipped (`Conversions (booked)`, `Lead conversion
  rate`, `CTR`, `Mean days to convert`, `Converted in a later month`, `Average lead score`,
  `Purchase rate`, `Attributed revenue`); `Total marketing spend` became `Total spend`, as on
  page 4. P2-08 headers: `Converted leads`, `Lead conv. rate`, `Cost per lead`, `Cost per
  conversion`; P3-07 headers: `Share of leads`, `Purchase rate`, `Mean days`.
- **Number formats.** Money, ratio and percent columns use a fixed 2 decimals instead of *auto*
  (e.g. 71,337.50, 14.60%, 32.10, 3.80%, 100.00%, 20.30%, 10.50, 102.20); counts stay whole.
  P2-07 `% of impressions` uses `0.000%` and shows `-` for the first row. KPI counts use compact
  numbers on every page (261.7K, 39.7K).
- **Layout and style.** Font Roboto throughout (title 24 px bold, section headings 16 px bold);
  legends 12 px; grey negative-change arrows on the "2025 vs 2024" cards; P1-08 right axis 0-25 and
  P3-08 right axis 0-30% so the ticks sit on the gridlines; P3-08 bars light, line and labels dark;
  P2-06 funnel in one blue scale; P2-09 without the gradient fill; P4-09 data labels at 10 px on
  wider groups so the paid_social pair no longer overlaps; tables that show all their rows use
  Top N instead of pagination; P4-08 Budget total no longer clipped.
- **Captions.** Fixed `channell`; header subtitle reads "synthetic data"; captions that pointed at
  interactions ("Click a bar to filter the page") or at a repo path were reworded for the PDF.
- **Second PDF review (2026-10-18).** 835 values re-checked, none wrong. Two regressions from the
  first polish were fixed: P2-08 had lost its formats (counts without separators, the five rate
  columns as fractions such as 0.15) and P4-11 showed the Purchases total as `16691`. Cause: a
  decimal precision set in a chart's STYLE tab can reset the field's *Display Format* to `None`,
  which only shows after a reload. Fix: the chart's metric chips carry the format (`Default` for
  counts, `Percent(2)` for rates, `Number(2)` for money ratios) and STYLE decimal precision stays
  `auto`. Also: P3-07 headers `Converted leads` / `Lead conv. rate` / `Avg lead score`; P3-08 line
  labels dark grey (its right axis keeps `0.00%` ticks because it follows the field format);
  P4-09 labels centred in the bars; P1-11 ROAS bars green as on page 4; `CC BY 4.0` kept on one
  line in the header (non-breaking spaces); spacing tightened around P1-10, P2-07, P2-08, P3-07
  and P3-11; shorter P3-09 caption and P4-13 second bullet.
- **Third PDF review (2026-10-18).** 553 values re-checked, none wrong; the P2-08 and P4-11
  regressions are confirmed fixed. Last touches: P4-07 left-axis title off; P4-08 and P4-11
  captions widened to one line; P4-09 data labels 9 px (at 10 px the PDF export drew most of them
  above the bars; at 9 px all ten sit inside the bars in white, checked in the final PDF); P2-06 and P4-12 captions
  trimmed to avoid one-word last lines; the P4-13 text no longer points to the GitHub repo; P1-11
  uses *Auto-height* like P4-11, so both 5-row campaign tables share the same row height (P2-14
  keeps the compact rows so its 10 rows still fit the page); P3-11 caption moved closer to its
  chart.

## Build log, pass 2: the Google Sheets copy

The public version is a copy of the final report in a personal Google account (the university
Workspace does not allow "Anyone with the link"), moved onto seven reusable Google Sheets data
sources named `<TABLE> (Sheets snapshot)`, one per report table, on the
[exports/](../exports/README.md) workbook converted to Google Sheets (export of 2026-10-14). The
final Snowflake report was only read, never edited.

- **What the copy broke.** The *Make a copy* dialog mapped all seven sources correctly, but the
  Snowflake and Sheets connectors give fields different IDs, so Data Studio "repaired" each chart
  by picking fields itself. Many chips pointed at the wrong field and every per-chart name was
  lost. Examples: P2-01 showed the sum of the stored `CTR` column (9.28% instead of 1.63%); P2-07
  became a table of channels with `Record Count`; P2-08 showed `BUDGET` / `SPEND` in place of the
  Wilson bounds; P3-06, P3-07, P3-10 and P3-11 had `CHANNEL` and `LEAD_SCORE_SEGMENT` swapped;
  P4-03 showed `Click-through rate`, P4-06 `Cost per purchase`; P1-11, P2-14, P4-11 and P4-12 and
  the three campaign drop-downs used `CAMPAIGN_ID` instead of `CAMPAIGN_NAME`; P1-08 and P4-07
  plotted the wrong second series; the channel drop-down lost its label and the `DAILY` filters
  `In flight only` and `After flight` became invalid (P2-12 showed an error).
- **Repair.** Every component was set back by hand to the final report: fields, sort fields,
  per-chart names, display formats (`Number(2)`, `Percent(2)`, P2-07 `0.000%`), data-label
  decimals (P3-09 2), and both `DAILY` filters re-pointed at `IS_IN_FLIGHT` (= 1 / = 0). The copy
  had also reset the card formats to `Default`, which shows only in some states (P2-04 and P4-04
  read `32.1` for video); all rate and money-ratio cards now carry their format on the chip. The
  copy was renamed `Marketing CRM & Conversion Funnel Analytics Report`.
- **Snapshot note.** A report-level text box between the date control and the Channel drop-down
  ([step 8 of the Sheets runbook](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/sheets_snapshot.md#step-8-provenance-note-and-attribution),
  in the git history at commit dbe41f7).
- **Checks (2026-10-18), all matching.**
  - Default state: the rendered text of all four pages is identical to the final Snowflake
    report, value by value, labels and captions included.
  - video: P1 cards 24 / 828,094.54 / 55,205,469 / 492,490 / 25,799 / 3,933 / 15.24%; strip
    129,218.74 (-74.4%), 3,889 (-75.3%), 638 (-73.8%), 15.61% (+1.1%); P1-11 24 campaigns, summary
    828,094.54 / 25,799 / 3,933 / 2,087,554.22 / 32.10 / 15.24% / 2.52; P2 cards 0.89% / 5.24% /
    15.24% / 32.10 / 210.55; P2-07 video funnel; P2-10..P2-12 10.38 / 34.05% / 406; page 3 all
    tables as the video rows of `07 [20]`-`07 [23]`; P4 cards 2.52 / 32.10 / 210.55 / 83.24%.
  - 2024: P1-02..P1-07 1,971,198.34 / 175,148,406 / 3,092,049 / 107,371 / 16,148 / 15.20% (read as
    compact values); P1-01, the strip and P1-11 unchanged; on page 2 (G1) P2-10..P2-12 10.51 /
    35.12% / 2,065 while the `CH` cards stay unchanged.
  - Campaign `Affiliate 2024 080` on page 1: P1-11 one row and summary 17,904.18 / 2,644 / 394 /
    232,990.96 / 6.77 / 14.90% / 13.01; the cards unchanged.
  - Only cosmetic difference left: the sorted rate column of P2-08 and P2-14 shows the ▼ sort
    marker in its header, which the final report does not show; the sort and every row are the
    same.
- **Viewer language.** Compact numbers, dates and the summary label follow the viewer's Google
  language (Korean: 452.3만, 2023. 1. 1., 총 합계). Adding `?hl=en` to the report link shows the
  English formats (4.5M, Jan 1, 2023, Grand total), as in the PDFs.

## Sign-off

Fill in one column per pass. Pass 1 is the live Snowflake connector. Pass 2 repeats the whole
checklist on the Google Sheets snapshot (spec
[section 9](dashboard_spec.md#9-later-the-snowflake--google-sheets-swap);
[build log, pass 2](#build-log-pass-2-the-google-sheets-copy)). The numbers must be identical in
both passes.

| Item | Pass 1: live Snowflake | Pass 2: Sheets snapshot |
|---|---|---|
| Date checked | 2026-10-15..16 (build); PDF reviews 2026-10-17..18 | 2026-10-18 |
| Checked by | build session, report read back against this page | build session, report read back against this page and the final report |
| G2 result (no overrides / overrides / fallback) | no overrides (2026-10-14) | no overrides (2026-10-18) |
| G1 result (report-level date control on page 2) | not recorded | passed: 2024 set on page 1 carried to page 2 |
| Rows checked / rows matched | every component in the default state plus the build-log spot checks; PDF reviews 835 and 553 values; all matched | all four pages in the default state (identical to the final report), video on all four pages, 2024 on pages 1-2, campaign on page 1; all matched |
| Rows not matching (IDs and observed values) | none | none |
| Midpoint cells seen as the lower value (see Rounding) | none (P4-11 / P4-12 show 119.82) | none (119.82) |
| All four pages match the SQL (yes / no) | yes | yes |

A mismatch is recorded, not fixed by changing a field: the sign-off is "yes" only when every row
matches. Then the spec's publishing steps (section 7) follow.

## Reproduce the expected values

From the repository root (read-only; well under a minute on the X-Small warehouse):

```
.venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/07_dashboard_validation.sql
```

The run exits 1 if any check row says FAIL. Statement map (`07 [n]` → block of the SQL file):

| `07 [n]` | Block | Components |
|---|---|---|
| `[6]` | 0b inputs | the seven sources and the three seeds: row counts; date columns per source |
| `[7]` | 0c gate G2 | `SUM(LEADS)` per source, all channels and video |
| `[8]` | 1 | P1-01..P1-07 |
| `[9]` | 2 | P1-K1..P1-K5 |
| `[10]` | 3 | P1-08, P1-10, P4-07: the 36 months, all channels and video |
| `[11]` | 3c | their point counts, sums and peaks per state |
| `[12]` | 4 | P1-09 |
| `[13]` | 5 | P1-11, P2-14, P4-11, P4-12: rows shown and summary rows, default and video |
| `[14]` | 5c | campaign counts, ties, re-sort extremes, D3 diagnostic, summary-row trap |
| `[15]` | 6 | P2-01..P2-05, default and video |
| `[16]` | 7 | P2-06, P2-07 |
| `[17]` | 8 | P2-08 |
| `[18]` | 9 | P2-09: the 36 cohort months, all channels and video |
| `[19]` | 10 | P2-10..P2-12, default, video, 2024, 2025 |
| `[20]` | 11 | P3-01..P3-05, default and video |
| `[21]` | 12 | P3-06, P3-07 |
| `[22]` | 13 | P3-08 |
| `[23]` | 14 | P3-09, P3-10, P3-11 |
| `[24]` | 15 | P4-01..P4-06, default and video |
| `[25]` | 16 | P4-08, P4-09 |
| `[26]` | 17 | Campaign drop-downs P1-12, P2-13, P4-10: `Affiliate 2024 080` |
| `[27]` | 18 | display rounding guard (midpoint cells) |

The references are documented in the SQL file's header. Every reference is independent of the
query it checks. The seeds and the publisher table come from outside Snowflake. The evidence numbers
passed their own Phase 4 checks. The STAGING recomputations are an independent aggregation path,
used only where neither of the others has the figure. If a dbt rebuild changes any MART table,
re-run the file and regenerate this page's numbers from the new evidence.
