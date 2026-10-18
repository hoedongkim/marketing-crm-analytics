# KPI definitions

Every KPI of the four dashboard pages, plus the extra KPIs built in Phase 4, defined once:
formula, numerator and denominator, time basis, the grain at which a stored ratio is valid, the
MART table and columns it comes from, the exact Data Studio calculated field, its value over the
full range, and its caveats. The [coverage matrix](#coverage-matrix) at the end maps each dashboard
page to its KPIs and MART tables, with the SQL output that computes and checks each one.

Status (2026-10-14): written in Phase 4, after `make analysis-marts analyses` ran with 0 FAIL rows.
Phase 5 rebuilt every MART table with dbt under the same names, with identical rows, and the files
behind the MART values on this page (`02cT`, `03` to `06`) print identical output on the dbt build
([dbt.md](dbt.md#parity-with-the-hand-written-sql-build)). Phase 6 builds the Data Studio fields
listed here; Phase 7 does a final pass. Phase 6 also added one dbt table for the funnel chart,
`MART_CONVERSION_FUNNEL` ([Funnel stages and stage conversion](#funnel-stages-and-stage-conversion),
evidence `06F`).

How to read this page:

- **Values** are copied from the evidence files, never typed in by hand. Sources are given as
  *file [statement]*; the statement map in each SQL file's header gives the block. In `06` each
  result is followed by its check statement (`06 [8]` checks `06 [7]`, and so on). The few values
  that are arithmetic on printed numbers (a ratio of two printed costs) say so where they appear.

  | Tag | Evidence file | Produced by |
  |---|---|---|
  | `01` | [`evidence/01_data_profiling.txt`](evidence/01_data_profiling.txt) | `sql/01_data_profiling.sql` (Phase 2 profile of RAW) |
  | `02cT` | [`evidence/02c_analysis_marts_tests.txt`](evidence/02c_analysis_marts_tests.txt) | `sql/02c_analysis_marts_tests.sql` (tests of the Phase 4 marts) |
  | `03` | [`evidence/03_overview.txt`](evidence/03_overview.txt) | `sql/03_marketing_overview.sql` (page 1) |
  | `04` | [`evidence/04_funnel.txt`](evidence/04_funnel.txt) | `sql/04_conversion_funnel.sql` (page 2) |
  | `05` | [`evidence/05_lead.txt`](evidence/05_lead.txt) | `sql/05_lead_analysis.sql` (page 3) |
  | `06` | [`evidence/06_efficiency.txt`](evidence/06_efficiency.txt) | `sql/06_marketing_efficiency.sql` (page 4) |
  | `06F` | [`evidence/06_funnel_mart.txt`](evidence/06_funnel_mart.txt) | Phase 6: build and tests of `MART_CONVERSION_FUNNEL`; cited as *step [statement]*, e.g. `06F 7 [9]` |

- **Tables and columns** are described in [data_dictionary.md](data_dictionary.md); the stored
  ratio columns of `MART_CAMPAIGN_PERFORMANCE` are defined there too
  ([KPI definitions: MART_CAMPAIGN_PERFORMANCE](data_dictionary.md#kpi-definitions-mart_campaign_performance)).
- **Rounding** of stored ratios: rates, ROAS and shares 6 dp, cost per unit 4 dp, each rounded once
  from the exact quotient (`sql/02b_core_models.sql`, "Rounding").

## Contents

1. [Rules for every KPI](#rules-for-every-kpi)
2. [Quick reference: the Data Studio fields](#quick-reference-the-data-studio-fields)
3. [Base measures](#base-measures)
4. [Delivery and funnel ratios](#delivery-and-funnel-ratios)
5. [Cost and return](#cost-and-return)
6. [Mix, shares and uncertainty](#mix-shares-and-uncertainty)
7. [Lead quality and time to conversion](#lead-quality-and-time-to-conversion)
8. [Coverage matrix](#coverage-matrix)
9. [Notes for Phase 6](#notes-for-phase-6)

## Rules for every KPI

These follow from [architecture.md](architecture.md#design-decisions), decisions 6, 7 and 9.

1. **A ratio is a ratio of sums.** Every ratio in a chart that aggregates rows (a channel, a
   month range, a scorecard) is `SUM(numerator) / SUM(denominator)` over the additive base
   columns. Never `SUM` or `AVG` a stored ratio column: an average of campaign or daily ratios
   weights every row equally, whatever its size. Example: the average of the 11,233 defined
   daily CPLs is 20.8479, the ratio of sums is 17.2844 (`04 [14]`).
2. **Stored ratios only at their own grain.** `MART_CAMPAIGN_PERFORMANCE` ratios are valid in a
   table with one row per campaign; `MART_CHANNEL_PERFORMANCE` ratios in a table with one row per
   channel over the full range. No other MART table stores a ratio.
3. **Two time bases, never mixed.** *Activity* figures count each event on its own date (spend by
   spend date, leads by created date, conversions and revenue by converted date): what happened in
   a period. *Lead-cohort* figures count what the leads created in a period later did. A
   conversion rate exists only on the cohort basis. `CONVERSIONS / LEADS` of the same month
   (activity) is not a rate: it swings from 0.083019 to 0.938462 by month while the cohort rate
   stays between 0.139402 and 0.169231 (`04 [17]`). Activity and cohort months are never put on
   one date axis.
4. **The funnel is an aggregate campaign funnel.** Impressions, clicks, leads and conversions are
   different units. Click-to-lead rate and lead conversion rate are ratios of campaign totals, not
   one person's probabilities. A lead converts at most once, to a trial **or** a purchase, so
   trials and purchases are parallel outcomes, not stages.
5. **Budget is additive across campaigns, not across dates.** Budget utilisation uses whole
   campaigns (campaign or channel grain, full range). `BUDGET_PRORATED` spreads each budget evenly
   over its flight days for planning views by month or year; that spread is an assumption, so
   `SPEND / BUDGET_PRORATED` of a month is pacing against it, not utilisation.
6. **Revenue is last-touch attributed.** ROAS and revenue by channel or campaign describe
   attribution, not the causal effect of the spend.
7. **Synthetic data.** Regular patterns (near-round CPM per channel, a flat 0-21 day lag, a
   35-lead daily ceiling) are generator properties, not market facts (`04 [13]`, `04 [19]`,
   `06 [37]`).

## Quick reference: the Data Studio fields

Architecture decision 9 allows only thin ratios of sums as Data Studio calculated fields. This is
the complete list, so each one can be recreated exactly after the Google Sheets swap. Field names
are the UPPERCASE MART column names. "Full range" is 2023-01-01..2025-12-31, all channels.

Each field is valid only on the data sources named in its row: they carry both columns **and**
keep the KPI on its basis. Some other tables carry the same column names on another basis, and
the field would compute there without an error but mean something else (for example
`SUM(PURCHASES) / SUM(LEADS)` on `MART_MONTHLY_MARKETING` divides purchases booked in a month by
the leads created in it). Short names: DAILY = `FCT_CAMPAIGN_DAILY_ACTIVITY`, MONTHLY =
`MART_MONTHLY_MARKETING`, COHORT = `MART_MONTHLY_COHORT`, CHANNEL = `MART_CHANNEL_PERFORMANCE`,
QUALITY = `MART_LEAD_QUALITY`, CAMPAIGN = `MART_CAMPAIGN_PERFORMANCE`, LEAD = `FCT_LEAD_CONVERSIONS`,
FUNNEL = `MART_CONVERSION_FUNNEL`.

| KPI | Data Studio calculated field | Basis | Valid data sources | Full range | Source |
|---|---|---|---|---:|---|
| [CTR](#ctr) | `SUM(CLICKS) / SUM(IMPRESSIONS)` | activity | DAILY, MONTHLY, CHANNEL, CAMPAIGN | 0.016258 | `03 [6]` |
| [CPC](#cpc-cost-per-click) | `SUM(SPEND) / SUM(CLICKS)` | activity | DAILY, MONTHLY, CHANNEL, CAMPAIGN | 0.6368 | `03 [6]` |
| [CPM](#cpm-cost-per-1000-impressions) | `SUM(SPEND) * 1000 / SUM(IMPRESSIONS)` | activity | DAILY, MONTHLY, CHANNEL, CAMPAIGN | 10.3539 | `04 [13]` |
| [Click-to-lead rate](#click-to-lead-rate) | `SUM(LEADS) / SUM(CLICKS)` | activity | DAILY, MONTHLY, CHANNEL, CAMPAIGN | 0.036845 | `03 [6]` |
| [Lead conversion rate](#lead-conversion-rate-the-conversion-rate) | `SUM(CONVERTED_LEADS) / SUM(LEADS)` | cohort | COHORT, QUALITY, CHANNEL, CAMPAIGN | 0.151694 | `03 [6]` |
| [Purchase rate](#purchase-rate) | `SUM(PURCHASES) / SUM(LEADS)` | cohort | COHORT, QUALITY, CHANNEL, CAMPAIGN (never DAILY or MONTHLY) | 0.063783 | `03 [6]` |
| [Purchase share of conversions](#purchase-share-of-conversions) | `SUM(PURCHASES) / SUM(CONVERTED_LEADS)` | cohort | COHORT, QUALITY, CHANNEL, CAMPAIGN | 0.420471 | `04 [6]` |
| [Cost per lead](#cost-per-lead-cpl) | `SUM(SPEND) / SUM(LEADS)` | activity | DAILY, MONTHLY, CHANNEL, CAMPAIGN | 17.2844 | `03 [6]` |
| [Cost per conversion](#cost-per-conversion) | `SUM(SPEND) / SUM(CONVERTED_LEADS)` | full range | CHANNEL, CAMPAIGN | 113.9422 | `04 [13]` |
| [Cost per purchase](#cost-per-purchase) | `SUM(SPEND) / SUM(PURCHASES)` | full range | CHANNEL, CAMPAIGN (never DAILY or MONTHLY) | 270.9874 | `04 [13]` |
| [ROAS](#roas) | `SUM(REVENUE) / SUM(SPEND)` | full range (or activity, labelled) | CHANNEL, CAMPAIGN; activity ROAS: MONTHLY, DAILY | 4.767102 | `03 [6]` |
| [Budget utilisation](#budget-utilisation) | `SUM(SPEND) / SUM(BUDGET)` | campaign / channel, whole campaigns | CAMPAIGN, CHANNEL | 0.834720 | `03 [6]` |
| [Average lead score](#average-lead-score) | `SUM(SUM_LEAD_SCORE) / SUM(LEADS)` | cohort | QUALITY | 50.5711 | `05 [10]` |
| [Mean time to conversion](#time-to-conversion) | `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)` | cohort | COHORT, QUALITY | 10.5056 | `02cT [16]` |
| [Cross-month share](#time-to-conversion) | `SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS)` | cohort | COHORT | 0.344493 | `02cT [16]` |
| [After-campaign-end share](#time-to-conversion) | `SUM(CONVERTED_AFTER_CAMPAIGN_END) / SUM(IS_CONVERTED)` | cohort | LEAD | 0.118803 | `05 [15]` |
| [Stage conversion](#funnel-stages-and-stage-conversion) | `SUM(STAGE_VALUE) / SUM(PREV_STAGE_VALUE)` | full range, per stage | FUNNEL, only with `STAGE` as the dimension | Clicks 0.016258, Leads 0.036845, Converted leads 0.151694, Purchases 0.420471 (Impressions: no value) | `06F 7 [9]` |
| [Share of top of funnel](#funnel-stages-and-stage-conversion) | `SUM(STAGE_VALUE) / SUM(TOP_OF_FUNNEL_VALUE)` | full range, per stage | FUNNEL, only with `STAGE` as the dimension | Impressions 1, Clicks 0.01625822, Leads 0.00059903, Converted leads 0.00009087, Purchases 0.00003821 | `06F 7 [9]` |

Not calculated fields: the shares (use the stored channel columns or Data Studio's *Percent of
total* comparison, see [Shares](#shares-of-spend-leads-and-revenue)), the Wilson interval (stored at
channel grain only), and the lag median and percentiles (SQL; see
[Notes for Phase 6](#notes-for-phase-6)).

## Base measures

Additive columns: `SUM` them over any rows of their table. Each total below equals the known
total in every MART table that carries it (`02cT [10]`).

### Campaigns

| | |
|---|---|
| Definition | Number of campaigns. Over the full range: all campaigns. Over a period: campaigns **in flight** on at least one day of it (active campaigns). |
| Basis / grain | Campaign attribute (full range); activity (a period). |
| Source | Full range: `MART_CHANNEL_PERFORMANCE.CAMPAIGNS` (24 per channel), or one row per campaign in `MART_CAMPAIGN_PERFORMANCE`. A period: `FCT_CAMPAIGN_DAILY_ACTIVITY` (`CAMPAIGN_ID`, `IS_IN_FLIGHT`). Per month: `MART_MONTHLY_MARKETING.ACTIVE_CAMPAIGNS`. |
| Data Studio | Full range: `SUM(CAMPAIGNS)` on `MART_CHANNEL_PERFORMANCE`. A period: `COUNT_DISTINCT(CAMPAIGN_ID)` on `FCT_CAMPAIGN_DAILY_ACTIVITY` with a chart filter `IS_IN_FLIGHT = 1`. |
| Value | 120 campaigns (`03 [6]`). Started per year 48 / 50 / 22, active per year 48 / 60 / 35 (2023 / 2024 / 2025, `03 [12]`). Active per month 1 to 20 (`03 [7]`). |
| Caveats | `ACTIVE_CAMPAIGNS` is additive across channels within one month but **not across months**: over the 180 rows it sums to 490 campaign-months, not 120 campaigns (`02cT [18]`). A campaign counts as "active" whether it is in flight on one day of the period or on all of them, so campaign-days are the better exposure measure for trends (`03 [13]`). `START_YEAR` / `START_MONTH` are campaign attributes, not activity dates (23 campaigns cross into the next year, `01 [27]`). |

### Spend, impressions, clicks

| | |
|---|---|
| Definition | Media spend, ad impressions and clicks delivered. |
| Basis / grain | Activity, by spend date. Any grain. |
| Source | `SPEND`, `IMPRESSIONS`, `CLICKS` in `FCT_CAMPAIGN_DAILY_ACTIVITY` (day), `MART_MONTHLY_MARKETING` (month), `MART_CHANNEL_PERFORMANCE` (channel), `MART_CAMPAIGN_PERFORMANCE` (campaign). |
| Data Studio | `SUM(SPEND)`, `SUM(IMPRESSIONS)`, `SUM(CLICKS)` (the default aggregation). |
| Value | Spend 4,523,050.02; impressions 436,844,819; clicks 7,102,319 (`03 [6]`). Spend per year 1,458,262.41 / 1,971,198.34 / 1,093,589.27 (`03 [12]`). |
| Caveats | Spend is 0 on the 21 post-flight days of each campaign in `FCT_CAMPAIGN_DAILY_ACTIVITY` (`IS_IN_FLIGHT = 0`, `02cT [9]`). |

### Leads

| | |
|---|---|
| Definition | Leads created, attributed (last touch) to a campaign. |
| Basis / grain | Activity by created date. For leads the created month is also the cohort month, so `MART_MONTHLY_MARKETING.LEADS` and `MART_MONTHLY_COHORT.LEADS` agree month by month. |
| Source | `LEADS` in `FCT_CAMPAIGN_DAILY_ACTIVITY`, `MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT`, `MART_CHANNEL_PERFORMANCE`, `MART_LEAD_QUALITY`, `MART_CAMPAIGN_PERFORMANCE`. |
| Data Studio | `SUM(LEADS)`. |
| Value | 261,684 (`03 [6]`); by channel 25,799 (video) to 67,849 (affiliate) (`03 [8]`). |
| Caveats | A lead is credited to one campaign by the dataset's last-touch attribution. Lead volume follows the number of running campaigns (`03 [11]`). |

### Conversions (converted leads), trials, purchases

| | |
|---|---|
| Definition | Leads that converted, to a trial or a purchase (each lead at most once). `TRIALS + PURCHASES = CONVERTED_LEADS`. |
| Basis / grain | **Activity** (`CONVERSIONS` by converted date) or **cohort** (`CONVERTED_LEADS` in the lead's created month). Same total, different months: 13,675 of 39,696 conversions land in a later month than their lead (`02cT [16]`). |
| Source | Activity: `MART_MONTHLY_MARKETING.CONVERSIONS`, `FCT_CAMPAIGN_DAILY_ACTIVITY.CONVERSIONS`, plus `TRIALS`, `PURCHASES`. Cohort: `MART_MONTHLY_COHORT.CONVERTED_LEADS`, `MART_LEAD_QUALITY.CONVERTED_LEADS`. Full range: `MART_CHANNEL_PERFORMANCE.CONVERTED_LEADS`, `MART_CAMPAIGN_PERFORMANCE.CONVERTED_LEADS`. |
| Data Studio | `SUM(CONVERSIONS)` (activity tables) or `SUM(CONVERTED_LEADS)` (cohort and full-range tables); `SUM(TRIALS)`, `SUM(PURCHASES)`. |
| Value | 39,696 converted leads: 23,005 trials and 16,691 purchases (`03 [6]`). |
| Caveats | A trial is not a stage before a purchase: no table can follow a trial to a purchase. On a time axis label which basis is shown; never divide activity `CONVERSIONS` by `LEADS` of the same period. |

### Attributed revenue

| | |
|---|---|
| Definition | Last-touch attributed revenue of the converted leads; 0.00 for trials. |
| Basis / grain | Activity (`REVENUE` booked by converted date) in `FCT_CAMPAIGN_DAILY_ACTIVITY` and `MART_MONTHLY_MARKETING`; cohort (revenue of the leads created in the month) in `MART_MONTHLY_COHORT`; full range in `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`, `MART_LEAD_QUALITY`. |
| Data Studio | `SUM(REVENUE)`. |
| Value | 21,561,839.01 (`03 [6]`); 2,532,266.74 of it booked after the campaign ended (`05 [15]`). |
| Caveats | Attributed, not causal. Offline and view-through conversions are not in the data. |

### Budget

| | |
|---|---|
| Definition | Planned budget of a whole campaign window. `BUDGET_PRORATED` = `BUDGET / CAMPAIGN_DAYS` on each flight day (an even spread, an assumption). |
| Basis / grain | `BUDGET`: campaign attribute, additive across campaigns, **not across dates**. `BUDGET_PRORATED`: additive across days, months and campaigns. |
| Source | `BUDGET` in `MART_CAMPAIGN_PERFORMANCE`, `MART_CHANNEL_PERFORMANCE`; `BUDGET_PRORATED` in `FCT_CAMPAIGN_DAILY_ACTIVITY`, `MART_MONTHLY_MARKETING`. |
| Data Studio | `SUM(BUDGET)` (campaign or channel tables only); `SUM(BUDGET_PRORATED)` for a month or year. |
| Value | 5,418,642.16; prorated total 5,418,642.159820 (`02cT [10]`); prorated per year 1,750,679.286340 / 2,349,894.124804 / 1,318,068.748676 (`02cT [18]`). |
| Caveats | See [Budget utilisation](#budget-utilisation). |

## Delivery and funnel ratios

### CTR

| | |
|---|---|
| Formula | Clicks per impression: `CLICKS / IMPRESSIONS`. |
| Numerator / denominator | `CLICKS` / `IMPRESSIONS`, both by spend date. |
| Basis | Activity (delivery). |
| Stored ratio valid at | Campaign (`MART_CAMPAIGN_PERFORMANCE.CTR`), channel (`MART_CHANNEL_PERFORMANCE.CTR`). |
| Recompute from | `CLICKS`, `IMPRESSIONS` of `MART_MONTHLY_MARKETING`, `FCT_CAMPAIGN_DAILY_ACTIVITY`, `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`. |
| Data Studio | `SUM(CLICKS) / SUM(IMPRESSIONS)` |
| Value | 0.016258 (`03 [6]`); by channel 0.005987 (display) to 0.034920 (paid_search) (`04 [6]`). |
| Caveats | Synthetic delivery data. |

### CPC (cost per click)

*Extra KPI, built in Phase 4.*

| | |
|---|---|
| Formula | `SPEND / CLICKS`. |
| Basis | Activity. |
| Stored ratio valid at | Channel (`MART_CHANNEL_PERFORMANCE.CPC`). |
| Recompute from | `SPEND`, `CLICKS` of any delivery table. |
| Data Studio | `SUM(SPEND) / SUM(CLICKS)` |
| Value | 0.6368 (`03 [6]`); by channel 0.3594 (affiliate) to 1.6814 (video) (`04 [13]`). |
| Caveats | The channel order of CPC is the channel order of cost per lead and cost per purchase (`04 [13]`): in this data the cost gap between channels is made at the click. |

### CPM (cost per 1,000 impressions)

*Extra KPI, built in Phase 4.*

| | |
|---|---|
| Formula | `SPEND x 1000 / IMPRESSIONS`. |
| Basis | Activity. |
| Stored ratio valid at | Channel (`MART_CHANNEL_PERFORMANCE.CPM`). |
| Data Studio | `SUM(SPEND) * 1000 / SUM(IMPRESSIONS)` |
| Value | 10.3539 overall; by channel 6.5000 (display), 9.0001 (affiliate), 11.0001 (paid_social), 15.0002 (video), 18.0004 (paid_search) (`04 [13]`). |
| Caveats | Near-round and fixed per channel on every day (`06 [37]`: daily CPM within 9.0000-9.0008 for affiliate, for example): a generator constant, not a market price. |

### Click-to-lead rate

| | |
|---|---|
| Formula | `LEADS / CLICKS`. |
| Basis | Activity (leads by created date, clicks by spend date). |
| Stored ratio valid at | Campaign, channel (`CLICK_TO_LEAD_RATE`). |
| Data Studio | `SUM(LEADS) / SUM(CLICKS)` |
| Value | 0.036845 (`03 [6]`); by channel 0.028426 (affiliate) to 0.052385 (video) (`04 [6]`). |
| Caveats | A ratio of two different units (aggregate funnel), not the probability that a clicking person becomes a lead. |

### Lead conversion rate (the "conversion rate")

The Marketing Overview's "conversion rate" and the funnel's "lead conversion rate" are the same KPI.

| | |
|---|---|
| Formula | Converted leads (trial or purchase) per lead: `CONVERTED_LEADS / LEADS`. |
| Numerator / denominator | `CONVERTED_LEADS` / `LEADS` of the **same leads**. |
| Basis | Lead cohort only. Over a period it means "of the leads created in the period, the share that converted (within the observed 0-21 days)". |
| Stored ratio valid at | Campaign, channel (`LEAD_CONVERSION_RATE`). |
| Recompute from | `MART_MONTHLY_COHORT` (by cohort month), `MART_LEAD_QUALITY` (by score band), `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`. **Not** from `MART_MONTHLY_MARKETING` or `FCT_CAMPAIGN_DAILY_ACTIVITY` (activity tables have no `CONVERTED_LEADS`). |
| Data Studio | `SUM(CONVERTED_LEADS) / SUM(LEADS)` |
| Value | 0.151694 (`03 [6]`); by channel 0.149372 (display) to 0.153506 (paid_search) (`04 [8]`), every channel's Wilson 95% interval containing the pooled rate (`02cT [21]`); by cohort month 0.139402 (2025-09) to 0.169231 (2025-12) (`04 [17]`). |
| Caveats | Channel differences are not distinguishable from sampling noise (chi-square 5.231237 on 4 df, p 0.264383, `04 [9]`). The youngest cohorts are assumed complete (as-of date 2025-12-31, an assumption). A date-range control on `MART_MONTHLY_COHORT` filters by `COHORT_MONTH`, i.e. by when the leads were created: label the scorecard accordingly. |

### Purchase rate

*Extra KPI, built in Phase 4 (and stored at campaign grain since Phase 3).*

| | |
|---|---|
| Formula | Purchases per lead: `PURCHASES / LEADS`. |
| Basis | Lead cohort. |
| Stored ratio valid at | Campaign, channel (`PURCHASE_RATE`). |
| Recompute from | `MART_MONTHLY_COHORT`, `MART_LEAD_QUALITY`, `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`. **Not** from `MART_MONTHLY_MARKETING` or `FCT_CAMPAIGN_DAILY_ACTIVITY`: they carry `PURCHASES` and `LEADS` too, but purchases there are booked by converted date, so the same field would mix the two time bases. |
| Data Studio | `SUM(PURCHASES) / SUM(LEADS)` |
| Value | 0.063783 (`03 [6]`); by channel 0.063278 (paid_social) to 0.064411 (paid_search) (`06 [7]`); by score segment 0.038035 / 0.067789 / 0.093921 (Low / Medium / High, `05 [6]`). |
| Caveats | Never `PURCHASES / TRIALS`: a purchase is not a converted trial. |

### Purchase share of conversions

*Extra KPI, built in Phase 4 (`04` block 1.1).*

| | |
|---|---|
| Formula | `PURCHASES / CONVERTED_LEADS`: the share of conversions that were purchases rather than trials. |
| Basis | Lead cohort (or full range). |
| Stored ratio valid at | none; computed from the bases. |
| Data Studio | `SUM(PURCHASES) / SUM(CONVERTED_LEADS)` |
| Value | 0.420471 overall; by channel 0.416476 (video) to 0.425712 (display) (`04 [6]`). |
| Caveats | The last funnel step "converted leads -> purchases" is this share of parallel outcomes, not a trial-to-purchase rate. |

### Funnel stages and stage conversion

*Added in Phase 6: the long-format table `MART_CONVERSION_FUNNEL` for the funnel chart of page 2.*

| | |
|---|---|
| Definition | The aggregate campaign funnel Impressions → Clicks → Leads → Converted leads → Purchases, one row per channel × stage. *Stage conversion*: a stage over the stage before it. *Share of top of funnel*: a stage over impressions. |
| Formula | Stage conversion = `STAGE_VALUE / PREV_STAGE_VALUE`; share of top of funnel = `STAGE_VALUE / TOP_OF_FUNNEL_VALUE`. Each stage conversion is a KPI defined above: Clicks = [CTR](#ctr), Leads = [click-to-lead rate](#click-to-lead-rate), Converted leads = [lead conversion rate](#lead-conversion-rate-the-conversion-rate), Purchases = [purchase share of conversions](#purchase-share-of-conversions). |
| Basis / grain | Full range 2023-01-01..2025-12-31 (the bases of `MART_CHANNEL_PERFORMANCE`); channel × stage; no date column. |
| Source | `MART_CONVERSION_FUNNEL`: `CHANNEL`, `STAGE_ORDER`, `STAGE`, `STAGE_VALUE`, `PREV_STAGE_VALUE` (NULL on stage 1), `TOP_OF_FUNNEL_VALUE` ([data_dictionary.md](data_dictionary.md#mart_conversion_funnel)). |
| Data Studio | Dimension `STAGE`, sorted by `STAGE_ORDER` with aggregation *Min*, ascending (text order would be Clicks, Converted leads, Impressions, ...). Bar (or funnel) metric `SUM(STAGE_VALUE)`; stage conversion `SUM(STAGE_VALUE) / SUM(PREV_STAGE_VALUE)`; share of top of funnel `SUM(STAGE_VALUE) / SUM(TOP_OF_FUNNEL_VALUE)`. Channel comparison: `CHANNEL` as a breakdown dimension, or a channel filter control. Both ratios stay correct for any set of channels, because `PREV_STAGE_VALUE` and `TOP_OF_FUNNEL_VALUE` are additive across channels; there is no `ALL` row to exclude. |
| Value | All channels, stages 1-5: values 436,844,819 / 7,102,319 / 261,684 / 39,696 / 16,691; stage conversion (none) / 0.016258 / 0.036845 / 0.151694 / 0.420471; share of top of funnel 1 / 0.01625822 / 0.00059903 / 0.00009087 / 0.00003821 (`06F 7 [9]`). By channel the stage conversions equal the stored ratios of `MART_CHANNEL_PERFORMANCE`, 20 of 20 (`06F 7 [10]`), e.g. Clicks 0.005987 (display) to 0.034920 (paid_search); the 25 values are listed in `06F 7 [8]` and equal `04 [6]`. |
| Caveats | `STAGE` must be in the chart (as the dimension or a filter): `STAGE_VALUE` adds up within a stage only, so a scorecard of `SUM(STAGE_VALUE)` without it would add impressions to purchases. Stage 1 has no previous stage, so its stage conversion is empty (null). Not a person journey: the stages are different units, and Purchases is the subset of converted leads that bought (parallel to trials), not a step after a trial. No date column, so a date-range control cannot filter it; label the chart "2023-2025, full range". The values span 436.8 million to 16,691: show the ratios as labels or table columns, or use a log-scale axis, or the last stages are invisible. Synthetic data, last-touch attribution. |

## Cost and return

### Cost per lead (CPL)

| | |
|---|---|
| Formula | `SPEND / LEADS`. Its inverse, leads per 1,000 of spend = `LEADS x 1000 / SPEND`. |
| Basis | Activity (spend by spend date, leads by created date); over the full range the basis does not matter. |
| Stored ratio valid at | Campaign, channel (`COST_PER_LEAD`). |
| Data Studio | `SUM(SPEND) / SUM(LEADS)` (leads per 1,000 spend: `SUM(LEADS) * 1000 / SUM(SPEND)`) |
| Value | 17.2844; 57.8557 leads per 1,000 of spend (`03 [6]`). By channel 12.6433 (affiliate) to 32.0979 (video) (`04 [13]`). By year 16.6565 / 18.3588 / 16.3799 (`03 [12]`). |
| Caveats | An average over the campaigns that ran, not a marginal cost: in affiliate, paid_search and paid_social the cost per lead on the highest-spend fifth of days is 2.1 to 3.3 times that on the lowest (ratios of the printed costs per lead 22.3294 / 6.7360, 21.8814 / 9.5667 and 24.7676 / 11.9126, `06 [37]`; an association across days that coincides with the 35-lead daily ceiling, most likely a generator rule). 7 spend days have no lead (all CMP0084): their spend stays in `SUM(SPEND)` (`04 [14]`). |

### Cost per conversion

| | |
|---|---|
| Formula | Spend per converted lead: `SPEND / CONVERTED_LEADS`. |
| Basis | Full range (spend and its leads' conversions). Over a short period the spend and the conversions of its leads fall in different months (lag up to 21 days); compute it over campaigns, channels or long ranges. |
| Stored ratio valid at | Campaign, channel (`COST_PER_CONVERSION`). |
| Data Studio | `SUM(SPEND) / SUM(CONVERTED_LEADS)` on `MART_CHANNEL_PERFORMANCE` or `MART_CAMPAIGN_PERFORMANCE` |
| Value | 113.9422; by channel 82.8666 (affiliate) to 210.5504 (video) (`04 [13]`). |
| Caveats | A conversion includes trials (no revenue); for the cost of a paying customer use [cost per purchase](#cost-per-purchase). Divides all spend by last-touch attributed conversions: not a causal acquisition cost. |

### Cost per purchase

*Extra KPI, built in Phase 4 (and stored at campaign grain since Phase 3).*

| | |
|---|---|
| Formula | `SPEND / PURCHASES`: the cost of a paying customer. |
| Basis | Full range, as cost per conversion. |
| Stored ratio valid at | Campaign, channel (`COST_PER_PURCHASE`). |
| Data Studio | `SUM(SPEND) / SUM(PURCHASES)` on `MART_CHANNEL_PERFORMANCE` or `MART_CAMPAIGN_PERFORMANCE` (not on the activity tables, where a month's purchases come partly from earlier months' leads and spend) |
| Value | 270.9874; by channel 198.0229 (affiliate) to 505.5522 (video) (`04 [13]`); by campaign 102.1979 (CMP0040) to 872.1900 (CMP0084) (`06 [19]`). |
| Caveats | Small campaigns are noisy: CMP0084 has 7 purchases, CMP0018 11 (`06 [19]`); show `PURCHASES` next to the cost. Last-touch attribution decides which campaign a purchase is credited to. |

### ROAS

| | |
|---|---|
| Formula | Attributed revenue per unit of spend: `REVENUE / SPEND`. |
| Basis | Full range for channels and campaigns (both bases count the same revenue there). On a time axis it is activity ROAS: revenue booked in the period over spend in the period. |
| Stored ratio valid at | Campaign, channel (`ROAS`). |
| Data Studio | `SUM(REVENUE) / SUM(SPEND)` |
| Value | 4.767102 (`03 [6]`); by channel 2.520913 (video) to 6.540536 (affiliate) (`06 [7]`); by campaign 1.823364 (CMP0084) to 13.013216 (CMP0080) (`06 [15]`). |
| Caveats | Last-touch attributed revenue / spend: not causal, and an average ROAS is not the return of the next unit of spend (`06 [35]`). Monthly activity ROAS is distorted at the data edges (2025-12: 38.517298 on 807.04 of spend by 1 campaign, `06 [31]`); use cumulative or multi-month ranges. |

### Budget utilisation

| | |
|---|---|
| Formula | Share of the planned budget that was spent: `SPEND / BUDGET`. |
| Basis | Whole campaigns, full range only. |
| Stored ratio valid at | Campaign (`MART_CAMPAIGN_PERFORMANCE.BUDGET_UTILIZATION`), channel (`MART_CHANNEL_PERFORMANCE.BUDGET_UTILIZATION`). |
| Data Studio | `SUM(SPEND) / SUM(BUDGET)` on `MART_CAMPAIGN_PERFORMANCE` or `MART_CHANNEL_PERFORMANCE` only, with no date-range filter |
| Value | 0.834720, 895,592.14 unspent; channels 0.831179 to 0.839336; campaigns 0.698798 to 0.986811, none over budget (`06 [25]`). |
| Caveats | Never by month: a budget belongs to a whole campaign window. `SUM(SPEND) / SUM(BUDGET_PRORATED)` of a month is pacing against an assumed even spread, not utilisation. A date-range control bound to `START_DATE` of the campaign table would select campaigns by their start, not their activity, so keep this chart out of the page's date control. Utilisation says how much of a plan was spent, not whether the plan was right; across campaigns it is barely correlated with ROAS (CORR 0.0895, `06 [25]`). |

## Mix, shares and uncertainty

### Shares of spend, leads and revenue

*Extra KPIs, built in Phase 4.*

| | |
|---|---|
| Formula | A channel's part of the five-channel total: `SPEND / total SPEND`, likewise `LEADS`, `REVENUE`. |
| Basis | Full range. |
| Stored ratio valid at | Channel, unfiltered (`SPEND_SHARE`, `LEADS_SHARE`, `REVENUE_SHARE` in `MART_CHANNEL_PERFORMANCE`): each is a share of **all five** channels, even if a chart filters channels out. |
| Data Studio | No calculated field: use the stored columns at channel grain, or the metric `SUM(SPEND)` (`SUM(LEADS)`, `SUM(REVENUE)`) with the comparison calculation *Percent of total*, which shares out whatever the chart shows. |
| Value | Spend share 0.183083 (video) to 0.217714 (paid_social); leads share 0.098588 (video) to 0.259278 (affiliate); revenue share 0.096817 (video) to 0.260214 (affiliate) (`02cT [21]`). Rounded per row, so they sum to 1.000000 / 0.999999 / 0.999999 (`02cT [22]`). |
| Caveats | Never add rounded shares; a cumulative share is computed from the unrounded sums (`03 [8]`). Revenue share is attributed revenue. |

### Lead conversion rate 95% interval (Wilson)

*Extra KPI, built in Phase 4.*

| | |
|---|---|
| Formula | For p = `CONVERTED_LEADS / LEADS`, n = `LEADS`, z = 1.959964 (the two-sided 95% normal quantile, a constant in `sql/02c_analysis_marts.sql`): centre = (p + z²/(2n)) / (1 + z²/n); half-width = z / (1 + z²/n) x √(p(1 − p)/n + z²/(4n²)); interval = centre ± half-width. |
| Basis | Lead cohort. |
| Stored ratio valid at | Channel only (`LCR_CI_LOW`, `LCR_CI_HIGH` in `MART_CHANNEL_PERFORMANCE`). |
| Data Studio | No calculated field (not a thin ratio of sums, decision 9). For another grouping recompute it in SQL, from `SUM(CONVERTED_LEADS)` and `SUM(LEADS)` of that group (monthly cohorts: `04 [16]`; score segments: `05 [6]`; campaigns: `04 [11]`). Never `SUM` or `AVG` the bounds. |
| Value | paid_search [0.150760, 0.156291], affiliate [0.149888, 0.155299], video [0.148113, 0.156886], paid_social [0.147196, 0.153029], display [0.146114, 0.152690]; all contain the pooled 0.151694 (`02cT [21]`); all leads [0.150325, 0.153074] (`04 [8]`). |
| Caveats | Sampling noise only, treating each lead as an independent trial; says nothing about attribution or the generator. Overlapping intervals are not a formal test (the chi-square test is `04 [9]`). |

## Lead quality and time to conversion

### Average lead score

| | |
|---|---|
| Formula | `SUM(LEAD_SCORE) / LEADS`, stored in additive form as `SUM_LEAD_SCORE`. |
| Basis | Lead cohort (a lead attribute). |
| Source | `MART_LEAD_QUALITY` (`SUM_LEAD_SCORE`, `LEADS`). |
| Data Studio | `SUM(SUM_LEAD_SCORE) / SUM(LEADS)` |
| Value | 50.5711; by channel 50.4742 to 50.6614 (`05 [10]`); by segment 20.4796 / 55.5244 / 85.5210 (`02cT [24]`). |
| Caveats | How the score is produced is undocumented, and it is near-uniform on 1-100 (2,508 to 2,728 leads per score, `05 [9]`), a property of the synthetic data. |

### Conversion rate by score segment (and band)

| | |
|---|---|
| Formula | [Lead conversion rate](#lead-conversion-rate-the-conversion-rate) grouped by `LEAD_SCORE_SEGMENT` (Low 1-40, Medium 41-70, High 71-100) or by 10-point `SCORE_BAND`. |
| Basis | Lead cohort. |
| Source | `MART_LEAD_QUALITY` (`LEAD_SCORE_SEGMENT`, `SCORE_BAND`, `CONVERTED_LEADS`, `LEADS`); the bands never straddle a segment cut-off, so `SUM` by segment is exact. |
| Data Studio | Dimension `LEAD_SCORE_SEGMENT` or `SCORE_BAND`, metric `SUM(CONVERTED_LEADS) / SUM(LEADS)`. Sort segments by `SCORE_BAND_MIN` with aggregation *Min*, never *Sum* (text order would be High, Low, Medium). |
| Value | Low 0.091179, Medium 0.161776, High 0.221859 (`05 [6]`); bands 0.062689 (01-10) to 0.240152 (91-100), rising at every step (`05 [8]`). |
| Caveats | Association only: nothing here shows that the score predicts or causes conversion. Most leads of every segment do not convert. |

### Time to conversion

| | |
|---|---|
| Formula | Lag of a converted lead: `DAYS_TO_CONVERT = CONVERTED_DATE − CREATED_DATE` (days). Mean lag = `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)`. Two extra shares: cross-month share = `SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS)`; after-campaign-end share = conversions after the campaign's `END_DATE` / all conversions. |
| Basis | Lead cohort. |
| Source | Mean and cross-month share: `MART_MONTHLY_COHORT` (`SUM_DAYS_TO_CONVERT`, `CONVERTED_LATER_MONTH`, `CONVERTED_LEADS`); mean by score band: `MART_LEAD_QUALITY`. Distribution (median, percentiles, histogram) and after-end share: `FCT_LEAD_CONVERSIONS` (`DAYS_TO_CONVERT`, `CONVERTED_AFTER_CAMPAIGN_END`, `IS_CONVERTED`); after-end conversions also as `FCT_CAMPAIGN_DAILY_ACTIVITY.CONVERSIONS` on `IS_IN_FLIGHT = 0` rows. |
| Data Studio | Mean: `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)`. Cross-month: `SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS)`. After-end: `SUM(CONVERTED_AFTER_CAMPAIGN_END) / SUM(IS_CONVERTED)` on `FCT_LEAD_CONVERSIONS`. Histogram: dimension `DAYS_TO_CONVERT`, metric Record Count, filter `IS_CONVERTED = 1`. Median and percentiles: read from SQL (`04 [18]`). |
| Value | Mean 10.5056 days (`02cT [16]`); median 10, p25 5, p75 16, p90 19, max 21; 0.362228 within 7 days, 0.682814 within 14 (`04 [18]`). Cross-month share 0.344493 (13,675 of 39,696, `02cT [16]`). After campaign end 4,716 conversions, 0.118803 (`05 [15]`). |
| Caveats | The flat 0-21 day distribution with a hard stop is a generator property (`04 [19]`); do not carry it into real attribution windows. The last cohorts are assumed complete (as-of 2025-12-31). A campaign-window filter drops the after-end conversions. |

## Coverage matrix

Phase 4's completion criterion is that every KPI of the four dashboards can be computed in SQL.
Each row names the KPI as the plan lists it, the MART table and columns that carry it, and the
evidence where SQL computes it and checks it against independent expected values (every check row
PASS, 0 FAIL in all five files). In `06` the statement cited is the result; its checks are the
next statement (`06 [8]` for `06 [7]`, and so on). The four tables below list the 23 KPI rows of the
plan's four pages (7 + 5 + 5 + 6), plus one row added in Phase 6 for the Page 2 funnel chart. The
tables are organised by grain, not by page: the plan's page-shaped name `mart_marketing_efficiency`
maps to the tables named here; `mart_conversion_funnel` exists since Phase 6, but only as the
long-format source of the funnel chart, and the Page 2 KPIs still come from the grain tables, as
[dbt.md](dbt.md#plan-names-and-the-models-that-serve-them) explains.

### Page 1: Marketing Overview

| KPI (plan) | Definition used | MART table: columns | Computed and checked in SQL |
|---|---|---|---|
| Total campaigns | [Campaigns](#campaigns) | `MART_CHANNEL_PERFORMANCE`: `CAMPAIGNS`; `FCT_CAMPAIGN_DAILY_ACTIVITY`: `CAMPAIGN_ID`, `IS_IN_FLIGHT`; `MART_MONTHLY_MARKETING`: `ACTIVE_CAMPAIGNS` | `03 [6]` (block 1), `03 [7]` (block 2), `03 [12]` (block 7) |
| Total spend | [Spend](#spend-impressions-clicks) | `MART_MONTHLY_MARKETING`: `SPEND`; `MART_CHANNEL_PERFORMANCE`: `SPEND` | `03 [6]`, `03 [7]`, `03 [10]` (block 5) |
| Impressions | [Impressions](#spend-impressions-clicks) | `MART_MONTHLY_MARKETING`: `IMPRESSIONS` | `03 [6]`, `03 [7]` |
| Clicks | [Clicks](#spend-impressions-clicks) | `MART_MONTHLY_MARKETING`: `CLICKS` | `03 [6]`, `03 [7]` |
| Leads | [Leads](#leads) | `MART_MONTHLY_MARKETING`: `LEADS`; `MART_CHANNEL_PERFORMANCE`: `LEADS` | `03 [6]`, `03 [7]`, `03 [8]` (block 3) |
| Conversions | [Conversions](#conversions-converted-leads-trials-purchases), activity basis on the time axis | `MART_MONTHLY_MARKETING`: `CONVERSIONS`; `MART_CHANNEL_PERFORMANCE`: `CONVERTED_LEADS` | `03 [6]`, `03 [7]` |
| Conversion rate | [Lead conversion rate](#lead-conversion-rate-the-conversion-rate), cohort basis | `MART_MONTHLY_COHORT`: `CONVERTED_LEADS`, `LEADS`; `MART_CHANNEL_PERFORMANCE`: same | `03 [6]`, `04 [16]` (block 4.1), `04 [17]` (block 4.2) |

### Page 2: Conversion Funnel

| KPI (plan) | Definition used | MART table: columns | Computed and checked in SQL |
|---|---|---|---|
| CTR | [CTR](#ctr) | `MART_CHANNEL_PERFORMANCE`: `CLICKS`, `IMPRESSIONS` (and `CTR` at channel grain) | `04 [6]` (block 1.1), `04 [7]` (block 1.2) |
| Click-to-lead | [Click-to-lead rate](#click-to-lead-rate) | `MART_CHANNEL_PERFORMANCE`: `LEADS`, `CLICKS` | `04 [6]`, `04 [7]` |
| Lead conversion rate | [Lead conversion rate](#lead-conversion-rate-the-conversion-rate) | `MART_CHANNEL_PERFORMANCE`: `CONVERTED_LEADS`, `LEADS`, `LCR_CI_LOW`, `LCR_CI_HIGH`; `MART_MONTHLY_COHORT` by month | `04 [8]` (block 2.1), `04 [9]` (block 2.2), `04 [16]`, `04 [17]` |
| Cost per lead | [Cost per lead](#cost-per-lead-cpl) | `MART_CHANNEL_PERFORMANCE`: `SPEND`, `LEADS`; `MART_CAMPAIGN_PERFORMANCE`: same | `04 [13]` (block 3.1), `04 [14]` (block 3.2) |
| Cost per conversion | [Cost per conversion](#cost-per-conversion) | `MART_CHANNEL_PERFORMANCE`: `SPEND`, `CONVERTED_LEADS` | `04 [13]`, `02cT [20]` |
| Funnel chart Impressions → Clicks → Leads → Conversions, by channel (Phase 6) | [Funnel stages and stage conversion](#funnel-stages-and-stage-conversion) | `MART_CONVERSION_FUNNEL`: `STAGE`, `STAGE_ORDER`, `STAGE_VALUE`, `PREV_STAGE_VALUE`, `TOP_OF_FUNNEL_VALUE`, `CHANNEL` | `06F 2` (dbt build: `assert_conversion_funnel_reconciles` against both independent seeds), `06F 7 [9]`, `06F 7 [10]`; the same bases `04 [6]` |

### Page 3: Lead Quality & CRM

| KPI (plan) | Definition used | MART table: columns | Computed and checked in SQL |
|---|---|---|---|
| Total leads | [Leads](#leads) | `MART_LEAD_QUALITY`: `LEADS` | `05 [6]` (block 1a), `05 [10]` (block 3a) |
| Average lead score | [Average lead score](#average-lead-score) | `MART_LEAD_QUALITY`: `SUM_LEAD_SCORE`, `LEADS` | `05 [10]`, `02cT [24]` |
| Lead conversion rate | [Lead conversion rate](#lead-conversion-rate-the-conversion-rate) | `MART_LEAD_QUALITY`: `CONVERTED_LEADS`, `LEADS` | `05 [6]`, `05 [10]`, `05 [11]` (block 3b) |
| Conversion by score segment | [Conversion rate by score segment](#conversion-rate-by-score-segment-and-band) | `MART_LEAD_QUALITY`: `LEAD_SCORE_SEGMENT`, `SCORE_BAND`, `CONVERTED_LEADS`, `LEADS` | `05 [6]`, `05 [7]` (block 1b), `05 [8]` (block 2a) |
| Time to conversion | [Time to conversion](#time-to-conversion) | `MART_MONTHLY_COHORT` / `MART_LEAD_QUALITY`: `SUM_DAYS_TO_CONVERT`, `CONVERTED_LEADS`; `FCT_LEAD_CONVERSIONS`: `DAYS_TO_CONVERT` | `04 [18]` (block 5.1), `04 [19]` (block 5.2), `05 [13]`-`05 [16]` (blocks 4a-4d), `02cT [16]` |

### Page 4: Marketing Efficiency & ROAS

| KPI (plan) | Definition used | MART table: columns | Computed and checked in SQL |
|---|---|---|---|
| Total spend | [Spend](#spend-impressions-clicks) | `MART_CHANNEL_PERFORMANCE`: `SPEND`; `MART_MONTHLY_MARKETING`: `SPEND` | `06 [7]` (block 1), `06 [31]` (block 13) |
| Attributed revenue | [Attributed revenue](#attributed-revenue) | `MART_CHANNEL_PERFORMANCE`: `REVENUE`; `MART_MONTHLY_MARKETING`: `REVENUE` | `06 [7]`, `06 [31]` |
| ROAS | [ROAS](#roas) | `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`: `REVENUE`, `SPEND` (and `ROAS` at their grain) | `06 [7]`, `06 [15]` (block 5), `06 [31]` |
| CPL | [Cost per lead](#cost-per-lead-cpl) | `MART_CHANNEL_PERFORMANCE`: `SPEND`, `LEADS` | `06 [7]`, `04 [13]` |
| Cost per conversion | [Cost per conversion](#cost-per-conversion) | `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`: `SPEND`, `CONVERTED_LEADS` | `04 [13]`, `02cT [20]` |
| Budget utilisation | [Budget utilisation](#budget-utilisation) | `MART_CAMPAIGN_PERFORMANCE`, `MART_CHANNEL_PERFORMANCE`: `SPEND`, `BUDGET` | `06 [25]` (block 10), `06 [27]` (block 11), `06 [29]` (block 12) |

### Extra KPIs built in Phase 4

| KPI | MART table: columns | Computed and checked in SQL |
|---|---|---|
| [Purchase rate](#purchase-rate) | `MART_CHANNEL_PERFORMANCE`, `MART_LEAD_QUALITY`, `MART_MONTHLY_COHORT`: `PURCHASES`, `LEADS` | `03 [6]`, `05 [6]`, `06 [7]` |
| [Purchase share of conversions](#purchase-share-of-conversions) | `MART_CHANNEL_PERFORMANCE`: `PURCHASES`, `CONVERTED_LEADS` | `04 [6]`, `04 [7]` |
| [Cost per purchase](#cost-per-purchase) | `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`: `SPEND`, `PURCHASES` | `04 [13]`, `04 [15]` (block 3.3), `06 [19]` (block 7) |
| [CPC](#cpc-cost-per-click), [CPM](#cpm-cost-per-1000-impressions) | `MART_CHANNEL_PERFORMANCE`: `SPEND`, `CLICKS`, `IMPRESSIONS`, `CPC`, `CPM` | `04 [13]`, `02cT [20]` |
| [Shares](#shares-of-spend-leads-and-revenue) | `MART_CHANNEL_PERFORMANCE`: `SPEND_SHARE`, `LEADS_SHARE`, `REVENUE_SHARE` | `03 [8]`, `06 [33]` (block 14), `02cT [21]` |
| [Wilson interval](#lead-conversion-rate-95-interval-wilson) | `MART_CHANNEL_PERFORMANCE`: `LCR_CI_LOW`, `LCR_CI_HIGH` | `02cT [21]`, `04 [8]`, `05 [6]` (segments) |

Result: every KPI of the four pages, and every extra KPI, is computed by checked SQL over the
MART tables. The criterion is met.

## Notes for Phase 6

- **Lag distribution and after-end share (decided in Phase 6).** The report does not read
  `FCT_LEAD_CONVERSIONS` (261,684 rows), so it has no lag histogram and nothing extra is exported
  for the Google Sheets snapshot ([dashboard_spec.md](dashboard_spec.md#decisions-this-spec-makes),
  D1). Time to conversion comes from the small marts: the mean lag (P2-10, P3-05, P3-09), the
  cross-month share (P2-11) and the conversions after campaign end (P2-12: `CONVERSIONS` on the
  `IS_IN_FLIGHT = 0` rows of `FCT_CAMPAIGN_DAILY_ACTIVITY`, 4,716, `02cT [9]`). The median (10)
  and the flat 0-21 day distribution are quoted in the captions of P2-10..P2-12 and P3-09 from
  `04 [18]` and `04 [19]` ([business_insights.md](business_insights.md), Q5).
- **Zero denominators.** Over the full range no denominator is 0. A filtered view can have one:
  21 of the 180 channel-months of `MART_MONTHLY_MARKETING` have no spend (159 have,
  `02cT [15]`). Check how each chart shows an empty ratio when it is built.
- **Date ranges on month columns.** `MONTH_START` and `COHORT_MONTH` hold the first day of the
  month, so a date-range control includes a month only if its first day is in the range; use
  whole-month ranges (the dashboards use the fixed range 2023-01-01..2025-12-31, decision 9).
- **Funnel chart.** Since Phase 6 the funnel reads `MART_CONVERSION_FUNNEL` (25 rows), not a
  calculated pivot of `MART_CHANNEL_PERFORMANCE`: see
  [Funnel stages and stage conversion](#funnel-stages-and-stage-conversion). It is exported for
  the Sheets snapshot with the other report tables ([exports/](../exports/README.md), decision 8).
- **One basis per chart.** A page that shows both activity and cohort figures uses two data
  sources (`MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT`) with clearly labelled date dimensions,
  never one blended axis (decision 7).
