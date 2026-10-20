# Phase 2: data profile (Snowflake SQL)

**Goal of Phase 2:** load the raw data and understand its structure: check the data types,
primary-key duplicates, NULLs and outliers, and the relationships between the four tables, and
finish a basic SQL analysis. **Status: done (2026-10-13).**

This page summarises what the profiling found. Everything here is a **descriptive fact about the
dataset**. Nothing here answers the business questions or explains causes; that is Phase 4.

Every number on this page is copied from the two evidence files below. Where a number is derived
(a ratio, a sum or a difference), the arithmetic is shown next to it. Sources are given as
*file, block [statement]*. For example, `01 §8.3 [24]` is block 8.3 of
`01_data_profiling.sql`, printed as statement `[24]` in its evidence file. The challenge results
print their block in a `BLOCK` column, e.g. `01b 5c [26]`.

## Contents

1. [How it was produced](#how-it-was-produced)
2. [Data quality summary](#data-quality-summary)
3. [Structure and grain](#structure-and-grain)
4. [Distributions](#distributions)
5. [Time](#time)
6. [The grain trap](#the-grain-trap)
7. [First look](#first-look)
8. [Cleaning-challenge extracts](#cleaning-challenge-extracts)
9. [Implications for Phase 3 and Phase 4](#implications-for-phase-3-and-phase-4)
10. [Caveats](#caveats)

## How it was produced

| | Clean release | Cleaning-challenge extracts |
|---|---|---|
| SQL | [`sql/01_data_profiling.sql`](../sql/01_data_profiling.sql), 32 statements | [`sql/01b_challenge_profiling.sql`](../sql/01b_challenge_profiling.sql), 33 statements |
| Tables | `RAW.CAMPAIGNS`, `DAILY_SPEND`, `LEADS`, `CONVERSIONS` | `RAW.CHALLENGE_CAMPAIGNS`, `_DAILY_SPEND`, `_LEADS`, `_CONVERSIONS` |
| Command | `make profile` | `make profile-challenge` |
| Evidence (full output) | [`docs/evidence/01_data_profiling.txt`](evidence/01_data_profiling.txt) | [`docs/evidence/01b_challenge_profiling.txt`](evidence/01b_challenge_profiling.txt) |
| Check rows | 242 PASS, 0 FAIL | 182 PASS, 0 FAIL |
| Exit code | 0 | 0 |

- **How it runs.** Both make targets run `scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200`. `run_sql.py` prints every statement's first line and its result, and exits 1 if any result row has `STATUS = 'FAIL'`. `tee` writes the output to `build/` first, and `set -o pipefail` keeps the script's exit code, so only a run that exits 0 replaces the evidence file; a failed or interrupted run leaves it unchanged.
- **Identity.** User `SVC_CRM_PIPELINE`, role `CRM_TRANSFORMER`, no secondary roles. Warehouse `MARKETING_WH`, schema `MARKETING_CRM.RAW`, region `AWS_US_EAST_2`, Snowflake 10.36.101 (`01b 0 [5]`). `CRM_TRANSFORMER` can SELECT every RAW table but cannot write to RAW.
- **Read-only.** Both files contain only `USE` and `SELECT` / `WITH` statements. RAW stays all-VARCHAR (lossless landing, [architecture](architecture.md#design-decisions) decision 1). Values are cast inside the queries, with `TRY_TO_DATE(x, 'YYYY-MM-DD')` and `TRY_TO_NUMBER(x[, 12, 2])`.
- **Date.** Block 0 of the challenge evidence records `2026-10-14 01:36 UTC`, which is 21:36 US Eastern on 2026-10-13. The clean-release evidence has no timestamp column.
- **What PASS means.** Every `EXPECTED` value was computed locally from the same CSV files, without Snowflake. Most come from the profiling done before the account existed, in DuckDB; the channel and KPI bases were computed a second time with Python `csv` + `Decimal`, and the two methods agreed exactly. The few values that this first pass did not compute come from a Phase 2 recompute with Python `csv` + `Decimal` (for `01b`, that recompute also reproduced every DuckDB figure). The header comment of each SQL file names the source of every block's expected values. `STATUS = PASS` means Snowflake reproduced the expected value **exactly**, so the 424 PASS rows (242 + 182) are 424 exact agreements between Snowflake and the local baseline.
  - Percentiles agree to the last digit, because `PERCENTILE_CONT` and `MEDIAN` interpolate linearly, like DuckDB's `quantile_cont` and the Python recompute.
  - `STDDEV` returns FLOAT, so it is compared at 4 decimal places.
  - A PASS says the data is *as profiled*, not that it is "good". For example, 4,716 conversions after their campaign ended is an expected value and a design input.
- **Rows without a STATUS.** These are descriptive:
  - `01`: the channel × objective matrix.
  - `01b`: blocks 3b and 4b, the first copy of each duplicate in 2b (the reference the later copy is compared with), and the 15 defect rows of block 7, whose totals carry the STATUS.

## Data quality summary

**The clean release passes every check.** Sources: `01 §1 [5]`, `§2.1 [6]`, `§3.1 [8]`,
`§3.2 [9]`, `§4 [10]`, `§5.3 [13]`, `§6.4 [17]` and `§7.1 [19]`.

| Table | Rows | Business columns | Primary key | Other unique keys | NULL / empty / whitespace-only / untrimmed / null-token / non-printable cells | Values off their documented type | Orphan foreign keys | Exact duplicate rows |
|---|---:|---|---|---|---:|---:|---|---:|
| campaigns | 120 | 7, all TEXT | `campaign_id`: 120 distinct, gap-free 1..120 | `campaign_name`: 120 distinct | 0 | 0 | parent table: 0 campaigns without spend rows, leads or conversions | 0 |
| daily_spend | 11,240 | 6, all TEXT | `spend_id`: 11,240 distinct, gap-free 1..11,240 | `(campaign_id, spend_date)`: 11,240 distinct | 0 | 0 | 0 (`campaign_id` → campaigns) | 0 |
| leads | 261,684 | 5, all TEXT | `lead_id`: 261,684 distinct, gap-free 1..261,684 | none | 0 | 0 | 0 (`campaign_id` → campaigns) | 0 |
| conversions | 39,696 | 5, all TEXT | `conversion_id`: 39,696 distinct, gap-free 1..39,696 | `lead_id`: 39,696 distinct (one conversion per lead) | 0 | 0 | 0 (`lead_id` → leads) | 0 |

Every table also has the three lineage columns `_SOURCE_FILE`, `_SOURCE_ROW_NUMBER` and `_LOADED_AT`.
Its column order equals the CSV header (`COLUMNS_MATCH_HEADER = True`). Beyond the table above:

- **Domains.** 0 values fall outside the accepted sets of `channel`, `objective`, `lead_source` and `conversion_type`, and there are 0 case or whitespace variants (`01 §5.3 [13]`).
- **Business rules.** All 10 rules have 0 violations (`01 §6.4 [17]`): clicks ≤ impressions; impressions, clicks, spend and budget > 0; lead_score between 1 and 100; trial ⇒ revenue = 0.00; purchase ⇒ revenue > 0; campaign total spend ≤ budget; leads ≤ clicks per campaign-day.

**The cleaning-challenge extracts are where the defects are.** Sources: `01b 1a [6]`, `1b [7]`,
`2a [12]`, `7 [30]`.

| Extract | Rows | Distinct keys | Surplus exact copies | Casing / whitespace cells | Slash dates | Blank required cells | Relation to the clean release |
|---|---:|---:|---:|---:|---:|---:|---|
| CHALLENGE_CAMPAIGNS | 121 | 120 | 1 | 1 | 1 | 1 | the first 120 keys of 120 |
| CHALLENGE_DAILY_SPEND | 2,001 | 2,000 | 1 | 0 | 1 | 1 | the first 2,000 keys of 11,240 |
| CHALLENGE_LEADS | 2,001 | 2,000 | 1 | 1 | 1 | 1 | the first 2,000 keys of 261,684 |
| CHALLENGE_CONVERSIONS | 2,001 | 2,000 | 1 | 1 | 1 | 1 | the first 2,000 keys of 39,696 |
| **Total defects** | | | **4** | **3** | **4** | **4** | **15** |

## Structure and grain

| Table | One row is | Key | Grain facts |
|---|---|---|---|
| campaigns | one campaign | `campaign_id` (alternate key `campaign_name`) | 24 campaigns per channel. The window runs from `start_date` to `end_date`, 46 to 150 days. One `budget` per campaign |
| daily_spend | one campaign on one day of its window | `spend_id`, unique on `(campaign_id, spend_date)` | 11,240 rows = the window days of all campaigns: no gaps, no rows outside a window |
| leads | one lead, attributed to one campaign | `lead_id` | every lead falls inside its campaign window, on a day that has a spend row |
| conversions | one converted lead (trial **or** purchase) | `conversion_id`, unique on `lead_id` | 16,691 purchases + 23,005 trials |

```
campaigns (120) ──1:N──► daily_spend (11,240; one row per window day, 46-150 per campaign)
      │
      └──1:N──► leads (261,684) ──1:0..1──► conversions (39,696)
```

**Cardinalities and relationships** (`01 §3.1 [8]`, `§7.1-7.3 [19-21]`, `§8.2 [23]`, `§5.2 [12]`):

- **Leads to conversions is 1:0..1.**
  - 221,988 leads (share 0.848306) have no conversion; 39,696 (0.151694) have exactly 1; no lead has 2 or more.
  - So a lead converts at most once, to a trial or to a purchase, never both. The funnel is therefore an aggregate campaign funnel: the data cannot follow a person from trial to purchase.
  - Every lead-level model must LEFT JOIN conversions.
- **Every campaign has children.** Each one has spend rows, leads and conversions: 0 campaigns lack any of them.
- **`lead_source` duplicates the campaign channel.** It equals `campaigns.channel` for all 261,684 leads (0 mismatches).
- **Spend days without leads.** 7 spend rows have zero leads, so cost per lead is undefined on those days.
- **Channel and objective are partly confounded** (campaign counts):

  | Channel | acquisition | awareness | lead_gen | Campaigns |
  |---|---:|---:|---:|---:|
  | affiliate | 8 | 11 | 5 | 24 |
  | display | 3 | 4 | 17 | 24 |
  | paid_search | 9 | 7 | 8 | 24 |
  | paid_social | 7 | 10 | 7 | 24 |
  | video | 8 | 12 | 4 | 24 |
  | **Total** | **35** | **44** | **41** | **120** |

  Display is mostly lead_gen (17 of 24), and display makes up 17 of the 41 lead_gen
  campaigns. An objective comparison that ignores channel would partly re-measure channel.
- **The IDs are surrogate numbers.** They run gap-free from 1 to N in all four tables (`01 §3.2 [9]`), and the row counts equal the publisher's documented counts (`01 §1 [5]`), which together show that no row is missing from RAW. The IDs carry no business meaning. ID order is not used as a proxy for time, except where an invariant inside the files proves the ordering (challenge block `4c`).

## Distributions

**Categorical values** (`01 §5.1 [11]`):

| Column | Values (rows, share) |
|---|---|
| campaigns.channel | affiliate, display, paid_search, paid_social, video: 24 each (0.2000) |
| campaigns.objective | acquisition 35 (0.2917), awareness 44 (0.3667), lead_gen 41 (0.3417) |
| leads.lead_source | affiliate 67,849 (0.2593), paid_search 65,268 (0.2494), paid_social 57,619 (0.2202), display 45,149 (0.1725), video 25,799 (0.0986) |
| conversions.conversion_type | trial 23,005 (0.5795), purchase 16,691 (0.4205) |

Channels are balanced by campaign count but not by lead volume.

**Numeric measures** (`01 §6.1 [14]`; sample standard deviation):

| Measure | N | Min | P25 | Median | P75 | Max | Mean | SD |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| campaigns.budget | 120 | 8,102.32 | 27,094.5925 | 48,059.12 | 61,425.745 | 79,884.92 | 45,155.351333 | 20,913.6146 |
| daily_spend.impressions | 11,240 | 2,565 | 17,993.75 | 31,236 | 54,272.75 | 175,793 | 38,865.197420 | 27,384.1313 |
| daily_spend.clicks | 11,240 | 17 | 242.75 | 492 | 842 | 4,126 | 631.878915 | 542.2532 |
| daily_spend.spend | 11,240 | 37.14 | 236.375 | 369.53 | 524.3475 | 1,478.36 | 402.406585 | 231.1227 |
| leads.lead_score | 261,684 | 1 | 26 | 51 | 76 | 100 | 50.571059 | 28.869 |
| conversions.revenue (purchases) | 16,691 | 99.11 | 682.25 | 1,292.95 | 1,893.32 | 2,498.92 | 1,291.824277 | 695.2246 |
| conversions.revenue (all) | 39,696 | 0.00 | 0.00 | 0.00 | 1,057.0475 | 2,498.92 | 543.174098 | 780.9479 |

- **Skew.** Impressions, clicks and spend are right-skewed: in all three the mean is above the median.
- **Revenue has two populations.** Trials are always 0.00, so the median of all revenue is 0.00. Any revenue average must therefore say whether it is per conversion or per purchase.
- **Lead score is close to uniform on 1-100.** The ten 10-point bands hold 25,748 to 26,396 leads each (shares 0.0984 to 0.1009). The dashboard segments line up with band edges: Low (1-40) 104,245, Medium (41-70) 78,862, High (71-100) 78,577 leads (`01 §6.5 [18]`). How the score is produced is undocumented, and nothing here says whether it predicts conversion.

**Outliers by the 1.5 × IQR rule** (pooled fences, `01 §6.2 [15]`, `§6.3 [16]`):

| Measure | IQR | Upper fence | High outliers | Share of rows |
|---|---:|---:|---:|---:|
| daily_spend.impressions | 36,279 | 108,691.25 | 301 | 0.0268 |
| daily_spend.clicks | 599.25 | 1,740.875 | 559 | 0.0497 |
| daily_spend.spend | 287.9725 | 956.3063 | 303 | 0.0270 |
| budget, lead_score, revenue (purchases and all) | | | 0 | 0.0000 |

- **No low outliers.** Every lower fence is negative, and there are 0 low outliers anywhere.
- **The high outliers concentrate in particular channels:**

  | Channel | Spend rows | High impressions | High clicks | High spend |
  |---|---:|---:|---:|---:|
  | affiliate | 2,150 | 78 | 370 | 82 |
  | display | 2,367 | 189 | 0 | 24 |
  | paid_search | 2,307 | 0 | 119 | 88 |
  | paid_social | 1,906 | 34 | 70 | 89 |
  | video | 2,510 | 0 | 0 | 20 |
  | **Total** | **11,240** | **301** | **559** | **303** |

- **Nothing marks them as errors.** Every outlier row passes all 10 business rules (0 violations on any row, `01 §6.4 [17]`), so no row is a candidate for removal.

## Time

**Coverage per date column** (`01 §8.1 [22]`). The documented coverage is 2023-01-01 to
2025-12-31, and 0 dates fall outside it.

| Column | Min | Max | Distinct dates | Span (days) | Rows 2023 | Rows 2024 | Rows 2025 |
|---|---|---|---:|---:|---:|---:|---:|
| campaigns.start_date | 2023-01-04 | 2025-08-28 | 110 | 968 | 48 | 50 | 22 |
| campaigns.end_date | 2023-03-14 | 2025-12-02 | 116 | 995 | 38 | 47 | 35 |
| daily_spend.spend_date | 2023-01-04 | 2025-12-02 | 1,064 | 1,064 | 3,848 | 4,405 | 2,987 |
| leads.created_at | 2023-01-04 | 2025-12-02 | 1,064 | 1,064 | 87,549 | 107,371 | 66,764 |
| conversions.converted_at | 2023-01-05 | 2025-12-21 | 1,080 | 1,082 | 12,779 | 16,148 | 10,769 |

- **Observed activity is narrower than the documented coverage.** Spend dates are contiguous: 1,064 distinct dates over a 1,064-day span. 32 days of the documented coverage have no spend row (`01 §8.2 [23]`), so the documented coverage is 1,064 + 32 = 1,096 days.
- **Campaign windows hold all activity.** No campaign ends before it starts. Windows run 46 to 150 days, and 0 spend rows and 0 leads fall outside their campaign window.

**Conversion timing and lag** (`01 §8.3 [24]`, `§8.4 [25]`):

- **Before the lead:** 0 conversions.
- **On the lead's day:** 1,811 (770 purchases, 1,041 trials).
- **Lag** (`DATEDIFF('day', created_at, converted_at)`): it runs from 0 to 21 days, with 0 conversions over 21 days.
  - Overall: p25 5, median 10, p75 16, p90 19, mean 10.5056.
  - The minimum, p25, p75, p90 and maximum are identical for both conversion types and all five channels. Only the median differs, 10 or 11; it is 11 for trial, paid_search and paid_social. Means range from 10.3766 (video) to 10.5774 (paid_social).
- **4,716 conversions (share 0.118803) happen after their campaign's end date.** They are 1,951 purchases and 2,765 trials, with 2,532,266.74 of revenue, at most 21 days after the end date. 0 fall after the end of the documented coverage.

**Right-censoring** (`01 §8.5 [26]`):

| Last lead | Max lag | Max lag, 2023 leads | Latest possible conversion | Last observed conversion | Leads whose 21-day window ends after it | Complete by the observed data? | Assumed as-of date | Days to it, youngest lead | Mature if complete to it? |
|---|---:|---:|---|---|---:|---|---|---:|---|
| 2025-12-02 | 21 | 21 | 2025-12-23 | 2025-12-21 | 65 | False | 2025-12-31 | 29 | True |

- **21 days is the observed maximum lag, and censoring does not explain it.** It is also the maximum for 2023 leads, which had at least 721 days of later data in which to convert (2023-12-31 to 2025-12-21).
- **The observed data alone does not prove the youngest cohorts complete.** The 65 leads are those whose 21-day window reaches past 2025-12-21, i.e. leads created on 2025-12-01 or 2025-12-02 (the last lead date). They could have converted on 2025-12-22 or 2025-12-23 without the extract showing it.
- **Completeness is therefore an assumption.** *If* the extract is complete through the documented coverage end of 2025-12-31, the youngest lead had 29 days (more than 21), and no lead cohort is right-censored.

**Portfolio over time** (`01 §8.6 [27]`, `§8.7 [28]`):

| Start year | Campaigns started | Ended the same year | Crossed into the next year | Active in the year | Budget of the starts |
|---|---:|---:|---:|---:|---:|
| 2023 | 48 | 38 | 10 | 48 | 2,011,992.51 |
| 2024 | 50 | 37 | 13 | 60 | 2,458,235.85 |
| 2025 | 22 | 22 | 0 | 35 | 948,413.80 |
| **Total** | **120** | **97** | **23** | **143** | **5,418,642.16** |

- **Year-crossing campaigns.** 23 campaigns cross a year boundary, so "active campaigns per year" sums to 143, not 120. Budget is one amount per campaign and cannot be assigned to a single year or month without prorating it.
- **Monthly profile.** Active campaigns per month peak at 20 (2024-09).
- **The end of 2025.**
  - No campaign starts after 2025-08: 0 starts in 2025-09 to 2025-12.
  - Active campaigns fall to 11 / 5 / 3 / 1 in 2025-09 to 2025-12. 2025-12 has one active campaign; the last end date is 2025-12-02.
  - In all 36 months, the campaigns active by their window equal the campaigns with a spend row.

**Edge months:** the first and last six months, with each fact aggregated to the month on its
own (`01 §10.3 [32]`).

| Month | Spend | Leads | Conversions in the month (activity) | Conversions of the month's leads (cohort) |
|---|---:|---:|---:|---:|
| 2023-01 | 23,686.55 | 1,325 | 110 | 212 |
| 2023-02 | 49,461.61 | 2,825 | 325 | 427 |
| 2023-03 | 104,283.65 | 6,229 | 798 | 914 |
| 2023-04 | 104,393.90 | 5,748 | 902 | 880 |
| 2023-05 | 97,734.10 | 5,188 | 811 | 771 |
| 2023-06 | 123,064.68 | 7,491 | 963 | 1,137 |
| ... | | | | |
| 2025-07 | 132,922.32 | 7,710 | 1,101 | 1,156 |
| 2025-08 | 138,359.57 | 7,339 | 1,190 | 1,109 |
| 2025-09 | 65,610.05 | 3,680 | 700 | 513 |
| 2025-10 | 48,774.54 | 2,826 | 462 | 445 |
| 2025-11 | 16,510.95 | 1,093 | 256 | 173 |
| 2025-12 | 807.04 | 65 | 61 | 11 |

The two conversion columns answer different questions, and mixing them produces nonsense at the
edges. Dividing activity conversions by the same month's leads gives 110 / 1,325 = 8.3% in
2023-01 and 61 / 65 = 93.8% in 2025-12. The lead-cohort ratio for the same months is
212 / 1,325 = 16.0% and 11 / 65 = 16.9%.

## The grain trap

`daily_spend` is one row per campaign × day; `leads` is one row per lead. Joining them row by row
repeats every spend row once per matching lead (`01 §9 [29]`):

| Method | Joined rows | Total spend | Inflation |
|---|---:|---:|---:|
| `SUM(spend)` over `daily_spend` (correct) | 11,240 | 4,523,050.02 | 1.000000 |
| **ANTI-PATTERN:** `daily_spend JOIN leads ON campaign_id` | 25,941,510 | 11,286,380,144.15 | 2,495.302969 |
| **ANTI-PATTERN:** join on `campaign_id` and the same date | 261,684 | 123,557,885.18 | 27.317382 |

Adding the date to the join key does not fix it, because each lead still copies its day's spend.
The PASS on this block means the anti-pattern reproduces its documented inflation, not that it is
acceptable. The two cross-table business rules were evaluated at the correct grain for the same
reason (`01 §6.4 [17]`): campaign spend is summed per campaign before it is compared with the
budget, and leads are counted per campaign × date before they are compared with that day's
clicks.

## First look

### The plan's starter query

`LEAD_SCORE` is VARCHAR in RAW, so the query casts it explicitly and shows the denominator that
`AVG` really uses (`01 §10.1 [30]`; the evidence rounds the average to 4 dp):

```sql
SELECT LEAD_SOURCE,
       COUNT(*)                         AS TOTAL_LEADS,
       COUNT(TRY_TO_NUMBER(LEAD_SCORE)) AS SCORED_LEADS,
       AVG(TRY_TO_NUMBER(LEAD_SCORE))   AS AVG_LEAD_SCORE
FROM MARKETING_CRM.RAW.LEADS
GROUP BY LEAD_SOURCE;
```

| lead_source | Total leads | Scored leads | Avg lead score |
|---|---:|---:|---:|
| affiliate | 67,849 | 67,849 | 50.5620 |
| paid_search | 65,268 | 65,268 | 50.6614 |
| paid_social | 57,619 | 57,619 | 50.4742 |
| display | 45,149 | 45,149 | 50.5366 |
| video | 25,799 | 25,799 | 50.6429 |

- **Why the cast.** The plan's uncast `AVG(LEAD_SCORE)` also runs, but only through implicit VARCHAR → FLOAT coercion: it returns a binary FLOAT and aborts the whole query on any non-numeric value (see the comment of block 10.1). `TRY_TO_NUMBER` gives an explicit NUMBER and turns a bad value into NULL, which `AVG` then skips. That is why `SCORED_LEADS` is shown: here it equals `TOTAL_LEADS` for every source.
- **The result.** Affiliate and paid search have the most leads, video the fewest. The average scores span 50.4742 to 50.6614, a range of 50.6614 − 50.4742 = 0.1872 points. This page draws no conclusion from that about lead quality by source; whether the score relates to conversion is a Phase 4 question.

### Channel summary, grain-safe

Each fact is aggregated to the channel on its own and then joined 1:1 (`01 §10.2 [31]`):
`daily_spend` → campaigns, and conversions → leads → campaigns. **Spend and attributed revenue
per channel equal the publisher's reference output to the cent** (the output of its starter
query on the dataset page, tagged `[PUB]` in the header of `01_data_profiling.sql`). For these
two measures, that is an outside check of the path from the published files through RAW to the
query.

| Channel | Campaigns | Spend | Impressions | Clicks | Leads | Conversions | Purchases | Attributed revenue |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| affiliate | 24 | 857,835.07 | 95,314,042 | 2,386,856 | 67,849 | 10,352 | 4,332 | 5,610,700.73 |
| paid_search | 24 | 897,091.53 | 49,837,405 | 1,740,314 | 65,268 | 10,019 | 4,204 | 5,439,329.35 |
| paid_social | 24 | 984,731.88 | 89,520,215 | 1,602,785 | 57,619 | 8,648 | 3,646 | 4,690,137.28 |
| display | 24 | 955,297.00 | 146,967,688 | 879,874 | 45,149 | 6,744 | 2,871 | 3,734,117.43 |
| video | 24 | 828,094.54 | 55,205,469 | 492,490 | 25,799 | 3,933 | 1,638 | 2,087,554.22 |
| **Total** | **120** | **4,523,050.02** | **436,844,819** | **7,102,319** | **261,684** | **39,696** | **16,691** | **21,561,839.01** |

- **Columns.** `Conversions` counts converted leads of either type; `Purchases` counts purchases only.
- **Revenue.** It is last-touch attributed revenue, not causal impact.
- **Ratios.** CTR, CPL, ROAS and the conversion rates are Phase 4, and they will be ratios of these sums.

## Cleaning-challenge extracts

The publisher ships dirty extracts and names only the defect classes. `01b` locates each
defective cell with generic rules applied to the challenge files themselves; the two catch-all
classes find nothing beyond the 15 defects. The clean release is used only to check
that each extract is a subset of it (section 1) and to preview the Phase 3 reconciliation
(section 8), never as an input to a fix.

**Shape** (`01b 1b-1d [7-9]`):

- **Contiguous prefixes.** Each extract is the first 120 / 2,000 / 2,000 / 2,000 keys of the clean release, with 0 keys that are not in it.
- **Conversions point outside the leads extract by construction.** 1,687 of the 2,000 extract conversions point to leads outside the leads extract. All of those leads exist in the clean release (0 do not). This comes from how the extracts were cut, by `conversion_id` and by `lead_id`; it is not a defect.
- **The extracts are partial per campaign.**
  - Spend covers 22 complete campaigns (CMP0001..CMP0022) plus CMP0023 with 27 of 97 days.
  - Leads cover CMP0001 completely plus CMP0002 with 626 of 1,849 leads.
  - Conversions cover 7 complete campaigns (CMP0001..CMP0007) plus CMP0008 with 32 of 462.
  - CMP0001 is the only campaign complete in all three. Channel or portfolio funnel KPIs cannot be computed from the extracts; only CMP0001 can be reconciled end to end (block `8c` below).

**The 15 defects** (`01b 7 [30]`; data row = `_SOURCE_ROW_NUMBER`, file line = data row + 1):

| # | Class | Cell | Raw value | Data row (line) | Resolution and evidence | Recoverable |
|---:|---|---|---|---|---|---|
| 1-4 | duplicate row | CMP0001, DSP0000001, L00000001, CV0000001 (whole row) | identical to row 1 | 121 / 2,001 / 2,001 / 2,001 (122 / 2,002 / 2,002 / 2,002) | Byte-identical copy of the first data row: same row hash, 0 keys whose copies differ, raw or normalized (`2a`, `2b`). Keep the first copy | yes |
| 5 | casing/whitespace | CMP0008 `campaign_name` | `[ DISPLAY 2023 008 ]` | 8 (9) | `INITCAP(TRIM())` → `Display 2023 008` (`3d`) | yes |
| 6 | casing/whitespace | L00000008 `lead_source` | `[ PAID_SEARCH ]` | 8 (9) | `LOWER(TRIM())` → `paid_search` | yes |
| 7 | casing/whitespace | CV0000008 `conversion_type` | `[ TRIAL ]` | 8 (9) | `LOWER(TRIM())` → `trial` | yes |
| 8 | slash date | CMP0018 `start_date` | `2023/05/15` | 18 (19) | Only Y/M/D is a date (15 cannot be a month); it equals the first spend_date | yes: 2023-05-15 |
| 9 | slash date | DSP0000018 `spend_date` | `2023/07/04` | 18 (19) | Ambiguous by syntax. The spend_id neighbours ±1 day allow only 2023-07-04; Y/D/M (2023-04-07) is outside CMP0001's window, 2023-06-17..2023-08-17 | yes: 2023-07-04 |
| 10 | slash date | L00000018 `created_at` | `2023/06/17` | 18 (19) | Only Y/M/D is a date (17 cannot be a month); it fits the lead_id neighbours | yes: 2023-06-17 |
| 11 | slash date | CV0000018 `converted_at` | `2023/07/05` | 18 (19) | Ambiguous by syntax. Lead created_at + 0..21 days allows 2023-06-22..2023-07-13; Y/D/M (2023-05-07) is outside | yes: 2023-07-05 |
| 12 | blank required value | CMP0030 `campaign_name` | `[]` | 30 (31) | Naming rule `channel + year(start) + id[-3:]` holds for 119/119 named campaigns: 1 candidate (`5b`, `5c`) | yes: Affiliate 2024 030 |
| 13 | blank required value | DSP0000030 `spend_date` | `[]` | 30 (31) | spend_id neighbours: 1 candidate. Confirmed order-free by CMP0001's date spine: 62 window days, 61 dated rows, the one missing day is 2023-07-16 (`5d`) | yes: 2023-07-16 |
| 14 | blank required value | L00000030 `created_at` | `[]` | 30 (31) | lead_id neighbours allow 2023-06-17..2023-06-18: 2 candidates | **no** |
| 15 | blank required value | CV0000030 `converted_at` | `[]` | 30 (31) | Lead L00000199 created 2023-06-26 + 0..21 days: 22 candidates (2023-06-26..2023-07-17). Conversion neighbours do not help: conversion_ids follow lead order, not time (the date is non-decreasing for only 1,078 of 1,995 consecutive pairs, `4c` I7) | **no** |

- **No other defects.** The two catch-all classes ("other date defect", "other nonconforming") count 0 (`01b 7 [30]`).
- **Numbers.** Every numeric cell has a standard shape and casts cleanly, with no negatives. The only zeros are the 1,132 trial revenues (`01b 6a [28]`).
- **Business rules.** The 10 rule checks of block 6b find 0 violations on the de-duplicated, normalized rows (`01b 6b [29]`), including lead_source = campaign channel for all 2,000 leads. They are not the same 10 rules as the clean release's `§6.4`: 6b adds the date and channel rules that the clean release checks in `§7.3` and `§8` (conversion before its lead, end before start, campaign window, documented coverage, lead_source = channel), leaves the "> 0" checks to 6a, and does not include the two campaign-level rules (total spend ≤ budget, leads ≤ clicks).

**Why it matters: the starter query on the dirty extract** (`01b 3e [19]`):

| Version | lead_source | Leads | Avg lead score |
|---|---|---:|---:|
| raw, as loaded | `[ PAID_SEARCH ]` | 1 | 73.00 |
| raw, as loaded | `[paid_search]` | 1,374 | 49.68 |
| raw, as loaded | `[paid_social]` | 626 | 48.31 |
| cleaned (TRIM/LOWER, de-duplicated) | `paid_search` | 1,374 | 49.72 |
| cleaned | `paid_social` | 626 | 48.31 |

The raw paid_search count looks right only by coincidence: it includes the duplicate of
L00000001 and misses L00000008, so its average is wrong.

**Reconciliation preview** (`01b 8a-8c [31-33]`). The cleaning rules run inline here, read-only;
Phase 3 implements them as models:

- **The rules.** De-duplicate, normalize ids, codes and names, route dates by shape, turn blanks into NULL, and apply only the two provable fills.
- **Row level.**
  - With the blanks left NULL, 6,116 of 6,120 rows reproduce the clean release exactly.
  - With the two fills, 6,118 of 6,120 do.
  - The 2 rows that never match are L00000030 and CV0000030. Their cleaned date stays NULL; the clean release has 2023-06-18 and 2023-07-13. No residual mismatch is a wrong non-NULL value.

**Aggregate level:** CMP0001 (the only campaign complete in all three fact extracts), plus the
total budget over all campaigns. Each metric is aggregated on its own.

| Version | Spend | Impressions | Clicks | Leads | Conversions | Revenue | Budget, all campaigns |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw extract, as loaded | 13,899.32 | 772,156 | 26,562 | 1,375 | 214 | 105,014.02 | 5,433,509.32 |
| extract de-duplicated | 13,679.39 | 759,938 | 26,014 | 1,374 | 213 | 105,014.02 | 5,418,642.16 |
| clean release | 13,679.39 | 759,938 | 26,014 | 1,374 | 213 | 105,014.02 | 5,418,642.16 |

The duplicates add one spend day (13,899.32 − 13,679.39 = 219.93), one lead, one conversion
with 0.00 revenue, and CMP0001's budget a second time (5,433,509.32 − 5,418,642.16 = 14,867.16).

## Implications for Phase 3 and Phase 4

These are design inputs that follow from the facts above. They are not results.

**STAGING (Phase 3).**

- **Casts need a pattern and a TRY_ cast together** (`01 §2.2 [7]`). Snowflake's TRY_ casts are lenient:
  - `TRY_TO_DATE('2023-1-5', 'YYYY-MM-DD')` returns 2023-01-05.
  - `TRY_TO_NUMBER(' 42')` and `TRY_TO_NUMBER('42.0')` return 42.
  - `TRY_TO_NUMBER('1250.405', 12, 2)` silently rounds to 1250.41.
  - A pattern alone would accept `2023-02-29`, whose cast is NULL.

  Each column will therefore be typed only if it matches its pattern (`YYYY-MM-DD`, digits, or
  digits + 2 decimals) **and** the cast succeeds. On the clean release this changes nothing
  (0 non-conforming values, `01 §2.1 [6]`). On the challenge extracts, the same gate, extended
  with the code and name patterns, flags all 11 cell-level defects: 4 blank and 7
  non-conforming cells (`01b 1f [11]`). The 4 duplicate rows need the key check of `2a`.
- **Tests.** The Phase 2 checks will become the STAGING tests:
  - unique: the four PKs, `campaign_name`, `(campaign_id, spend_date)`, `conversions.lead_id`;
  - not null on all 23 business columns;
  - accepted values for the four code columns;
  - relationships for the three foreign keys;
  - the 10 business rules as expression tests;
  - exact control totals: spend 4,523,050.02, revenue 21,561,839.01.
- **Keep every row.** The 1.5 × IQR outliers pass every business rule, so STAGING will not trim or winsorise. Outlier review, if any, will be done within a channel, because the high outliers concentrate in particular channels (display has 189 of the 301 impression outliers, affiliate 370 of the 559 click outliers, video none of either).
- **Cleaning-challenge track.** `STG_CHALLENGE_*` models (dbt: `stg_challenge_*`) will follow the rules previewed in `01b` section 8:
  - keep the first copy (`QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY _SOURCE_ROW_NUMBER) = 1`);
  - `LOWER(TRIM())` for codes, `INITCAP(TRIM())` for names only;
  - read year-first slash dates as Y/M/D;
  - turn blanks into NULL with a missing-value flag;
  - put the two provable fills in separate `*_filled` columns.

  The reconciliation test will then expect 6,118 of 6,120 matching rows. MART and the dashboard
  stay on the clean release. Phase 3 refines the `01b` section 8 preview in four documented ways
  (de-dup order, trim characters, number patterns, blank ids) without changing any value; see
  [Refinements over the Phase 2 preview](data_cleaning.md#refinements-over-the-phase-2-preview).
  Its gates read the trimmed value, so a padded number such as `' 42'` keeps its value but is
  flagged `untrimmed`, never accepted silently
  ([rule 4](data_cleaning.md#4-numbers-pattern-and-cast-with-explicit-precision); the rules are in
  `dbt/macros/staging/clean_*.sql`).

**MART and the analyses (Phase 4).**

- **Aggregate first, then join.** Spend, leads and conversions will be aggregated separately to a common grain (campaign, campaign × date, channel or month) before any join (see [The grain trap](#the-grain-trap)). Ratios will be ratios of sums. A test in `make dbt-build` (`assert_total_spend_in_every_mart`) fails if total spend in any MART table differs from 4,523,050.02.
- **Activity fact on a daily spine to `end_date + 21`.** 4,716 conversions, with 2,532,266.74 of revenue, land up to 21 days after their campaign ends. A campaign × date spine built only from `daily_spend` rows, or a "within the campaign window" filter, would drop them.
- **Lead-cohort fact, separate from the activity fact.** One row per lead, with conversion flag, type, lag and revenue, by the lead's cohort month. It will take an `as_of_date` parameter (2025-12-31, an assumption; see right-censoring under [Time](#time)) and flag maturity as `created_at <= as_of_date - 21`. Activity-month and cohort-month series must never be blended on one date axis (2025-12: 61 activity conversions, but 11 converted leads of 65).
- **Budget proration for monthly and yearly views.** Budget is one amount per campaign, and 23 campaigns cross a year boundary. Monthly and yearly budget figures must prorate it by window days. Budget utilisation will be computed only at campaign grain.
- **`dim_date` and a fixed dashboard date range.** `dim_date` will span the full documented coverage, 1,096 days (1,064 spend dates + 32 empty days), so empty days show as 0. Activity ends on 2025-12-02 (conversions on 2025-12-21), so relative ranges such as "last 28 days" are empty. The dashboard will use the fixed range 2023-01-01 to 2025-12-31.
- **`channel` is the canonical channel dimension.** It comes from `campaigns`, via `dim_campaign`. `lead_source` duplicates it: 0 mismatches over 261,684 leads, and 0 over the 2,000 challenge leads. STAGING will keep `lead_source` with a warning test, because the challenge extract shows the column can drift (`' PAID_SEARCH '`).
- **Guards.** The 7 spend days with zero leads need `NULLIF(leads, 0)` in cost per lead. 221,988 leads (share 0.848306) never convert, so lead-level models must LEFT JOIN conversions.
- **Read monthly comparisons against the active-campaign count.** It ranges from 1 to 20 per month and falls to 5 / 3 / 1 in Oct-Dec 2025.
- **Compare objectives within a channel.** Channel and objective are partly confounded: display is 17/24 lead_gen.

## Caveats

- **Synthetic data.** The dataset models a fictional business, with no real companies, people or industry benchmarks ([data_source.md](data_source.md)). Nothing here is a benchmark.
- **Regularities may be generator artefacts.** Exactly 24 campaigns per channel, a near-uniform lead score, the same lag percentiles in every channel and the late-2025 drop in active campaigns are properties of this deterministic synthetic data. They are recorded as shape facts, not read as marketing behaviour.
- **Last-touch attribution.** Revenue by channel is attributed revenue, not causal impact. Offline and view-through conversions are not included.
- **Descriptive facts, not insights.** This page states what the data contains and how it is shaped. Why a channel has more leads, why 2025 has fewer campaigns, or whether lead score predicts conversion is not addressed. Those are Phase 4 questions, and some cannot be answered from this data at all.
- **Assumptions are labelled as such.** The maturity of the youngest lead cohorts rests on the assumption that the extract is complete through 2025-12-31.
