# Dashboard build spec (Phase 6)

The build instructions for the four-page Google Data Studio (formerly Looker Studio) report. Each
page and chart is specified here: data source, fields, settings, the filters that apply, a caption,
and the values the chart must show.

**Who does what.** Claude cannot sign in to Google, authorise the connector or click in Data
Studio, so you build the report by hand from this spec. Everything was written to be followed step
by step: exact menu paths, exact field names, and an **Expect** line for every component. A
component is done when it shows its Expect values. The dashboard is done when every Expect value
matches and the sign-off in [docs/dashboard_validation.md](dashboard_validation.md) passes
(section 6).

**The rule this spec enforces** ([architecture.md](architecture.md#design-decisions), decisions 7-9):

- Every business metric is computed in Snowflake SQL / dbt. Data Studio only visualises.
- The only calculated fields are the thin `SUM(x) / SUM(y)` ratios listed in
  [kpi_definitions.md](kpi_definitions.md#quick-reference-the-data-studio-fields). Section 0.5
  lists the subset this report uses, per data source.
- Activity-basis and lead-cohort series never share a date axis.
- Budget utilisation is shown only over whole campaigns.
- Revenue and ROAS are last-touch attributed, not causal.
- The data is synthetic.

**Time.** Plan about 3 sessions:

| Session | Work | Time |
|---|---|---|
| 1 | Data sources (section 0), report setup (section 1), page 1 | about 1 h for sections 0-1, then 30-45 min for page 1 |
| 2 | Pages 2-4 | 30-40 min each |
| 3 | Validation, publishing, screenshots | about 1 h |

**Snowflake cost.** While you edit, Data Studio keeps querying Snowflake and keeps `MARKETING_WH`
running: an X-Small Gen1 warehouse costs 1 credit per running hour. The account monitor allows
4 credits per day (UTC) for the whole account. So keep each editing session under about 2.5
hours, and spread the three sessions over different days. If charts start failing with a
Snowflake error, check whether a resource monitor suspended the warehouse (Snowsight » Admin »
Cost management, or `SHOW RESOURCE MONITORS;` as admin). If one did, **stop** and wait for the
00:00 UTC reset. Never raise the quota just to finish faster.

**Deadline.** The Snowflake trial ends about **2026-11-12**. The report must be built and checked
on the live connector, and moved to the frozen Google Sheets snapshot, by about **2026-11-07**
(section 9).

## Contents

- [Decisions this spec makes](#decisions-this-spec-makes)
- [0. Prerequisites and data sources](#0-prerequisites-and-data-sources)
- [1. Report-wide setup](#1-report-wide-setup)
- [2. Page 1: Marketing Overview](#2-page-1-marketing-overview)
- [3. Page 2: Conversion Funnel](#3-page-2-conversion-funnel)
- [4. Page 3: Lead Quality & CRM](#4-page-3-lead-quality--crm)
- [5. Page 4: Marketing Efficiency & ROAS](#5-page-4-marketing-efficiency--roas)
- [6. Validation](#6-validation)
- [7. Publishing](#7-publishing)
- [8. Screenshots for the repository](#8-screenshots-for-the-repository)
- [9. Later: the Snowflake → Google Sheets swap](#9-later-the-snowflake--google-sheets-swap)

How to read the component specs:

- **Labels.** Menu items and buttons are in **bold**. Field names are in `CODE`, exactly as
  Snowflake returns them. Calculated fields have Title-case names, e.g. *Lead conversion rate*.
- **Filters** says which report controls change the component:
  - *date*: the date range control.
  - *channel*: the channel drop-down.
  - *campaign*: the campaign drop-down of that page.

  Everything else is fixed. "Full range" means 2023-01-01 to 2025-12-31.
- **Expect** gives the value in Data Studio's display format: rates in percent with 2 decimals,
  money and ratios with 2 decimals.
  - **Default view:** full range, all channels, no campaign selected.
  - **Spot checks:** "2024" means the date range 2024-01-01 to 2024-12-31. "video" means channel =
    video. Set the filter, check, then reset it.
  - **Sources:** every value is copied from the evidence files and cited by tag and statement, as
    in [kpi_definitions.md](kpi_definitions.md) (`03 [7]` = `docs/evidence/03_overview.txt`,
    statement 7; `06F 7 [9]` = `06_funnel_mart.txt`, step 7, statement 9; `07 [26]` =
    `07_dashboard_validation.txt`, statement 26). Values marked *(sum)* are sums of printed rows
    of the cited statement, not new queries.
- **Columns checked.** Every field named below exists in its source, with the type used here.
  `make export-check` read all seven tables as `SVC_CRM_BI` / `CRM_REPORTER`, the connector's
  identity, and found their live columns, types and row counts equal to
  [exports/manifest.json](../exports/manifest.json), which lists them
  ([evidence](evidence/06_export_check.txt), 2026-10-14). `07 [6]` checks the row counts and the
  date columns of each source.

## Decisions this spec makes

| # | Decision | Why |
|---:|---|---|
| D1 | **Seven reusable data sources**, one per MART table used: `MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT`, `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`, `MART_LEAD_QUALITY`, `MART_CONVERSION_FUNNEL`, `FCT_CAMPAIGN_DAILY_ACTIVITY`. Each one is `SELECT * FROM MARKETING_CRM.MART.<TABLE>`. | The connector takes one SQL statement per source. All seven are among the eight tables in [exports/](../exports/README.md) (`EXPORT_TABLES` in `scripts/export_marts.py`), so every chart survives the Sheets swap. `FCT_LEAD_CONVERSIONS` (261,684 rows) is not used, so there is no lag histogram. Time to conversion is shown as the mean lag, the cross-month share and the after-campaign-end count, all read from the small marts. `DIM_CAMPAIGN` is exported but not needed: the campaign filter reads `CAMPAIGN_NAME` from `MART_CAMPAIGN_PERFORMANCE`. |
| D2 | **Month columns stay full dates** (`Date (YYYYMMDD)`) in the data sources. Charts show them as *Year Month* by changing the granularity inside each chart. | Google: "The date range dimension must contain a complete date with year, month, and day." A `MONTH_START` typed *Year Month* in the data source could stop being a date range dimension, and the date control would then silently stop filtering it. |
| D3 | **The campaign table's dates become Text** (`START_DATE`, `END_DATE`, `START_MONTH`, `START_YEAR`), as does `ACTIVITY_MONTH` in the daily table. | Without a date field, a data source cannot be filtered by the date control. Campaign-grain charts therefore always show whole campaigns, never "campaigns that started in the range". This is the condition for budget utilisation. The daily table keeps exactly one date, `ACTIVITY_DATE`. |
| D4 | **One report-level date range control**, fixed default **2023-01-01 to 2025-12-31**, never relative. | It filters each chart on that chart's own date field: activity charts by activity month, cohort charts by lead cohort month. Full-range sources have no date field, so they ignore it. This needs no grouping. Relative ranges such as "last 28 days" are empty for this data. |
| D5 | **One report-level channel drop-down**, only if gate test G2 (section 1.4) shows that it filters every data source. Otherwise: one channel drop-down per page with a stated scope. | Data Studio matches filters across data sources by field ID, not by name. The docs do not say which IDs the Snowflake connector assigns. *Manage field names and IDs* can unify them, but that is a new feature (January 2026). |
| D6 | **The campaign drop-down is page-level**, on pages 1, 2 and 4 only, on `CAMPAIGN_NAME`. | Only `MART_CAMPAIGN_PERFORMANCE` has `CAMPAIGN_NAME`, so the control can only filter the campaign-grain charts. |
| D7 | **The KPI comparison is a fixed strip, "2025 vs 2024", on page 1.** The main KPI cards show no "vs previous period" arrow. | Section 1.7: with the default full range, Data Studio's previous-year comparison would compare two overlapping three-year windows. |
| D8 | **Money is shown as Number with 2 decimals, not Currency USD.** | The publisher's data dictionary gives no currency ("Media cost", "Attributed revenue"), so a $ sign would invent one. If you want a symbol anyway, use Currency (USD) everywhere and add "currency not stated by the publisher" to the header. |
| D9 | **Ratios on aggregated charts always come from the calculated fields** (ratio of sums), never from the stored ratio columns. Summary rows are on. | A calculated ratio is re-computed for any filter and for the summary row. A stored ratio would be summed or averaged. Stored columns are used only at their own grain, with no summary row: the Wilson interval bounds `LCR_CI_LOW` / `LCR_CI_HIGH` and the shares `SPEND_SHARE` / `REVENUE_SHARE` in channel charts. |
| D10 | **Cross-filtering is on for category charts** (channels, segments, campaign tables). It is off for time axes and the funnel. | Clicking a channel bar should filter the page. Brushing a time axis would change the date range without changing the visible control. |

## 0. Prerequisites and data sources

### 0.1 Before you start

- [ ] Use the **personal Gmail account** that ran the Phase 1 test. Never use LionMail or another
  Workspace account, and never transfer ownership of anything later: a Workspace admin can block
  sharing outside the organisation or community connectors, and a university account is
  deprovisioned after graduation.
- [ ] The MART tables are the deployed dbt build: the Phase 5 full build plus the Phase 6 funnel
  mart, exactly as exported to [exports/](../exports/README.md) and checked by
  [dashboard_validation.md](dashboard_validation.md). Do **not** rebuild them while you build the
  report. If you must, use `make dbt-build-select DBT_SELECT=...`, never a full `make dbt-build`.
  The data sources keep working after a rebuild: the table names are unchanged and the future
  grant re-applies `SELECT`.
- [ ] You have the key file for `SVC_CRM_BI`: the path in `SNOWFLAKE_BI_PRIVATE_KEY_PATH` of `.env`,
  by default `~/.snowflake/keys/svc_crm_bi.p8`. Do not open `.env` in a screen share or a
  screenshot.
- [ ] Open https://datastudio.google.com (old `lookerstudio.google.com` links redirect there).

### 0.2 The connector sign-in that worked (Phase 1, 2026-10-13)

The Snowflake partner connector asks for its credentials once per Google account. Every later data
source reuses them, so you may not see the sign-in step again. If it asks, use exactly this:

| Field | Value |
|---|---|
| Connector | Under **Partner Connectors**, the **Snowflake** card **with the Snowflake logo**, published by Snowflake. Not "Snowflake by Supermetrics" or "by Windsor.ai" (paid third parties). |
| Username | `SVC_CRM_BI` |
| Password or private key | The **base64 body only** of the key: no BEGIN/END lines, no newlines. Copy it with `grep -v -- '-----' "$HOME/.snowflake/keys/svc_crm_bi.p8" \| tr -d '\n' \| pbcopy`, paste, then clear the clipboard with `pbcopy < /dev/null`. The full PEM was rejected ("Incorrect username or password"). |
| Account URL | `<org>-<account>.snowflakecomputing.com`, **without** `https://` (with it the connector refuses: "Account URL should not start with 'https://'"). Take it from Snowsight » account menu » View account details. Never write the real value into the repository or a screenshot. |
| Role | `CRM_REPORTER` |
| Warehouse | `MARKETING_WH` |
| Database | `MARKETING_CRM` |
| Schema | `MART` |
| SQL query | Per data source, from the table in 0.3. **One `SELECT`, no trailing semicolon.** |

### 0.3 Create the seven reusable data sources

Create **every** data source from the Data Studio home page. Never use **Add data** with the
connector from inside a report: that creates an *embedded* source, and Google states that embedded
sources are accessible to anyone with the report link.

For each row of the table below:

1. Home page » **+ Create** (top left) » **Data source**.
2. Search `Snowflake`, pick the Snowflake card (0.2) and authorise it if asked.
3. Fill in the connection fields from 0.2. In **SQL query**, paste the row's SQL exactly.
4. Click **CONNECT** (top right). The field list opens.
5. Rename the source at the top left ("Untitled data source" or similar) to the row's **Name**.
6. In the top bar:
   - **Data credentials** → **Owner's credentials**.
   - **Data freshness** → the **longest** interval offered (probably 12 hours).
7. Make sure **Field editing in reports** is **on**. Charts need it to show a date as *Year Month*
   (verify in the UI: Google's docs do not say this setting is required for that).
8. Apply the field fixes and add the calculated fields of 0.4 and 0.5.
9. Go back to the home page. Do not click **CREATE REPORT** yet (section 1.1 does that).

| Code | Name (in Data Studio) | SQL query (copy exactly) | Rows | Basis | Date field |
|---|---|---|---:|---|---|
| `MM` | `MCRM MM - MART_MONTHLY_MARKETING` | `SELECT * FROM MARKETING_CRM.MART.MART_MONTHLY_MARKETING` | 180 | activity (spend by spend date, leads by created date, conversions and revenue by conversion date) | `MONTH_START` |
| `COH` | `MCRM COH - MART_MONTHLY_COHORT` | `SELECT * FROM MARKETING_CRM.MART.MART_MONTHLY_COHORT` | 180 | lead cohort (what the leads created in a month later did) | `COHORT_MONTH` |
| `CH` | `MCRM CH - MART_CHANNEL_PERFORMANCE` | `SELECT * FROM MARKETING_CRM.MART.MART_CHANNEL_PERFORMANCE` | 5 | full range, one row per channel | none |
| `CAMP` | `MCRM CAMP - MART_CAMPAIGN_PERFORMANCE` | `SELECT * FROM MARKETING_CRM.MART.MART_CAMPAIGN_PERFORMANCE` | 120 | full range, one row per campaign | none (after D3) |
| `LQ` | `MCRM LQ - MART_LEAD_QUALITY` | `SELECT * FROM MARKETING_CRM.MART.MART_LEAD_QUALITY` | 50 | lead cohort, full range, channel × 10-point score band | none |
| `FUN` | `MCRM FUN - MART_CONVERSION_FUNNEL` | `SELECT * FROM MARKETING_CRM.MART.MART_CONVERSION_FUNNEL` | 25 | full range, channel × funnel stage | none |
| `DAILY` | `MCRM DAILY - FCT_CAMPAIGN_DAILY_ACTIVITY` | `SELECT * FROM MARKETING_CRM.MART.FCT_CAMPAIGN_DAILY_ACTIVITY` | 13,760 | activity, campaign × day (flight + 21 days) | `ACTIVITY_DATE` |

The throwaway data source and report of the Phase 1 connection test are not part of this
dashboard. Leave them private.

### 0.4 Field types per data source

Open each source (home page » **Data sources** tab » the name) and set the **Type** and **Default
aggregation** columns of the field list as below. The connector maps `DATE` to *Date*, `NUMBER` to
*Number* and `TEXT` to *Text*.

**Observed on the first real source (MM, 2026-10-14): the Snowflake connector imports every field as
a dimension (green) with Default Aggregation *None*, numbers included** ("Dimensions (12)", no
metrics). A field with aggregation *None* is a dimension and cannot be a chart metric. So, on every
source, first set **Default Aggregation = Sum** on every Number field (they turn blue and move to
*Metrics*), **except** the fields the table below sets to *None* or *Min*, and the fields it turns
into *Text*. Dates and texts keep *None*. The calculated fields of 0.5 use `SUM(...)` explicitly, so
they work either way. The same source also showed the defaults *Data freshness: 12 hours*,
*Field editing in reports: On* and *Community visualizations access: On*.

| Source | Field | Set Type to | Default aggregation | Why |
|---|---|---|---|---|
| `MM` | `MONTH_START` | keep **Date (YYYYMMDD)** | | The date range dimension (D2). Do not change it to *Year Month*. |
| `MM` | `ACTIVE_CAMPAIGNS` | Number | Sum | Additive across channels within a month only. Use it only in charts with the month as dimension, never in a scorecard (it would add 490 campaign-months, [`02cT [18]`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/evidence/02c_analysis_marts_tests.txt)). |
| `COH` | `COHORT_MONTH` | keep **Date (YYYYMMDD)** | | The date range dimension (D2). |
| `CH` | `CTR`, `CLICK_TO_LEAD_RATE`, `LEAD_CONVERSION_RATE`, `PURCHASE_RATE`, `BUDGET_UTILIZATION`, `SPEND_SHARE`, `LEADS_SHARE`, `REVENUE_SHARE`, `LCR_CI_LOW`, `LCR_CI_HIGH` | **Percent** | Sum | Stored ratios at channel grain. Only the last four are used in charts, each with one row per channel (D9). |
| `CAMP` | `START_DATE`, `END_DATE`, `START_MONTH` | **Text** | | Removes the date dimension (D3). They may then display as `20240517`; no chart uses them. |
| `CAMP` | `START_YEAR` | **Text** | | A campaign attribute, not an activity year, and never a metric. |
| `CAMP` | `CTR`, `CLICK_TO_LEAD_RATE`, `LEAD_CONVERSION_RATE`, `PURCHASE_RATE`, `BUDGET_UTILIZATION` | **Percent** | Sum | Stored ratios at campaign grain. Not used in charts (D9); typed only so they read correctly in the field list. |
| `LQ` | `SCORE_BAND_MIN`, `SCORE_BAND_MAX` | Number | **Min** | Sort keys, never summed. |
| `LQ` | `SCORE_BAND` | Text | | `01-10` ... `91-100`, zero-padded, so it sorts correctly as text. |
| `FUN` | `STAGE_ORDER` | Number | **Min** | The sort key of the funnel. Text order would be Clicks, Converted leads, Impressions, ... |
| `DAILY` | `ACTIVITY_DATE` | keep **Date (YYYYMMDD)** | | The only date field, so the date range dimension. |
| `DAILY` | `ACTIVITY_MONTH` | **Text** | | Leaves one date field (D3). Not used. |
| `DAILY` | `CAMPAIGN_ID` | Text | (*Count Distinct* when used as a metric) | For the *Total campaigns* card. |
| `DAILY` | `IS_IN_FLIGHT` | Number | **None** | Makes the 0/1 flag a **dimension**. The card filters `In flight only` and `After flight` (P1-01, P1-K1, P2-12) must test it on each daily row. As a *Sum* metric, the condition would be tested on the card's aggregated total (11,240 flight days over the full range), so `= 1` and `= 0` would both be false and the cards would show no data. |

Every `CHANNEL` field stays **Text**, in all seven sources. The channel filter needs the same type
everywhere (section 1.4).

Set `IS_IN_FLIGHT` to **None** before you create the two card filters: switching a field between
metric and dimension later disables the filters that use it. In the field list, a dimension is
green and a metric blue; `IS_IN_FLIGHT` must be green. If your version offers no **None** for a
Number field, set its **Type** to **Text** instead; the filters then compare with the text `1`
and `0`.

### 0.5 Calculated fields per data source

These are the only calculated fields in the report. Each formula is copied from the
[quick reference in kpi_definitions.md](kpi_definitions.md#quick-reference-the-data-studio-fields)
and is valid on the source it is added to, per that table's "Valid data sources" column. To add
one: open the source » **ADD A FIELD** (top right). If a menu appears, choose **Add calculated
field**. Then enter the **Field name** and **Formula** exactly, set the **Type**, and click
**Save** » **Done**.

Do **not** add any other calculated field: no `CASE`, no date functions, no ratio on `MM` or
`DAILY`. On `MM`, for example, `SUM(CONVERSIONS) / SUM(LEADS)` would compute without an error, but
it is the naive cross-basis ratio that swings from 8.30% to 93.85% by month (`04 [17]`).

| Source | Field name | Formula | Type | Full-range value (source) |
|---|---|---|---|---|
| `COH` | Lead conversion rate | `SUM(CONVERTED_LEADS) / SUM(LEADS)` | Percent | 15.17% (`03 [6]`) |
| `COH` | Mean days to convert | `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)` | Number | 10.51 (`04 [18]`) |
| `COH` | Cross-month share | `SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS)` | Percent | 34.45% (`04 [17]`) |
| `CH` | Click-through rate | `SUM(CLICKS) / SUM(IMPRESSIONS)` | Percent | 1.63% (`03 [6]`) |
| `CH` | Click-to-lead rate | `SUM(LEADS) / SUM(CLICKS)` | Percent | 3.68% (`03 [6]`) |
| `CH` | Lead conversion rate | `SUM(CONVERTED_LEADS) / SUM(LEADS)` | Percent | 15.17% (`03 [6]`) |
| `CH` | Cost per lead | `SUM(SPEND) / SUM(LEADS)` | Number | 17.28 (`03 [6]`) |
| `CH` | Cost per conversion | `SUM(SPEND) / SUM(CONVERTED_LEADS)` | Number | 113.94 (`04 [13]`) |
| `CH` | Cost per purchase | `SUM(SPEND) / SUM(PURCHASES)` | Number | 270.99 (`04 [13]`) |
| `CH` | ROAS (attributed) | `SUM(REVENUE) / SUM(SPEND)` | Number | 4.77 (`03 [6]`) |
| `CH` | Budget utilisation | `SUM(SPEND) / SUM(BUDGET)` | Percent | 83.47% (`03 [6]`) |
| `CAMP` | Lead conversion rate | `SUM(CONVERTED_LEADS) / SUM(LEADS)` | Percent | 15.17% |
| `CAMP` | Cost per lead | `SUM(SPEND) / SUM(LEADS)` | Number | 17.28 |
| `CAMP` | Cost per purchase | `SUM(SPEND) / SUM(PURCHASES)` | Number | 270.99 |
| `CAMP` | ROAS (attributed) | `SUM(REVENUE) / SUM(SPEND)` | Number | 4.77 |
| `CAMP` | Budget utilisation | `SUM(SPEND) / SUM(BUDGET)` | Percent | 83.47% |
| `LQ` | Lead conversion rate | `SUM(CONVERTED_LEADS) / SUM(LEADS)` | Percent | 15.17% (`05 [10]`) |
| `LQ` | Purchase rate | `SUM(PURCHASES) / SUM(LEADS)` | Percent | 6.38% (`05 [6]`) |
| `LQ` | Average lead score | `SUM(SUM_LEAD_SCORE) / SUM(LEADS)` | Number | 50.57 (`05 [10]`) |
| `LQ` | Mean days to convert | `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)` | Number | 10.51 (`05 [13]`) |
| `FUN` | Stage conversion | `SUM(STAGE_VALUE) / SUM(PREV_STAGE_VALUE)` | Percent | per stage (`06F 7 [9]`) |
| `FUN` | Share of top of funnel | `SUM(STAGE_VALUE) / SUM(TOP_OF_FUNNEL_VALUE)` | Percent | per stage (`06F 7 [9]`) |

The calculated-field names differ from the stored UPPERCASE columns on purpose. For example,
*Lead conversion rate* (calculated) and `LEAD_CONVERSION_RATE` (stored) are both in `CH` and `CAMP`.
When you pick a ratio for a chart, always pick the Title-case one.

`MM` and `DAILY` get no calculated field. The *Total campaigns* card uses the aggregation *Count
Distinct* on `CAMPAIGN_ID` plus a filter, not a formula (section 2).

### 0.6 Check before moving on

- [ ] Home page » **Data sources** lists the seven `MCRM ...` sources. Each shows **Owner's
  credentials** and the longest freshness.
- [ ] `CAMP` and `CH` show no field with a calendar icon. `MM`, `COH` and `DAILY` show exactly one
  each: `MONTH_START`, `COHORT_MONTH`, `ACTIVITY_DATE`.
- [ ] In `DAILY`, `IS_IN_FLIGHT` is a dimension (green, aggregation **None**), not a metric.
- [ ] The 22 calculated fields of 0.5 exist, with the types shown.

## 1. Report-wide setup

### 1.1 Create the report and attach the sources

1. Home page » **+ Create** » **Report**. In **Add data to report**, open the **My data sources**
   tab, pick `MCRM MM - MART_MONTHLY_MARKETING`, click **Add**, then **Add to report**.
2. Delete the table Data Studio places automatically.
3. **Resource** » **Manage added data sources** » **ADD A DATA SOURCE** » **My data sources**. Add
   the other six, one at a time. Never pick the Snowflake connector here (0.3).
4. Rename the report (top left) to `Marketing CRM & Conversion Funnel Analytics Report`. The
   page header text box keeps the title `Marketing CRM & Conversion Funnel Analytics`.
5. **File** » **Report settings**: leave **Viewer data refresh** off and any auto-refresh off.

### 1.2 Theme, canvas, pages

1. Toolbar **Theme and layout** » **THEME**: pick **Simple** (light).
2. **Theme and layout** » **LAYOUT**:
   - **Navigation type: Tab** (Google lists the options **Left**, **Tab**, **Top Left** and
     **Hidden**).
   - **Canvas size: Custom**, width **1200**, height **1900**. This applies to every page; blank
     space at the bottom of the shorter pages is fine.
   - **Display mode: Fit to width**.
   - **Report-level component position: Top**.
3. **Page** » **Manage pages**: rename the first page and add three more, in this order:
   1. `Marketing Overview`
   2. `Conversion Funnel`
   3. `Lead Quality & CRM`
   4. `Marketing Efficiency & ROAS`
4. Add a fifth page, `TEST`, for gate test G2. Delete it after section 1.5.

### 1.3 Report-level header

On page 1, add these text boxes (**Insert** » **Text**). Select them all and **Arrange** » **Make
report-level**, or right-click » **Make report-level**, so they appear on every page.

```
x=24..1176, y=0..120   (approximate; snap to the grid)
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Marketing CRM & Conversion Funnel Analytics                [ Date range ▾ ] [ Channel ▾ ]│ y 16
│ KPIs computed in Snowflake SQL / dbt (MARKETING_CRM.MART); data synthetic;   whole months│ y 52
│ revenue last-touch attributed                                                            │
│ Data: Analytics Engineering, "Marketing Campaigns & Conversions Dataset v1.0.0" (...)    │ y 76
└──────────────────────────────────────────────────────────────────────────────────────────┘ y 120
```

| Box | Text (exact) | Position / style |
|---|---|---|
| Title | `Marketing CRM & Conversion Funnel Analytics` | x 24, y 12, w 720, h 34; 22 px, bold, dark grey `#202124` |
| Provenance | `KPIs computed in Snowflake SQL / dbt (MARKETING_CRM.MART); data synthetic; revenue last-touch attributed` | x 24, y 50, w 740, h 22; 12 px, `#3C4043` |
| Attribution (CC BY 4.0) | `Data: Analytics Engineering, "Marketing Campaigns & Conversions Dataset v1.0.0" (https://www.analyticsengineering.com/datasets/marketing-campaigns), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Typed, cleaned and aggregated by Hoedong Kim; not endorsed by the publisher.` | x 24, y 74, w 760, h 40; 10 px, `#5F6368`, wraps to 2 lines |
| Control hint | `Date range: whole months (monthly data is keyed on the 1st)` | x 800, y 60, w 376, h 18; 10 px, `#5F6368` |

The attribution text is the one in [architecture.md](architecture.md#design-decisions), decision
8, which asks for a header or footer text box on every page. It sits in the header rather than a
footer so that it is on every page without depending on page height. The public Sheets version
adds one more header box under the controls (section 9).

Below the header, every page gets its own page-level subtitle at y 128 (section 2-5, "Page
subtitle").

### 1.4 Gate test G2: does one channel control filter every data source?

Run this **before** you build any page. If field IDs have to be overridden, the override breaks
every chart that already uses the field ("Changing a field ID that is already in use in the
report breaks any charts that use that field"), so it must happen first.

1. On page `TEST`, add **Add a control** » **Drop-down list**:
   - **Data source** `CH`, **Control field** `CHANNEL`.
   - In **STYLE**, untick **Show values** if a metric appears.
2. Add one small check per data source, each a scorecard unless stated:

   | Check | Source | Metric | All channels | video |
   |---|---|---|---:|---:|
   | a | `MM` | `LEADS` (Sum) | 261,684 | 25,799 |
   | b | `COH` | `LEADS` (Sum) | 261,684 | 25,799 |
   | c | `CAMP` | `LEADS` (Sum) | 261,684 | 25,799 |
   | d | `LQ` | `LEADS` (Sum) | 261,684 | 25,799 |
   | e | `DAILY` | `LEADS` (Sum) | 261,684 | 25,799 |
   | f | `FUN` (a **table**: dimension `STAGE`, metric `STAGE_VALUE`) | row `Leads` | 261,684 | 25,799 |
   | g | `CH` (scorecard, same source as the control) | `LEADS` (Sum) | 261,684 | 25,799 |

   Values from `03 [6]` and `03 [8]`. If `MM`, `COH` or `DAILY` show "No data", set the scorecard's
   **Default date range** to **Custom** 2023-01-01..2025-12-31 for this test.
3. In view mode (**View**, top right), select **video** in the drop-down.
   - **All seven show the video value** → cross-source filtering works as is. Write "G2: works
     without overrides" in the validation record and go to 1.5.
   - **Only g changes** → unify the IDs. **Resource** » **Manage field names and IDs** » **Add
     field override**. Pick `CHANNEL` of one data source, leave **New display name** empty, and set
     **New ID** to `channel`. Repeat for `CHANNEL` of all seven sources: same ID, and all are Text.
     Back on `TEST`, re-select the control field (the override breaks it), then repeat step 3.
   - **Still only g changes, or only some** → use the **fallback** (1.5, "Channel control:
     fallback") and write which checks failed in the validation record.
4. Delete page `TEST` when the result is recorded. **Page** » **Manage pages** » the page's menu »
   **Delete**.

### 1.5 Report-level controls

Place both controls on page 1, in the header area. Select both and **Make report-level**.

**Date range control** (D4):

1. **Add a control** » **Date range control**. Place it at x 800, y 16, w 180, h 40.
2. **SETUP** » **Default date range**: **Custom**. In the calendar choose **Fixed**, then start
   **Jan 1, 2023** and end **Dec 31, 2025**. Never a preset such as "Last 28 days": the data ends
   in December 2025, so relative ranges are empty.
3. What it does: each chart is filtered on its own date range dimension.
   - `MM` charts by `MONTH_START`.
   - `COH` charts by `COHORT_MONTH`: by **when the leads were created**.
   - `DAILY` charts by `ACTIVITY_DATE`.
   - `CH`, `CAMP`, `LQ` and `FUN` have no date field, so the control cannot change them.
4. Gate test **G1**, after page 2 exists: on page 1 set the control to 2025-01-01..2025-12-31,
   open page 2 and check that the "by lead cohort month" chart shows only 2025 months. Google's
   [controls page](https://docs.cloud.google.com/data-studio/add-edit-controls) states both parts:
   a report-level control appears in the same place on every page, and filters set on one page
   carry over to all pages of the report. So G1 only confirms the documented behaviour. If it
   fails anyway, use the fallback: **Make page-level**, then copy the control (Ctrl/Cmd+C,
   Ctrl/Cmd+V) onto pages 2 and 4 at the same position with the same fixed default. Page 3 needs
   none.

**Channel control**, when G2 passed (D5):

1. **Add a control** » **Drop-down list**. Place it at x 996, y 16, w 180, h 40.
   - **Data source** `CH`, **Control field** `CHANNEL`.
   - **Order**: `CHANNEL` ascending.
   - **Default selection**: empty, which means all channels.
2. **STYLE**:
   - **Single select** off, so viewers can pick several channels.
   - **Enable search box** off (only 5 values).
   - Untick **Show values** if a metric appears.
3. What it does: it filters every chart of all seven sources, on every page, including the
   comparison strip and the funnel. The funnel's ratios stay correct for any set of channels,
   because `PREV_STAGE_VALUE` and `TOP_OF_FUNNEL_VALUE` add up across channels (`06F 7 [10]`).

**Channel control: fallback**, when G2 failed:

- Do not make a channel control report-level.
- Put **one page-level drop-down per page** at x 996, y 128 (h 36), bound to the page's main source:

  | Page | Main source | Charts it filters |
  |---|---|---|
  | 1 | `MM` | P1-02..P1-06, P1-K2..P1-K4, P1-08..P1-10 |
  | 2 | `CH` | P2-01..P2-05, P2-08 |
  | 3 | `LQ` | all of page 3 |
  | 4 | `CH` | P4-01..P4-06, P4-08, P4-09 |

- Every other chart then shows all channels. Add ` · all channels` to its caption.
- **Page 1 has shared captions**, so mark the cards themselves there:
  - Rename the card labels of P1-01, P1-07, P1-K1 and P1-K5 with the suffix ` (all channels)`,
    e.g. `Total campaigns (all channels)`. They read `DAILY` and `COH`, which the `MM` drop-down
    does not reach.
  - KPI-row caption: replace the ending `· Filters: date, channel` with `· Filters: date; channel
    for spend, impressions, clicks, leads and conversions only`.
  - Strip caption: replace the ending `· Filters: channel` with `· Filters: channel for spend,
    leads and conversions only`.
- Charts that show `CHANNEL` as a column or bar still let viewers read each channel. Cross-filtering
  (D10) keeps working within a data source.

### 1.6 Conventions on every page

- **Page subtitle.** A page-level text box at x 24, y 128, w 940, h 36, 13 px: one sentence on
  what the page covers and which filters apply. The text is given per page.
- **Captions.** Under every chart, a page-level text box (11 px, `#5F6368`, h 20-36) with the
  caption given in the spec. It is written as `Reads as: ... · Filters: ...`.
- **KPI cards.** **Add a chart** » **Scorecard**. **STYLE**:
  - **Compact numbers** off: the Expect values are exact.
  - **Decimal precision**: 0 for counts; 2 for money, rates, ROAS, scores and days.
  - Label: 12 px. Value: 24 px.
  - **Missing data**: `-`.

  Rename the metric per card. Click the metric chip in **SETUP**, then the pencil, then **Name**.
  This renames it in that chart only.
- **Number formats.** Counts with thousands separators and 0 decimals. Money with 2 decimals, no
  currency (D8). Percent fields with 2 decimals (`0.151694` → `15.17%`).
- **Month axes.** For `MONTH_START` / `COHORT_MONTH` as a chart dimension, click the **calendar
  icon** left of the field in **SETUP** » **Dimension**. Set **Type** to **Date & Time** » **Year
  Month** (newer versions may call it *Granularity*). This changes the field in that chart only.
  The data source keeps the full date (D2). (Verify in the UI: this path is not in Google's docs.)
- **More than 10 categories.** Bar, column and combo charts show the **Top N** rows only, and
  **Group the rest as "Others"** is on by default. For every such chart:
  - Set **Number of bars** (in **SETUP** » **Display**; combo charts may call it *Points to
    display*) to the number given. (Verify in the UI: the docs confirm the setting, not its tab.)
  - Switch **Group the rest as "Others"** off.
  - Check that the axis shows every month or category.
- **Channel colours.** On the first chart that is coloured by channel, set **STYLE** » **Color by**
  » **Dimension values** » **Manage dimension values**. The map applies wherever `CHANNEL` values
  appear (verify in the UI: check that charts on the other data sources pick up the same colours).
  Colours are colour-blind safe (Okabe-Ito):

  | `CHANNEL` | Colour |
  |---|---|
  | `affiliate` | `#0072B2` |
  | `display` | `#E69F00` |
  | `paid_search` | `#009E73` |
  | `paid_social` | `#CC79A7` |
  | `video` | `#D55E00` |

- **Other colours.**
  - Single-series charts: `#1F3B57` (navy).
  - Second series: `#8A9BAE` (grey).
  - Score segments: `Low` `#C6DBEF`, `Medium` `#6BAED6`, `High` `#08519C`.
- **Cross-filtering** (D10): **SETUP**, at the bottom » **Chart interactions** » **Cross-filtering**.
  - On for the charts marked "on".
  - Off for the charts with a time axis (P1-08, P1-10, P2-09, P4-07) and for the funnel (P2-06,
    P2-07). P3-08 is a combo chart on a category axis (`SCORE_BAND`), so it stays on.
  - Viewers undo a cross-filter by clicking the value again or with right-click » **Reset
    action**.
- **Tables.**
  - **Rows per page** as given.
  - **Show summary row** on, where stated. The summary row re-aggregates the calculated ratios,
    so it must show the totals in the Expect line, e.g. ROAS 4.77. If a summary row ever shows a
    sum of ratios instead, for example a ROAS in the hundreds, switch it off and record it.
  - Leave **Ignore canvas filters in summary row** off (Google added the option to make totals
    ignore viewer filters in 2024). With it on, the summary row would keep the all-campaign totals
    when a campaign or channel is selected, and the P1-12, P2-13 and P4-10 checks would fail.
  - Viewers can re-sort a table by clicking a column header.
- **Never:**
  - `SUM` or `AVG` a stored ratio column.
  - Blend data sources.
  - Add a chart-level calculated field.
  - Pick `START_DATE` or `START_MONTH` as a date range dimension.

### 1.7 KPI comparison: what and why

The plan asks for "KPI comparison". The obvious way is a scorecard's **Comparison date range »
Previous year**, which compares the selected range with the same range one year earlier. With the
default range of 2023-01-01..2025-12-31, that compares two overlapping three-year windows:

- 2023-2025 against 2022-2024, half of which is empty.
- For spend, that is 4,523,050.02 against 1,458,262.41 + 1,971,198.34 = 3,429,460.75 (`03 [12]`).
- The arrow would show **+31.9%**: a number that means nothing.

"Previous period" would compare with 2020-2022, where there is no data at all.

So the main KPI cards show the selected period only. The comparison is a separate strip of five
cards, **"2025 vs 2024"** (P1-K1..P1-K5):

- Each card has its **own fixed date range**, 2025-01-01..2025-12-31, with comparison **Previous
  year**, i.e. 2024.
- A chart-level date range overrides the date range control, so the strip always compares the
  latest full year with the year before.
- It still follows the channel control.
- Volumes are on the activity basis. The rate is on the lead-cohort basis (leads created in each
  year), labelled as such.
- The strip makes the main story checkable: 2025 volumes fall by a third or more because fewer
  campaigns ran (22 started against 50, `03 [12]`), while the conversion rate does not move.

A year table (rows 2023, 2024, 2025) was the alternative. It was not chosen: Data Studio cannot
show a year-over-year change column without a calculated field that is not a ratio of sums.

## 2. Page 1: Marketing Overview

**Page subtitle:** `Activity in the selected date range: spend by spend date, leads by created
date, conversions by conversion date. The conversion rate is by lead cohort (leads created in the
range).`

```
y  128 ┌ subtitle ─────────────────────────────────────────────────────────────────────────────┐
y  172 │[P1-01 Campaigns][P1-02 Spend][P1-03 Impr.][P1-04 Clicks][P1-05 Leads][P1-06 Conv.][P1-07]│ h 96
y  284 │ "2025 vs 2024"  [K1 Active campaigns][K2 Spend][K3 Leads][K4 Conversions][K5 Conv. rate]│ h 80
y  384 │[P1-08 Monthly marketing spend trend (combo)    w 740 ][P1-09 Leads by channel   w 400 ] │ h 300
y  712 │[P1-10 Monthly conversion trend (time series)                                 w 1152 ] │ h 260
y 1000 │                                                                     [ Campaign ▾ ]    │ h 36
y 1044 │[P1-11 Campaign performance table                                            w 1152 ] │ h 420
y 1490 └───────────────────────────────────────────────────────────────────────────────────────┘
        captions (h 20-36) sit under each chart, inside the gaps
```

### KPI cards P1-01 .. P1-07

> **Build note, 2026-10-14 (observed in the live report).** `CAMPAIGN_ID` with aggregation *Count
> Distinct* on `DAILY` did **not** return distinct campaigns: the card showed 13,760 (all rows) and,
> with the `In flight only` filter, 11,240 (the in-flight campaign-days), instead of 120. The
> connector's query history shows it fetching raw rows (`SELECT ACTIVITY_DATE, CAMPAIGN_ID,
> IS_IN_FLIGHT FROM (...)`), so the distinct count is lost on the Data Studio side, apparently per
> date. **So P1-01 is built on `CH` instead: metric `CAMPAIGNS` (Sum) = 120, video = 24.** It
> follows the channel control but not the date control (always all campaigns). For the same reason
> **P1-K1 is dropped** from the comparison strip; the strip keeps P1-K2..P1-K5 and its caption keeps
> the started-campaign counts (22 vs 50) as text. The table below still lists the original design
> for reference.

Seven scorecards, each w 156, h 96, gap 10, at x = 24, 190, 356, 522, 688, 854, 1020, y 172.
Build the first card, then copy and paste it and change the source and metric. **Filters: date,
channel** for all seven.

| # | Card label | Source | Metric (aggregation) | Card filter | Decimals | Expect: default | 2024 | video |
|---|---|---|---|---|---:|---:|---:|---:|
| P1-01 | Total campaigns | `DAILY` | `CAMPAIGN_ID` (**Count Distinct**) | `In flight only` (below) | 0 | 120 | 60 | 24 |
| P1-02 | Total spend | `MM` | `SPEND` (Sum) | | 2 | 4,523,050.02 | 1,971,198.34 | 828,094.54 |
| P1-03 | Total impressions | `MM` | `IMPRESSIONS` (Sum) | | 0 | 436,844,819 | 175,148,406 *(sum)* | 55,205,469 |
| P1-04 | Total clicks | `MM` | `CLICKS` (Sum) | | 0 | 7,102,319 | 3,092,049 *(sum)* | 492,490 |
| P1-05 | Total leads | `MM` | `LEADS` (Sum) | | 0 | 261,684 | 107,371 | 25,799 |
| P1-06 | Conversions (booked) | `MM` | `CONVERSIONS` (Sum) | | 0 | 39,696 | 16,148 | 3,933 |
| P1-07 | Lead conversion rate | `COH` | *Lead conversion rate* | | 2 | 15.17% | 15.20% *(sum)* | 15.24% |

Sources:

- Default: `03 [6]`.
- 2024: `03 [12]`. The two *(sum)* volumes are the 12 rows of 2024 in `03 [7]`. The rate is
  16,322 / 107,371, from the 2024 rows of `04 [16]`.
- video: `04 [6]`, `04 [13]`, and `03 [8]` for campaigns.

**Card filter `In flight only`** (P1-01, P1-K1):

- In the card's **SETUP** » **Filter** » **ADD A FILTER** » **CREATE A FILTER**.
- Name `In flight only`; **Include** `IS_IN_FLIGHT` **Equal to (=)** `1` » **Save**.
- `IS_IN_FLIGHT` must be a dimension here (0.4: aggregation **None**). In the filter editor it is
  listed with the dimensions, in green. If it shows as a blue metric, the condition is tested on
  the card's total instead of on each day, and the card shows no data: fix 0.4 first (verify in the
  UI).
- It belongs to `DAILY` and is reused by P1-K1.
- Why: the post-flight days (`IS_IN_FLIGHT = 0`) carry late conversions, not running campaigns.
  The card counts campaigns in flight on at least one day of the range, the definition of
  `03 [12]` "active".

Caption, under the row: `Reads as: totals for the date range and channels selected; campaigns =
in flight on at least one day. Conversions are booked by conversion date; the rate is for the
leads created in the range (lead cohort). · Filters: date, channel`

### Comparison strip P1-K1 .. P1-K5: "2025 vs 2024"

- A label text box `2025 vs 2024 (fixed years)` at x 24, y 284, w 150, 12 px bold.
- Five scorecards, each w 186, h 80, gap 10, at x = 184, 380, 576, 772, 968.
- Each card's **SETUP**:
  - **Comparison type: Period**.
  - **Default date range: Custom**, Fixed 2025-01-01 to 2025-12-31.
  - **Comparison date range: Previous year**.
- **STYLE**:
  - Leave **Show absolute change** off. Turn it on only to check the second Expect figure.
  - Set **Positive change color** and **Negative change color** both to grey `#5F6368`. Up is not
    "good" for spend, and down is not "bad" for leads in a year with fewer campaigns.
- **Filters: channel** (fixed years; the date control does not change them).

| # | Card label | Source | Metric | Expect: value, change (absolute) | video |
|---|---|---|---|---|---|
| P1-K1 | Active campaigns | `DAILY` | `CAMPAIGN_ID` (Count Distinct), filter `In flight only` | 35, −41.7% (−25) | |
| P1-K2 | Spend | `MM` | `SPEND` (Sum) | 1,093,589.27, −44.5% (−877,609.07) | 129,218.74, −74.4% |
| P1-K3 | Leads | `MM` | `LEADS` (Sum) | 66,764, −37.8% (−40,607) | 3,889, −75.3% |
| P1-K4 | Conversions (booked) | `MM` | `CONVERSIONS` (Sum) | 10,769, −33.3% (−5,379) | |
| P1-K5 | Lead conversion rate | `COH` | *Lead conversion rate* | 15.18%, −0.1% (absolute shown as −0.02%, i.e. −0.02 points) | |

Sources:

- `03 [12]` gives the year values: active 35 / 60; `SPEND_YOY` −0.4452; `LEADS_YOY` −0.3782;
  `CONVERSIONS_YOY` −0.3331.
- video: `03 [9]`.
- P1-K5: 10,138 / 66,764 against 16,322 / 107,371 *(sum)*, from the 2025 and 2024 rows of `04 [16]`.
- Changes: (2025 − 2024) / 2024, from these numbers.

Caption: `Reads as: calendar 2025 against calendar 2024, whatever the date range. Volumes fall
because fewer campaigns ran (22 started in 2025 vs 50 in 2024); the lead conversion rate does not
move. · Filters: channel`

### P1-08 Monthly marketing spend trend

- **Chart:** **Combo chart**, x 24, y 384, w 740, h 300. **Source:** `MM`. Date range dimension
  `MONTH_START` (automatic; check it in **SETUP**).
- **Dimension:** `MONTH_START` as **Year Month** (1.6).
- **Metrics:**
  - `SPEND` (Sum), renamed `Spend`.
  - `ACTIVE_CAMPAIGNS` (Sum), renamed `Campaigns in flight`. Correct here because the dimension is
    the month (0.4).
- **Sort:** `MONTH_START` ascending. **Number of bars / points:** 36, "Others" off.
- **STYLE:**
  - Series 1 (`Spend`): **Bars**, **Axis: Left**, colour `#1F3B57`.
  - Series 2 (`Campaigns in flight`): **Line**, **Axis: Right**, colour `#8A9BAE`.
  - Left axis min 0. Right axis min 0.
- **Filters:** date, channel. **Cross-filtering:** off.
- **Caption:** `Reads as: spend per month by spend date (bars, left) next to the number of
  campaigns in flight (line, right); spend follows the number of running campaigns. · Filters:
  date, channel`
- **Expect** (`03 [7]`):
  - 36 months, 2023-01 to 2025-12.
  - 2023-01: 23,686.55 and 3 campaigns.
  - Peak spend 2024-10: 219,378.73 (18 campaigns).
  - Most campaigns 2024-09: 20.
  - 2025-12: 807.04 and 1.
  - **video:** months without video spend show 0, and the line shows video campaigns only.

### P1-09 Leads by channel

- **Chart:** **Bar chart**, **STYLE** » **Horizontal**. x 784, y 384, w 392, h 300. **Source:**
  `MM`.
- **Dimension:** `CHANNEL`. **Metric:** `LEADS` (Sum), renamed `Leads`.
- **Sort:** `Leads` descending. **Number of bars:** 5.
- **STYLE:**
  - **Color by: Dimension values**: set the channel colours here (1.6).
  - **Show data labels** on.
- **Filters:** date, channel. **Cross-filtering:** **on**. Clicking a channel filters the page
  (other data sources too, if G2 passed; verify in the UI: G2 tests a control, and Google's
  field-ID docs cover controls, not chart interactions).
- **Caption:** `Reads as: leads created in the range, by channel (last-touch attributed). Every
  channel ran 24 campaigns. · Filters: date, channel`
- **Expect:**
  - Default (`03 [8]`): affiliate 67,849, paid_search 65,268, paid_social 57,619, display 45,149,
    video 25,799.
  - **2024** (`03 [9]`): paid_search 29,566, affiliate 28,727, paid_social 21,435, video 15,733,
    display 11,910.

### P1-10 Monthly conversion trend

The plan's "Monthly Conversion Trend" is the number of conversions **booked** per month (activity
basis). The monthly conversion **rate** needs the lead-cohort basis, so it is on page 2 (P2-09),
never on this activity axis.

- **Chart:** **Time series**, x 24, y 712, w 1152, h 260. **Source:** `MM`.
- **Dimension:** `MONTH_START` as **Year Month**.
- **Metrics:**
  - `CONVERSIONS` (Sum), renamed `Conversions (trial or purchase)`, colour `#1F3B57`.
  - `PURCHASES` (Sum), renamed `of which purchases`, colour `#8A9BAE`.
- **STYLE:** both series **Line**, Left axis, min 0. **Missing data: Line to zero** (the table has
  a row for every month, so nothing is missing).
- **Filters:** date, channel. **Cross-filtering:** off.
- **Caption:** `Reads as: conversions booked per month by conversion date, whichever month the
  lead came from (activity basis). Not a conversion rate: 34.45% of conversions land in a later
  month than their lead. · Filters: date, channel`
- **Expect** (`03 [7]`):
  - 2023-01: 110 / 48.
  - Peak 2024-10: 1,830 / 749.
  - 2025-12: 61 / 22.
  - **2024:** 12 points; the series sums to 16,148 (P1-06).

### P1-12 Campaign drop-down (page 1)

- **Add a control** » **Drop-down list**, x 996, y 1000, w 180, h 36. **Source:** `CAMP`.
  **Control field:** `CAMPAIGN_NAME`.
- **Order:** `CAMPAIGN_NAME` ascending. **Default selection:** empty (all).
- **STYLE:** **Single select** off; **Enable search box** on.
- **Filters it applies to:** the campaign-grain charts of this page only: P1-11. No other source
  has `CAMPAIGN_NAME` (D6).
- **Expect** (`07 [26]`): select `Affiliate 2024 080`. P1-11 shows one row, 17,904.18 / 2,644 /
  394 / 232,990.96 / 6.77 / 14.90% / 13.01, and its summary row the same values. P1-01..P1-10 do
  not change.

### P1-11 Campaign performance table

- **Chart:** **Table**, x 24, y 1044, w 1152, h 420. **Source:** `CAMP`. No date range dimension
  (D3).
- **Dimensions:** `CAMPAIGN_NAME` (renamed `Campaign`), `CHANNEL`, `OBJECTIVE`.
- **Metrics:**
  - `SPEND`, `LEADS`, `CONVERTED_LEADS` (renamed `Converted leads`), `REVENUE` (renamed
    `Attributed revenue`), all Sum.
  - *Cost per lead*, *Lead conversion rate*, *ROAS (attributed)*.
- **Sort:** `SPEND` descending. **Rows per page:** 10. **Show summary row:** on.
- **STYLE:** for *ROAS (attributed)*, **Bar** column type (shows the number and a bar).
- **Filters:** channel, campaign (full range: whole campaigns, unaffected by the date control).
  **Cross-filtering:** on.
- **Caption:** `Reads as: every campaign over its whole window (full range), largest spend first;
  ratios are each campaign's own sums. Small campaigns have noisy ratios. · Filters: channel,
  campaign`
- **Expect** (`03 [14]`, summary `03 [6]`):
  - Row 1: `Display 2024 093`, display, awareness, 72,153.85, 3,273, 478, 250,142.87, 22.05,
    14.60%, 3.47.
  - Row 2: `Paid Search 2024 021`, 71,337.50, 4,727, 691, 380,892.89, 15.09, 14.62%, 5.34.
  - Row 3: `Paid Social 2025 102`, 67,070.47, 3,836, 571, 270,077.02, 17.48, 14.89%, 4.03.
  - Summary row: 4,523,050.02, 261,684, 39,696, 21,561,839.01, 17.28, 15.17%, 4.77.
  - 120 rows in 12 pages.

## 3. Page 2: Conversion Funnel

**Page subtitle:** `The aggregate campaign funnel over the full range 2023-2025 (not one person's
journey). Only the "Conversion over time" block follows the date range.`

```
y  128 ┌ subtitle ──────────────────────────────────────────────────────────────────────────────┐
y  172 │[P2-01 CTR][P2-02 Click-to-lead][P2-03 Lead conv. rate][P2-04 Cost/lead][P2-05 Cost/conv.]│ h 96
y  292 │[P2-06 Funnel chart                 w 560 ][P2-07 Funnel stage table            w 576 ]│ h 340
y  664 │[P2-08 Channel funnel comparison table                                       w 1152 ] │ h 250
y  948 │ "Conversion over time (follows the date range)"                                         │
y  972 │[P2-09 Lead conversion rate by lead cohort month w 800 ][P2-10 Mean days to convert     ]│ h 90
y      │                                                       [P2-11 Converted in a later mth]│ h 90
y      │                                                       [P2-12 Conversions after end   ]│ h 90
y 1290 │                                                                     [ Campaign ▾ ]     │
y 1334 │[P2-14 Campaign conversion rate table                                        w 1152 ] │ h 420
y 1780 └────────────────────────────────────────────────────────────────────────────────────────┘
```

### KPI cards P2-01 .. P2-05

Five scorecards, each w 222, h 96, gap 10, at x = 24, 256, 488, 720, 952, y 172. **Source:** `CH`
(full range). **Filters: channel.**

| # | Card label | Metric | Decimals | Expect: default | video |
|---|---|---|---:|---:|---:|
| P2-01 | CTR | *Click-through rate* | 2 | 1.63% | 0.89% |
| P2-02 | Click-to-lead rate | *Click-to-lead rate* | 2 | 3.68% | 5.24% |
| P2-03 | Lead conversion rate | *Lead conversion rate* | 2 | 15.17% | 15.24% |
| P2-04 | Cost per lead | *Cost per lead* | 2 | 17.28 | 32.10 |
| P2-05 | Cost per conversion | *Cost per conversion* | 2 | 113.94 | 210.55 |

Sources: `04 [6]`, `04 [8]`, `04 [13]`.

Caption: `Reads as: funnel ratios over the full range for the channels selected; each is a ratio
of totals (aggregate units), not a person's probability. A conversion is a trial or a purchase.
· Filters: channel`

### P2-06 Funnel chart

- **Chart:** **Funnel chart**, x 24, y 292, w 560, h 340. **Source:** `FUN`.
- **Dimension:** `STAGE`. **Metric:** `STAGE_VALUE` (Sum).
- **Sort:** `STAGE_ORDER`, aggregation **Min** (the default from 0.4), **Ascending** (verify in
  the UI: Google's funnel reference says the sort slot takes "a dimension").
  - If the sort slot does not accept `STAGE_ORDER`, sort by `STAGE_VALUE` **Descending** instead.
  - In this data every stage is smaller than the one before it, in every channel (`06F 7 [8]`),
    so both give the order Impressions → Clicks → Leads → Converted leads → Purchases.
  - Never sort by `STAGE` (that would be alphabetical).
- **STYLE:**
  - **Funnel shape: Stepped bar**. Not *Inverted triangle* or proportional heights: the stages
    are different units.
  - **Data labels: Number + Percentage**; **Percentage type: % of previous**. The "% of
    previous" label of a stage is `STAGE_VALUE` over the previous stage's value, so it is exactly
    *Stage conversion*.
  - **Color by:** Single color `#1F3B57`.
- **Filters:** channel (full range). **Cross-filtering:** off. Clicking a stage would filter only
  `FUN` charts by `STAGE`.
- **Caption:** `Reads as: impressions → clicks → leads → converted leads → purchases, summed over
  campaigns (full range). Percent = share of the previous stage. Purchases are the converted leads
  that bought (the rest became trials), not a step after a trial. Widths of the last stages are
  tiny because the stages span 436.8 million to 16,691. · Filters: channel`
- **Expect** (`06F 7 [9]`):
  - Default: Impressions 436,844,819 · Clicks 7,102,319 (1.63%) · Leads 261,684 (3.68%) ·
    Converted leads 39,696 (15.17%) · Purchases 16,691 (42.05%).
  - The first stage's percentage may show as 100% or be blank.
  - **video** (`06F 7 [8]`): 55,205,469 · 492,490 (0.89%) · 25,799 (5.24%) · 3,933 (15.24%) ·
    1,638 (41.65%).

### P2-07 Funnel stage table

- **Chart:** **Table**, x 600, y 292, w 576, h 340. **Source:** `FUN`.
- **Dimension:** `STAGE`.
- **Metrics:**
  - `STAGE_VALUE` (Sum), renamed `Value`.
  - *Stage conversion*, renamed `% of previous stage`.
  - *Share of top of funnel*, renamed `% of impressions`. Set it to 4 decimals if the field panel
    offers decimal precision.
- **Sort:** `STAGE_ORDER` (Min) ascending. **Rows per page:** 5.
- **Show summary row:** **off**. `STAGE_VALUE` adds up within a stage only, so a total would add
  impressions to purchases.
- **Filters:** channel. **Cross-filtering:** off.
- **Caption:** `Reads as: exact stage values and ratios; each ratio is a sum over the selected
  channels divided by a sum (stays correct for any channel set). · Filters: channel`
- **Expect** (`06F 7 [9]`):

  | `STAGE` | Value | % of previous stage | % of impressions (2 dp / 4 dp) |
  |---|---:|---:|---:|
  | Impressions | 436,844,819 | null / `-` | 100.00% / 100.0000% |
  | Clicks | 7,102,319 | 1.63% | 1.63% / 1.6258% |
  | Leads | 261,684 | 3.68% | 0.06% / 0.0599% |
  | Converted leads | 39,696 | 15.17% | 0.01% / 0.0091% |
  | Purchases | 16,691 | 42.05% | 0.00% / 0.0038% |

### P2-08 Channel funnel comparison

- **Chart:** **Table**, x 24, y 664, w 1152, h 250. **Source:** `CH`.
- **Dimension:** `CHANNEL`.
- **Metrics:**
  - `IMPRESSIONS`, `CLICKS`, *Click-through rate*, `LEADS`, *Click-to-lead rate*,
    `CONVERTED_LEADS` (renamed `Converted leads`), *Lead conversion rate*.
  - `LCR_CI_LOW` (renamed `95% CI low`), `LCR_CI_HIGH` (renamed `95% CI high`): stored Wilson
    bounds at channel grain, one row per channel (D9).
  - *Cost per lead*, *Cost per conversion*.
- **Sort:** *Lead conversion rate* descending. **Rows per page:** 5.
- **Show summary row:** **off**. A summary would add up the interval bounds. The totals are the
  cards P2-01..P2-05.
- **STYLE:** **Heatmap** column type for *Click-through rate*, *Click-to-lead rate* and *Cost per
  lead*.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: the funnel per channel, full range. Channels differ at the click (CTR,
  cost per lead), not detectably in lead conversion: all five 95% intervals contain the pooled
  15.17% (chi-square p = 0.26). · Filters: channel`
- **Expect** (`04 [6]`, `04 [8]`, `04 [13]`):

  | `CHANNEL` | Impressions | Clicks | CTR | Leads | Click-to-lead | Converted | Lead conv. rate | 95% CI | Cost/lead | Cost/conv. |
  |---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
  | paid_search | 49,837,405 | 1,740,314 | 3.49% | 65,268 | 3.75% | 10,019 | 15.35% | 15.08%-15.63% | 13.74 | 89.54 |
  | affiliate | 95,314,042 | 2,386,856 | 2.50% | 67,849 | 2.84% | 10,352 | 15.26% | 14.99%-15.53% | 12.64 | 82.87 |
  | video | 55,205,469 | 492,490 | 0.89% | 25,799 | 5.24% | 3,933 | 15.24% | 14.81%-15.69% | 32.10 | 210.55 |
  | paid_social | 89,520,215 | 1,602,785 | 1.79% | 57,619 | 3.59% | 8,648 | 15.01% | 14.72%-15.30% | 17.09 | 113.87 |
  | display | 146,967,688 | 879,874 | 0.60% | 45,149 | 5.13% | 6,744 | 14.94% | 14.61%-15.27% | 21.16 | 141.65 |

### P2-09 .. P2-12 Conversion over time (date-aware block)

Above the block, add a text box `Conversion over time (follows the date range): rate, lag and
cross-month share by lead cohort month; after-end conversions by conversion date` at x 24, y 948,
12 px bold. Each item here follows the date range on its own date field: P2-09..P2-11 by
`COHORT_MONTH` (leads created in the range), P2-12 by `ACTIVITY_DATE` (conversions booked in the
range). None of them shares an axis with the other basis.

**P2-09 Lead conversion rate by lead cohort month**

- **Chart:** **Time series**, x 24, y 972, w 800, h 290. **Source:** `COH`. Date range dimension
  `COHORT_MONTH`.
- **Dimension:** `COHORT_MONTH` as **Year Month**, renamed `Lead cohort month`.
- **Metric:** *Lead conversion rate*.
- **STYLE:**
  - **Missing data: Line Breaks**. With a channel filter, a month without leads gives 0/0; *Line
    To Zero* would draw that as a false 0%.
  - Left axis **min 0**: the line is flat, and an axis from 0 shows that honestly.
- **Filters:** date (by cohort month), channel. **Cross-filtering:** off.
- **Caption:** `Reads as: of the leads created in each month, the share that converted (trial or
  purchase) within the observed 0-21 days. Lead-cohort basis: never compare with the activity
  charts' months. · Filters: date (cohort month), channel`
- **Expect** (`04 [16]`, `04 [17]`):
  - 36 points between 13.94% (2025-09, the lowest) and 16.92% (2025-12, the highest, 11 of 65
    leads).
  - 2023-01: 16.00%.
  - **2025:** 12 points; the first is 2025-01 at 15.36%, the last 2025-12 at 16.92%.

**P2-10 .. P2-12 Conversion time** (three scorecards stacked)

Each w 336, h 90, at x 840, y 972 / 1072 / 1172. **STYLE** as the KPI cards.

| # | Card label | Source | Metric | Card filter | Decimals | Expect: default | 2025 | video |
|---|---|---|---|---|---:|---:|---:|---:|
| P2-10 | Mean days to convert | `COH` | *Mean days to convert* | | 2 | 10.51 | | 10.38 |
| P2-11 | Converted in a later month | `COH` | *Cross-month share* | | 2 | 34.45% | 32.85% *(sum)* | |
| P2-12 | Conversions after campaign end (booked in range) | `DAILY` | `CONVERSIONS` (Sum) | `After flight` (below) | 0 | 4,716 | | 406 |

Sources:

- Default: `04 [18]`, `04 [17]`.
- 2025: 3,330 / 10,138 from the 2025 rows of `04 [16]`.
- video: `04 [18]`. The `AFTER_CAMPAIGN_END` column there counts the same conversions: converted
  after the campaign's `END_DATE`.

Card filter **`After flight`**: in P2-12 **SETUP** » **Filter** » **ADD A FILTER** » **CREATE A
FILTER**. Name `After flight`; **Include** `IS_IN_FLIGHT` **Equal to (=)** `0` » **Save**. As for
`In flight only`, `IS_IN_FLIGHT` must be a green dimension in the filter editor (0.4; verify in the
UI).

Caption, under the cards: `Reads as: the mean lag from lead to conversion is 10.5 days (flat
0-21, median 10, a property of the synthetic data); a third of conversions land in a later month
than their lead, which is why rates use the lead cohort; conversions after the campaign ended
would be lost by a campaign-window filter. · Filters: date, channel`

### P2-13 Campaign drop-down (page 2)

The same as P1-12 (copy and paste it): x 996, y 1290, w 180, h 36, source `CAMP`, field
`CAMPAIGN_NAME`. It applies to P2-14 only.

- **Expect** (`07 [26]`): select `Affiliate 2024 080`. P2-14 shows one row, 2,644 / 394 / 14.90%,
  and its summary row the same values. P2-01..P2-12 do not change.

### P2-14 Campaign conversion rate table

- **Chart:** **Table**, x 24, y 1334, w 1152, h 420. **Source:** `CAMP`.
- **Dimensions:** `CAMPAIGN_NAME` (renamed `Campaign`), `CHANNEL`, `OBJECTIVE`.
- **Metrics:** `LEADS`, `CONVERTED_LEADS` (renamed `Converted leads`), *Lead conversion rate*
  (column type **Bar**).
- **Sort:** *Lead conversion rate* descending. **Rows per page:** 10. **Show summary row:** on.
- **Filters:** channel, campaign. **Cross-filtering:** on.
- **Caption:** `Reads as: lead conversion rate per campaign (full range). The top and bottom are
  small campaigns: across the 120 campaigns the differences are consistent with chance (chi-square
  p > 0.05); read Leads next to the rate. · Filters: channel, campaign`
- **Expect** (`04 [11]`):
  - Rows 1-3: `Video 2024 054` 459 / 86 / 18.74%; `Video 2024 029` 1,142 / 201 / 17.60%;
    `Affiliate 2024 030` 2,205 / 366 / 16.60%.
  - Re-sorted ascending (click the header), rows 1-3: `Video 2023 084` 145 / 14 / 9.66%;
    `Video 2023 074` 934 / 119 / 12.74%; `Video 2024 034` 1,044 / 140 / 13.41%.
  - Summary row: 261,684 / 39,696 / 15.17%.

## 4. Page 3: Lead Quality & CRM

**Page subtitle:** `Lead score and conversion over the full range 2023-2025. These tables carry no
date, so the date range control does not change this page; the channel filter does.`

How the score is produced is undocumented. Everything on this page is an association in this
synthetic dataset, not evidence that the score predicts conversion.

```
y  128 ┌ subtitle ──────────────────────────────────────────────────────────────────────────────┐
y  172 │[P3-01 Leads][P3-02 Avg score][P3-03 Lead conv. rate][P3-04 Purchase rate][P3-05 Days]  │ h 96
y  292 │[P3-06 Conversion by score segment w 460 ][P3-07 Score segment table          w 676 ]  │ h 300
y  624 │[P3-08 Leads and conversion by score band w 740 ][P3-09 Days to convert by ch. w 396 ] │ h 300
y  956 │[P3-10 Channel lead quality table   w 680 ][P3-11 Score mix by channel        w 456 ] │ h 260
y 1250 └────────────────────────────────────────────────────────────────────────────────────────┘
```

### KPI cards P3-01 .. P3-05

Five scorecards, each w 222, h 96, gap 10, at x = 24, 256, 488, 720, 952, y 172. **Source:** `LQ`.
**Filters: channel.**

| # | Card label | Metric | Decimals | Expect: default | video |
|---|---|---|---:|---:|---:|
| P3-01 | Total leads | `LEADS` (Sum) | 0 | 261,684 | 25,799 |
| P3-02 | Average lead score | *Average lead score* | 2 | 50.57 | 50.64 |
| P3-03 | Lead conversion rate | *Lead conversion rate* | 2 | 15.17% | 15.24% |
| P3-04 | Purchase rate | *Purchase rate* | 2 | 6.38% | 6.35% |
| P3-05 | Mean days to convert | *Mean days to convert* | 2 | 10.51 | 10.38 |

Sources: `05 [6]`, `05 [10]`, `05 [13]`, `06 [7]`.

Caption: `Reads as: all leads of the selected channels, full range; conversion = trial or purchase
within 0-21 days. · Filters: channel`

### P3-06 Conversion by lead score segment

- **Chart:** **Column chart** (Bar chart, **Vertical**), x 24, y 292, w 460, h 300. **Source:**
  `LQ`.
- **Dimension:** `LEAD_SCORE_SEGMENT`. **Metric:** *Lead conversion rate*.
- **Sort:** `SCORE_BAND_MIN` (**Min**) ascending, which gives Low, Medium, High. Text order would be
  High, Low, Medium.
- **STYLE:**
  - **Color by: Dimension values**, with the segment colours of 1.6.
  - **Show data labels** on. Left axis min 0.
- **Filters:** channel. **Cross-filtering:** on (filters the other `LQ` charts by segment).
- **Caption:** `Reads as: share of leads that converted, by score segment (Low 1-40, Medium 41-70,
  High 71-100). Rises with the score in this data; most leads of every segment do not convert.
  · Filters: channel`
- **Expect:**
  - Default (`05 [6]`): Low 9.12%, Medium 16.18%, High 22.19%.
  - **video** (`05 [11]`): 8.95%, 16.37%, 22.41%.

### P3-07 Score segment table

- **Chart:** **Table**, x 500, y 292, w 676, h 300. **Source:** `LQ`.
- **Dimension:** `LEAD_SCORE_SEGMENT` (renamed `Segment`).
- **Metrics:**
  - `LEADS` (Sum).
  - `LEADS` (Sum) a second time: click its chip » **Comparison calculation** » **Percent of total**,
    and rename it `Share of leads`.
  - `CONVERTED_LEADS` (renamed `Converted`).
  - *Lead conversion rate*, *Purchase rate*, *Average lead score*, *Mean days to convert*.
- **Sort:** `SCORE_BAND_MIN` (Min) ascending. **Rows per page:** 3. **Show summary row:** on.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: each segment's leads, conversion and purchase rates, mean score and
  mean days to convert; the lag does not differ by segment. · Filters: channel`
- **Expect** (`05 [6]`, `07 [21]`, `05 [13]`):

  | Segment | Leads | Share | Converted | Lead conv. rate | Purchase rate | Avg score | Mean days |
  |---|---:|---:|---:|---:|---:|---:|---:|
  | Low | 104,245 | 39.84% | 9,505 | 9.12% | 3.80% | 20.48 | 10.61 |
  | Medium | 78,862 | 30.14% | 12,758 | 16.18% | 6.78% | 55.52 | 10.46 |
  | High | 78,577 | 30.03% | 17,433 | 22.19% | 9.39% | 85.52 | 10.48 |
  | Summary | 261,684 | 100.00% | 39,696 | 15.17% | 6.38% | 50.57 | 10.51 |

### P3-08 Leads and conversion by 10-point score band

- **Chart:** **Combo chart**, x 24, y 624, w 740, h 300. **Source:** `LQ`.
- **Dimension:** `SCORE_BAND`.
- **Metrics:** `LEADS` (Sum) and *Lead conversion rate*.
- **Sort:** `SCORE_BAND` ascending (zero-padded text: `01-10` ... `91-100`). **Number of bars /
  points:** 10, "Others" off.
- **STYLE:**
  - Series 1 `LEADS`: **Bars**, **Axis: Left**, `#C6DBEF`.
  - Series 2 *Lead conversion rate*: **Line**, **Axis: Right**, `#08519C`, data labels on.
  - Both axes min 0.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: leads are spread evenly over the score (bars); the conversion rate rises
  at every 10-point step (line). An association, not a validated predictor. · Filters: channel`
- **Expect** (`05 [8]`, the band rows):

  | Band | Leads | Rate |
  |---|---:|---:|
  | 01-10 | 26,193 | 6.27% |
  | 11-20 | 26,058 | 7.95% |
  | 21-30 | 25,748 | 10.19% |
  | 31-40 | 26,246 | 12.07% |
  | 41-50 | 26,293 | 14.16% |
  | 51-60 | 26,173 | 16.03% |
  | 61-70 | 26,396 | 18.33% |
  | 71-80 | 26,184 | 20.30% |
  | 81-90 | 26,068 | 22.23% |
  | 91-100 | 26,325 | 24.02% |

### P3-09 Time to conversion by channel

- **Chart:** **Bar chart**, **Horizontal**, x 780, y 624, w 396, h 300. **Source:** `LQ`.
- **Dimension:** `CHANNEL`. **Metric:** *Mean days to convert*.
- **Sort:** `CHANNEL` ascending. **Number of bars:** 5.
- **STYLE:** **Color by: Dimension values**; data labels on; axis min 0.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: mean days from lead to conversion, by channel: the same everywhere
  (10.4-10.6). The full distribution is flat over 0-21 days, median 10 (docs/business_insights.md,
  Q5). · Filters: channel`
- **Expect** (`04 [18]`): affiliate 10.50, display 10.51, paid_search 10.50, paid_social 10.58,
  video 10.38.

### P3-10 Channel lead quality

- **Chart:** **Table**, x 24, y 956, w 680, h 260. **Source:** `LQ`.
- **Dimension:** `CHANNEL`.
- **Metrics:** `LEADS`, *Average lead score*, *Lead conversion rate*, *Purchase rate*.
- **Sort:** `LEADS` descending. **Rows per page:** 5. **Show summary row:** on.
- **STYLE:** **Heatmap** on *Lead conversion rate*.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: no channel brings better-scored or better-converting leads in this data
  (mean score 50.5-50.7; conversion 14.9-15.4%). Channels differ in what a lead costs (page 4).
  · Filters: channel`
- **Expect** (`05 [10]`, `06 [7]`):

  | `CHANNEL` | Leads | Avg score | Lead conv. rate | Purchase rate |
  |---|---:|---:|---:|---:|
  | affiliate | 67,849 | 50.56 | 15.26% | 6.38% |
  | paid_search | 65,268 | 50.66 | 15.35% | 6.44% |
  | paid_social | 57,619 | 50.47 | 15.01% | 6.33% |
  | display | 45,149 | 50.54 | 14.94% | 6.36% |
  | video | 25,799 | 50.64 | 15.24% | 6.35% |
  | Summary | 261,684 | 50.57 | 15.17% | 6.38% |

### P3-11 Score mix by channel (optional, about 5 minutes)

- **Chart:** **Stacked bar chart**, x 720, y 956, w 456, h 260. **Source:** `LQ`.
- **Dimension:** `CHANNEL`. **Breakdown dimension:** `LEAD_SCORE_SEGMENT`. **Metric:** `LEADS`
  (Sum).
- **STYLE:**
  - **Horizontal**; **Stacked bars** on; **100% stacking** on, if your version allows it with a
    breakdown dimension. Otherwise leave absolute stacks.
  - Segment colours of 1.6.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: every channel's leads split about 40/30/30 into Low/Medium/High.
  · Filters: channel`
- **Expect** (`05 [10]`), Low / Medium / High:

  | `CHANNEL` | Low | Medium | High |
  |---|---:|---:|---:|
  | affiliate | 39.88% | 30.18% | 29.93% |
  | display | 39.87% | 30.19% | 29.94% |
  | paid_search | 39.60% | 30.25% | 30.16% |
  | paid_social | 40.14% | 29.78% | 30.08% |
  | video | 39.58% | 30.43% | 29.99% |

## 5. Page 4: Marketing Efficiency & ROAS

**Page subtitle:** `Spend, last-touch attributed revenue and cost efficiency. Cards, channel and
campaign charts cover whole campaigns over the full range (so budget utilisation is valid); only
the monthly chart follows the date range. ROAS is attributed, not causal.`

```
y  128 ┌ subtitle ──────────────────────────────────────────────────────────────────────────────┐
y  172 │[P4-01 Spend][P4-02 Revenue][P4-03 ROAS][P4-04 Cost/lead][P4-05 Cost/conv.][P4-06 Budget]│ h 96
y  292 │[P4-07 Monthly spend vs attributed revenue (combo)                            w 1152 ] │ h 300
y  624 │[P4-08 Channel efficiency table                w 760 ][P4-09 Spend vs revenue share  ] │ h 260
y  910 │                                                                     [ Campaign ▾ ]     │
y  954 │[P4-11 Campaign ROAS ranking table             w 760 ][P4-12 Top 10: cost/purchase  ] │ h 480
y 1460 │[P4-13 Budget allocation insights (text)                                      w 1152 ] │ h 130
y 1610 └────────────────────────────────────────────────────────────────────────────────────────┘
```

### KPI cards P4-01 .. P4-06

Six scorecards, each w 183, h 96, gap 10, at x = 24, 217, 410, 603, 796, 989, y 172. **Source:**
`CH` (whole campaigns, full range). **Filters: channel.**

| # | Card label | Metric | Decimals | Expect: default | video |
|---|---|---|---:|---:|---:|
| P4-01 | Total spend | `SPEND` (Sum) | 2 | 4,523,050.02 | 828,094.54 |
| P4-02 | Attributed revenue | `REVENUE` (Sum) | 2 | 21,561,839.01 | 2,087,554.22 |
| P4-03 | ROAS (attributed) | *ROAS (attributed)* | 2 | 4.77 | 2.52 |
| P4-04 | Cost per lead | *Cost per lead* | 2 | 17.28 | 32.10 |
| P4-05 | Cost per conversion | *Cost per conversion* | 2 | 113.94 | 210.55 |
| P4-06 | Budget utilisation | *Budget utilisation* | 2 | 83.47% | 83.24% |

Sources: `03 [6]`, `06 [7]`, `04 [13]`, `06 [25]`.

Caption: `Reads as: whole campaigns over the full range; ROAS = attributed revenue / spend (last
touch, not causal); budget utilisation = spend / planned budget of whole campaigns (none went
over budget). · Filters: channel`

### P4-07 Monthly spend vs attributed revenue

- **Chart:** **Combo chart**, x 24, y 292, w 1152, h 300. **Source:** `MM`.
- **Dimension:** `MONTH_START` as **Year Month**.
- **Metrics:**
  - `SPEND` (Sum), renamed `Spend`.
  - `REVENUE` (Sum), renamed `Attributed revenue (booked)`.
- **Sort:** `MONTH_START` ascending. **Number of bars / points:** 36, "Others" off.
- **STYLE:**
  - Series 1: **Bars**, **Axis: Left**, `#1F3B57`.
  - Series 2: **Line**, **Axis: Left**, `#E69F00`. Same axis on purpose: both are money.
  - Left axis min 0.
- **Filters:** date, channel. **Cross-filtering:** off.
- **Caption:** `Reads as: spend per month (by spend date) and attributed revenue booked per month
  (by conversion date, activity basis). A month's revenue partly comes from earlier months' leads,
  so a single month's ratio is not a campaign's ROAS (2025-12: 807.04 of spend, 31,085.00 booked).
  · Filters: date, channel`
- **Expect** (`06 [31]`):
  - 2023-01: 23,686.55 / 52,800.58.
  - Peak 2024-10: 219,378.73 / 961,348.25.
  - 2025-12: 807.04 / 31,085.00.
  - The 36 months add up to 4,523,050.02 / 21,561,839.01 (the cards P4-01 / P4-02).
  - **2024:** 12 months, sums 1,971,198.34 / 8,677,647.82 (`03 [12]`).

### P4-08 Channel efficiency comparison

- **Chart:** **Table**, x 24, y 624, w 760, h 260. **Source:** `CH`.
- **Dimension:** `CHANNEL`.
- **Metrics:** `BUDGET`, `SPEND`, `REVENUE` (renamed `Attributed revenue`), *ROAS (attributed)*,
  *Cost per lead*, *Cost per conversion*, *Cost per purchase*, *Budget utilisation*.
- **Sort:** *ROAS (attributed)* descending. **Rows per page:** 5. **Show summary row:** on.
- **STYLE:** **Heatmap** on *ROAS (attributed)* and *Cost per purchase*.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: per channel over the full range. The ROAS gap is a cost-per-lead gap:
  purchase rate and revenue per purchase are nearly equal across channels. · Filters: channel`
- **Expect** (`06 [7]`, `04 [13]`, `06 [25]`):

  | `CHANNEL` | Budget | Spend | Attributed revenue | ROAS | Cost/lead | Cost/conv. | Cost/purchase | Budget util. |
  |---|---:|---:|---:|---:|---:|---:|---:|---:|
  | affiliate | 1,025,491.41 | 857,835.07 | 5,610,700.73 | 6.54 | 12.64 | 82.87 | 198.02 | 83.65% |
  | paid_search | 1,079,299.66 | 897,091.53 | 5,439,329.35 | 6.06 | 13.74 | 89.54 | 213.39 | 83.12% |
  | paid_social | 1,180,823.70 | 984,731.88 | 4,690,137.28 | 4.76 | 17.09 | 113.87 | 270.09 | 83.39% |
  | display | 1,138,158.37 | 955,297.00 | 3,734,117.43 | 3.91 | 21.16 | 141.65 | 332.74 | 83.93% |
  | video | 994,869.02 | 828,094.54 | 2,087,554.22 | 2.52 | 32.10 | 210.55 | 505.55 | 83.24% |
  | Summary | 5,418,642.16 | 4,523,050.02 | 21,561,839.01 | 4.77 | 17.28 | 113.94 | 270.99 | 83.47% |

### P4-09 Spend share vs revenue share (budget allocation)

- **Chart:** **Column chart**, x 800, y 624, w 376, h 260. **Source:** `CH`.
- **Dimension:** `CHANNEL`.
- **Metrics:** `SPEND_SHARE` (renamed `Share of spend`) and `REVENUE_SHARE` (renamed `Share of
  attributed revenue`). Both are stored, Percent, one row per channel (D9).
- **Sort:** `REVENUE_SHARE` descending. **Number of bars:** 5.
- **STYLE:** series colours `#8A9BAE` (spend) and `#1F3B57` (revenue); data labels on.
- **Filters:** channel. **Cross-filtering:** on.
- **Caption:** `Reads as: each channel's share of all five channels' spend and attributed revenue
  (shares of the five, even when the channel filter hides some). · Filters: channel`
- **Expect** (`06 [33]`), spend / revenue:
  - affiliate 18.97% / 26.02%
  - paid_search 19.83% / 25.23%
  - paid_social 21.77% / 21.75%
  - display 21.12% / 17.32%
  - video 18.31% / 9.68%

### P4-10 Campaign drop-down (page 4)

The same as P1-12 (copy and paste it): x 996, y 910, w 180, h 36. It applies to P4-11 and P4-12.

- **Expect** (`07 [26]`): select `Affiliate 2024 080`. P4-11 shows one row, 17,904.18 /
  232,990.96 / 172 / 13.01 / 104.09 / 20,903.18 / 85.65%, and its summary row the same values.
  P4-12 shows one bar, 104.09. P4-01..P4-09 do not change.

### P4-11 Campaign ROAS ranking

- **Chart:** **Table**, x 24, y 954, w 760, h 480. **Source:** `CAMP`.
- **Dimensions:** `CAMPAIGN_NAME` (renamed `Campaign`), `CHANNEL`.
- **Metrics:**
  - `SPEND`, `REVENUE` (renamed `Attributed revenue`), `PURCHASES`.
  - *ROAS (attributed)* (column type **Bar**).
  - *Cost per purchase*, `BUDGET`, *Budget utilisation*.
- **Sort:** *ROAS (attributed)* descending. **Rows per page:** 15. **Show summary row:** on.
- **Filters:** channel, campaign. **Cross-filtering:** on.
- **Caption:** `Reads as: all 120 campaigns by attributed ROAS (whole campaigns). The ranking
  largely restates the channel ranking; small campaigns are noisy (read Purchases). Click a header
  to re-sort, e.g. by budget utilisation. · Filters: channel, campaign`
- **Expect** (`06 [15]`, summary `03 [6]`):
  - Row 1: `Affiliate 2024 080`, affiliate, 17,904.18, 232,990.96, 172, 13.01, 104.09.
  - Row 2: `Affiliate 2024 070`, 12.61.
  - Row 3: `Affiliate 2023 040`, 12.27.
  - Row 10: `Paid Search 2023 086`, 10.85.
  - Last row (page 8, row 120): `Video 2023 084`, 6,105.33, 11,132.24, 7, 1.82, 872.19.
  - Summary row: 4,523,050.02, 21,561,839.01, 16,691, 4.77, 270.99, 5,418,642.16, 83.47%.
  - Re-sorted by *Budget utilisation* ascending (`06 [29]`): row 1 `Affiliate 2023 100` 69.88%.
    Descending: row 1 `Affiliate 2025 115` 98.68%.

### P4-12 Top performing campaigns: lowest cost per purchase

"Top performing" here means the cheapest paying customers: spend per last-touch attributed
purchase (business question 3). This is a second lens next to the ROAS ranking.

- **Chart:** **Bar chart**, **Horizontal**, x 800, y 954, w 376, h 480. **Source:** `CAMP`.
- **Dimension:** `CAMPAIGN_NAME`. **Metric:** *Cost per purchase*.
- **Sort:** *Cost per purchase* **ascending**. **Number of bars:** 10, "Others" off.
- **STYLE:** single colour `#0072B2`; data labels on.
- **Filters:** channel, campaign. **Cross-filtering:** on.
- **Caption:** `Reads as: the 10 campaigns with the lowest spend per attributed purchase (whole
  campaigns). 9 of 10 are affiliate, mostly its smaller campaigns (larger affiliate campaigns have
  lower attributed ROAS, docs/business_insights.md Q7); part of any top-10 of ratios is noise, so
  expect the next flight to move toward the channel average. · Filters: channel, campaign`
- **Expect** (`06 [19]`), in order:

  | # | Campaign | Cost per purchase |
  |---:|---|---:|
  | 1 | `Affiliate 2023 040` | 102.20 |
  | 2 | `Affiliate 2024 070` | 103.70 |
  | 3 | `Affiliate 2024 080` | 104.09 |
  | 4 | `Affiliate 2025 095` | 107.72 |
  | 5 | `Affiliate 2025 035` | 112.07 |
  | 6 | `Paid Search 2023 086` | 115.76 |
  | 7 | `Affiliate 2023 050` | 117.79 |
  | 8 | `Affiliate 2025 110` | 118.23 |
  | 9 | `Affiliate 2024 005` | 119.28 |
  | 10 | `Affiliate 2024 045` | 119.82 |

### P4-13 Budget allocation insights (text box)

A page-level text box, x 24, y 1460, w 1152, h 130, 12 px. It holds commentary, not a KPI. Every
number in it is a number of [business_insights.md](business_insights.md#q7-where-should-the-budget-go-first-hypotheses-and-tests)
Q7 rounded to 2 decimals; the share differences are in percentage points (affiliate +0.070556 →
+7.06).
Text (exact):

```
Budget allocation: hypotheses to test, not recommendations (last-touch attribution, no experiment).
• Affiliate and paid_search earn a larger share of attributed revenue than of spend (+7.06 and +5.39 points); video and display a smaller one (−8.63 and −3.80).
• Within affiliate and paid_search the larger campaigns have lower ROAS (by spend tercile 11.64 → 4.86 and 8.08 → 5.03): average ROAS is not the return of the next unit of spend.
• Last touch may hide assists from video and display. A matched-market reallocation test and a video holdout would decide it (docs/business_insights.md, Q7).
```

The sources are `06 [33]` and `06 [35]`.

## 6. Validation

The dashboard is done when its numbers match the SQL results. The sign-off checklist, and the
place to record each result, is [docs/dashboard_validation.md](dashboard_validation.md). The Expect
lines in this spec are the same numbers, placed where you build, so you can check each component
as you go.

**While building**, after each component:

1. Compare it with its Expect line in the **default view**: full range, all channels, no campaign
   selected.
2. Run its spot checks (2024, video, a campaign), then reset the filters.
3. If a value differs, check these usual causes, in this order:
   - an active filter: the filter bar, a cross-filter, or a campaign selected;
   - the date range (fixed 2023-01-01..2025-12-31?) and the chart's date range dimension;
   - the aggregation (*Sum*, not *Average*; *Min* for sort keys);
   - "Group the rest as Others" or the number of bars;
   - a stored ratio picked instead of the calculated field;
   - the field type (Percent vs Number);
   - the summary row (section 1.6).

   Never change a formula away from 0.5 to make a number fit. Record the mismatch instead.
   Claude can then check the SQL side.

**Gates to record** (in the [sign-off](dashboard_validation.md#sign-off)): G2 (cross-source
channel filter, 1.4) and G1 (report-level date control on other pages, 1.5).

**Connector checks carried over from Phase 1**, after page 1 is built, as admin in Snowsight
(queries in section D of the Phase 1 checklist, in the git history:
[phase1_connection_test.md at dbe41f7](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/phase1_connection_test.md#d-what-snowflake-saw-as-the-admin-in-snowsight)):
the wrapped queries of `SVC_CRM_BI`; whether the `CHANNEL` filter is pushed down (the date filter
is documented as not pushed down); cache reuse; and the credits used. Result on 2026-10-17, from
the `SVC_CRM_BI` query history: the `CHANNEL` filter is pushed down as a `WHERE` with bind
parameters; the date filter is not, so Data Studio applies the date range itself. The Phase 1
public-link checks are part of section 7, and its one-chart Sheets rehearsal is covered by the
full swap (section 9).

## 7. Publishing

Do this after section 6 passes.

1. **Resource** » **Manage added data sources**: exactly the seven `MCRM ...` sources, every one
   **Reusable**, none **Embedded**. Fix an embedded one first (rebuild its charts on the reusable
   source).
2. **Attribution and provenance**: open each of the four pages in view mode. The report-level
   header shows the title, the provenance line and the CC BY 4.0 attribution.
3. **File** » **Report settings**: **Viewer data refresh** off. Every viewer cache miss runs a
   Snowflake query on the trial's credits.
4. **File** » **Publishing settings**: turn on **report publishing**, so that later edits stay in
   draft until you click **Publish**. This does not protect the data sources: edits to a reusable
   source, and credential changes, reach viewers at once.
5. **Share** » **Manage access** » link settings **"Anyone with the link can view"**. Never an
   "edit" option. "Anyone on the Internet can find and view" is not needed for a portfolio link.
6. **Incognito check**:
   - Open the link in a private window, not signed in.
   - All four pages render, with the default view (full range, all channels).
   - P1-02 shows 4,523,050.02, P2-06 shows 16,691 purchases, P3-06 shows High 22.19%, P4-03
     shows 4.77.
7. **Optional:** **File** » **Embed report** » **Enable embedding**, for a portfolio site. A GitHub
   README cannot embed it: use the screenshots (section 8) linked to the report.
8. **Cost while public.** Viewers share one cache (Owner's credentials, longest freshness). If a
   resource monitor suspends `MARKETING_WH`, the charts show a data error. **Stop** and report it;
   do not raise the quota.

## 8. Screenshots for the repository

The repository layout ([README.md](../README.md#-repository-structure)) has four images in
`docs/images/`:

| File | Page |
|---|---|
| `docs/images/overview.png` | 1. Marketing Overview |
| `docs/images/funnel.png` | 2. Conversion Funnel |
| `docs/images/lead_quality.png` | 3. Lead Quality & CRM |
| `docs/images/efficiency.png` | 4. Marketing Efficiency & ROAS |

1. Open the report in **view** mode with the default view: full range, all channels, no campaign,
   no cross-filter. Reloading the link resets everything.
2. Capture each page's full canvas. Either:
   - **(a) PDF route.** **File** » **Download** » **PDF**, current page (verify in the UI: Google's
     PDF page gives **Share** » **Download**, then the pages to include). Open the PDF in Preview »
     **File** » **Export...** » Format **PNG**, Resolution **144**. Or:
   - **(b) Screenshot route.** Zoom the browser out (Cmd −) until the whole canvas fits, then
     Cmd+Shift+5 » **Capture Selected Portion** around the canvas only.
3. Crop to the canvas. Before saving, check that the image shows:
   - no edit panels;
   - no Google account name, avatar or e-mail;
   - no data source settings;
   - **no Snowflake account URL or identifier**.

   Width at least 1200 px.
4. Save them under the four names. Leave them uncommitted: the commit happens later, in one batch.

## 9. Later: the Snowflake → Google Sheets swap

When the trial ends (about 2026-11-12), the live charts stop working once their cache expires. By
about **2026-11-07** the public report must read a frozen Google Sheets snapshot of the same
tables ([architecture.md](architecture.md#design-decisions), decision 8). The swap was done on
2026-10-18; what it took and how it was checked is in the
[pass-2 build log](dashboard_validation.md#build-log-pass-2-the-google-sheets-copy) of
dashboard_validation.md (the step-by-step runbook is in the git history:
[sheets_snapshot.md at dbe41f7](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/sheets_snapshot.md)).
The files come from `make export-marts`, which writes [exports/](../exports/README.md), and their
integrity is proven by `make export-check`.

What this spec already does to make the swap mechanical:

- The **seven data sources are exactly seven exported tables** (D1). Each is one worksheet of
  `exports/marketing_crm_dashboard_snapshot.xlsx`, with the same UPPERCASE column names.
- **All KPI logic is in the tables.** The only things to recreate on each Sheets source are:
  - the 22 calculated fields of 0.5, with the same names and formulas;
  - the field types and default aggregations of 0.4 (month columns as full dates; the campaign
    table's dates and `ACTIVITY_MONTH` as Text; percent types; `IS_IN_FLIGHT` with aggregation
    **None**);
  - the two card filters `In flight only` and `After flight`.

  Google: "Data Studio won't try to map your old fields in calculated fields and filters."
- **Field ID overrides for `CHANNEL` are always needed on the Sheets sources**, whatever G2 showed
  on Snowflake. Google's [controls page](https://docs.cloud.google.com/data-studio/about-controls)
  lists Google Sheets as a flexible-schema connector whose data sources do not share field IDs, so
  one channel drop-down filters several Sheets sources only after the IDs are unified. Add the
  override (**New ID** `channel`, Text) for `CHANNEL` of each of the seven Sheets sources before
  you re-select fields, then run gate G2 (1.4) again on the Sheets copy and record it in the
  sign-off's Pass 2 column. If it fails there, use the page-level fallback of 1.5.
- **Every Expect line stays valid.** After the swap, re-run section 6 on the Sheets version. The
  numbers must be identical, because the exported values are the Snowflake values written out
  exactly.
- **Provenance for the public version** (decision 8). Keep the header's provenance line (1.3) and
  add one more report-level text box under the controls: x 800, y 80, w 376, h 40; 10 px,
  `#5F6368`; text `This public version serves a frozen export from <date> via Google Sheets
  because the Snowflake trial ended; SQL in the repository: <repository link>.` Together the two
  boxes carry decision 8's note.
