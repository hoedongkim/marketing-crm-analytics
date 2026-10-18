# Google Sheets snapshot of the dashboard (Phase 6)

This runbook moves the Data Studio dashboard off the live Snowflake connector and onto a frozen
Google Sheets copy of the same MART tables, before the Snowflake trial ends
([architecture.md](architecture.md), decision 8).

- **Your part.** You do the Google steps by hand. They need your Google sign-in, so no script can do them.
- **The repository's part.** `make export-marts` writes the files and `make export-check` proves
  they equal Snowflake ([exports/README.md](../exports/README.md)).

Menu paths use `»`. Labels in **bold** are what the screen shows.

## Deadline

| Date | What |
|---|---|
| 2026-10-13 | Snowflake trial account created (30-day trial). |
| As soon as the live report passes [dashboard_validation.md](dashboard_validation.md) | Steps 1-9 below. Start early: the swap takes an afternoon, and step 7 needs the live report for side-by-side checks. |
| **about 2026-11-07** | **Deadline: the public link must point to the Sheets version.** That leaves a few days of margin before the trial ends. |
| about 2026-11-12 | The trial ends. A suspended account cannot run queries, so the live charts fail once their cache expires, and `make export-marts` and the live half of `make export-check` stop working. |

- **Check the real end date.** It is shown in Snowsight: the trial banner, or the billing page as
  the admin user.
- **The free balance can end the trial earlier.** The trial also ends when the free usage balance
  ($400) runs out. The daily resource monitor (4 credits) makes that unlikely before day 30.
- **If the tables change.** If a MART table changes after the snapshot (a dbt rebuild that changes
  data), see [When the MART tables change later](#when-the-mart-tables-change-later).

## Before you start

- [ ] **The live report is finished.** Every row of [dashboard_validation.md](dashboard_validation.md) matches.
- [ ] **One Google account.** You are signed in to Google Drive and Data Studio with the same personal
      Gmail account that owns the live report and its Snowflake data sources
      ([phase1_connection_test.md](phase1_connection_test.md), section A). Never transfer ownership of
      the report, the data sources or the Sheet.
- [ ] **The repository is set up.** You have it with `.venv` (`make setup`) and a working `.env`.

## Step 1. Export the tables and check them (terminal)

From the repository root:

```bash
make export-marts
make export-check
```

1. **Read the result.** Both must end without an error:
   - `export-marts` ends with `PASS  wrote 8 CSVs (14440 rows), marketing_crm_dashboard_snapshot.xlsx (9 sheets) and manifest.json to exports/ (exported <time>)`.
   - `export-check` ends with `OK    export check: 8 tables, files and live tables match manifest.json`.
2. **If a query fails because a resource monitor suspended the warehouse:** stop and resume the next
   day, when the daily monitor resets. Do not raise the quota for this.
3. **Write down the export time.** It is the `<time>` above (UTC; also `exported_at_utc` in
   `exports/manifest.json` and row 5 of the `README` sheet). The snapshot note in step 8 quotes its date.
4. **Commit `exports/`** with the rest of Phase 6 (you make the commits in this repository).

The export reads the tables as `SVC_CRM_BI` / `CRM_REPORTER`, the same identity as the Data Studio
connector, so it contains exactly what the live dashboard shows. What each file holds and how it is
checked: [exports/README.md](../exports/README.md).

## Step 2. Upload the workbook to My Drive

1. Open https://drive.google.com, signed in as the owner account.
2. Click **My Drive** in the left sidebar.
   - **Not Shared drives:** Data Studio cannot read files on shared drives.
3. Click **New » File upload** and choose `exports/marketing_crm_dashboard_snapshot.xlsx` from the repository.
   - **Use the `.xlsx`, never the CSVs.** A CSV imported into Sheets with automatic conversion
     turns `SCORE_BAND` values such as `01-10` into dates. The workbook's cells are already typed.

## Step 3. Convert it to a Google Sheets file and check it

The Google Sheets connector reads native Google Sheets files only. Excel files need a different
connector (Microsoft Excel), which this project does not use.

1. Double-click the uploaded file in Drive. It opens in Google Sheets with an **.XLSX** badge next to its name.
2. Click **File » Save as Google Sheets**. A converted copy opens in a new tab and is saved in the same folder.
   - If that menu item is missing: open https://sheets.new (a blank spreadsheet), then
     **File » Import » Upload**, choose the `.xlsx`, set **Import location** to **Replace spreadsheet** and
     click **Import data**.
3. Rename the converted file: click its title and type
   `Marketing CRM dashboard snapshot (MART export YYYY-MM-DD)`, with the export date from step 1.
4. **Check the converted file** (about five minutes):
   - [ ] **The file type.** No **.XLSX** badge next to the title: this is the native Google Sheets copy.
   - [ ] **The tabs**, in this order: `README`, `MART_CHANNEL_PERFORMANCE`, `MART_CAMPAIGN_PERFORMANCE`,
         `MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT`, `MART_CONVERSION_FUNNEL`, `MART_LEAD_QUALITY`,
         `FCT_CAMPAIGN_DAILY_ACTIVITY`, `DIM_CAMPAIGN`.
   - [ ] **The headers.** In every table tab, row 1 holds the UPPERCASE column names, bold and frozen.
         Do not rename them: they become the Data Studio field names.
   - [ ] **The row counts.** In every table tab, click cell A1 and press Ctrl+Down (Cmd+Down on a
         Mac): the last row is the one in the [table below](#last-row-of-each-tab) (the row count + 1).
   - [ ] **Spot values**:
     - `MART_CHANNEL_PERFORMANCE`, row 2 (affiliate): D2 `SPEND` = 857835.07, L2 `CTR` = 0.025042, S2 `ROAS` = 6.540536.
     - `MART_LEAD_QUALITY` B2 = `01-10`, left-aligned text, not a date.
     - `MART_MONTHLY_MARKETING` A2 = `2023-01-01`: a date. With the cell selected, **Format » Number** shows a date format ticked.
     - `MART_CONVERSION_FUNNEL` E2 (`PREV_STAGE_VALUE` of the first stage) is empty. That is a NULL, as in Snowflake.
   - [ ] **Two column totals.** In `MART_CHANNEL_PERFORMANCE`, select D2:D6. The sum at the bottom right
         reads **Sum: 4523050.02** (total spend). K2:K6 reads **Sum: 21561839.01** (attributed
         revenue). The cells are formatted `0.00`, without thousands separators, so the sum is
         probably shown the same way; `4,523,050.02` and `21,561,839.01` are the same values and
         also match.
   - [ ] **The attribution note.** Hover over A1 of any table tab: a note shows the attribution.
     - If the notes were lost in the conversion, right-click A1, choose **Insert note** and paste
       the attribution from [Step 8](#step-8-provenance-note-and-attribution).
     - Never type the attribution into a cell. Every cell of a table tab is read as data.
5. **Do not edit the table tabs.** No sorting, filters, formulas, extra rows or columns, and no
   format changes: Data Studio reads each tab as a whole table.
6. **Leave the file's sharing at Restricted.** With Owner's credentials (step 4), report viewers see
   the charts without access to the file.

#### Last row of each tab

| Tab | Rows | Last row |
|---|---:|---:|
| `MART_CHANNEL_PERFORMANCE` | 5 | 6 |
| `MART_CAMPAIGN_PERFORMANCE` | 120 | 121 |
| `MART_MONTHLY_MARKETING` | 180 | 181 |
| `MART_MONTHLY_COHORT` | 180 | 181 |
| `MART_CONVERSION_FUNNEL` | 25 | 26 |
| `MART_LEAD_QUALITY` | 50 | 51 |
| `FCT_CAMPAIGN_DAILY_ACTIVITY` | 13,760 | 13,761 |
| `DIM_CAMPAIGN` | 120 | 121 |

## Step 4. Create one reusable data source per report table (7 of them)

Repeat for each of the 7 tabs that the live report uses: `MART_CHANNEL_PERFORMANCE`,
`MART_CAMPAIGN_PERFORMANCE`, `MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT`,
`MART_CONVERSION_FUNNEL`, `MART_LEAD_QUALITY` and `FCT_CAMPAIGN_DAILY_ACTIVITY`
([dashboard_spec.md](dashboard_spec.md#decisions-this-spec-makes), D1).

- Skip the `DIM_CAMPAIGN` tab. It is in the workbook for completeness, but no chart uses it (the
  campaign drop-downs read `CAMPAIGN_NAME` from `MART_CAMPAIGN_PERFORMANCE`), so the copy dialog of
  step 5 would never ask for it.
- The `README` tab gets no data source either.

1. Open https://datastudio.google.com and click **Create » Data source** on the home page.
   - Always start from the home page. A data source created this way is **reusable**. One added
     from inside a report is **embedded**, and Google makes embedded sources accessible to anyone
     with the report link.
2. Choose the **Google Sheets** connector (the one built by Google).
3. Under **Spreadsheet**, pick the converted file from step 3 (not the `.xlsx`). Under **Worksheet**, pick the table tab.
4. Options:
   - **Use first row as headers:** ticked.
   - **Include hidden and filtered cells:** ticked (the default).
   - **Optional Range:** empty.
5. Click **CONNECT** (top right). The fields panel opens.
6. **Data credentials** (top of the fields panel): **Owner's credentials**.
7. **Field types: copy them from the live source, field by field.** Open the matching live
   Snowflake data source in another tab (**Resource » Manage added data sources » EDIT** in the
   live report, or the **Data sources** tab of the home page). For every field, set the same
   **Type** and the same **Default aggregation** as there. The live sources follow
   [dashboard_spec.md](dashboard_spec.md) section 0.4.
   - Field names must be the column names exactly. Do not rename.
   - The Sheets connector guesses types from the cells, so several fields need a change. **These
     differences from the cells are deliberate**; do not "correct" them back:

     | Data source | Field | Type | Default aggregation | Why (spec) |
     |---|---|---|---|---|
     | `MART_MONTHLY_MARKETING` | `MONTH_START` | **Date (YYYYMMDD)**, not *Year Month* | | The only date field: the date range dimension (D2) |
     | `MART_MONTHLY_COHORT` | `COHORT_MONTH` | **Date (YYYYMMDD)** | | The only date field (D2) |
     | `FCT_CAMPAIGN_DAILY_ACTIVITY` | `ACTIVITY_DATE` | **Date (YYYYMMDD)** | | The only date field |
     | `FCT_CAMPAIGN_DAILY_ACTIVITY` | `ACTIVITY_MONTH` | **Text** | | Leaves one date field (D3) |
     | `FCT_CAMPAIGN_DAILY_ACTIVITY` | `IS_IN_FLIGHT` | Number | **None** (a green dimension) | The card filters test it per row (0.4) |
     | `FCT_CAMPAIGN_DAILY_ACTIVITY` | `CAMPAIGN_ID` | Text | | Counted with *Count Distinct* by the cards |
     | `MART_CAMPAIGN_PERFORMANCE` | `START_DATE`, `END_DATE`, `START_MONTH`, `START_YEAR` | **Text** | | No date field, so the date control never filters campaigns (D3) |
     | `MART_CHANNEL_PERFORMANCE` | `CTR`, `CLICK_TO_LEAD_RATE`, `LEAD_CONVERSION_RATE`, `PURCHASE_RATE`, `BUDGET_UTILIZATION`, `SPEND_SHARE`, `LEADS_SHARE`, `REVENUE_SHARE`, `LCR_CI_LOW`, `LCR_CI_HIGH` | **Percent** | Sum | Stored ratios; the CI bounds and shares are charted (D9) |
     | `MART_CAMPAIGN_PERFORMANCE` | `CTR`, `CLICK_TO_LEAD_RATE`, `LEAD_CONVERSION_RATE`, `PURCHASE_RATE`, `BUDGET_UTILIZATION` | **Percent** | Sum | Stored ratios (0.4) |
     | `MART_LEAD_QUALITY` | `SCORE_BAND_MIN`, `SCORE_BAND_MAX` | Number | **Min** | Sort keys |
     | `MART_LEAD_QUALITY` | `SCORE_BAND` | **Text** | | `01-10` ... `91-100` |
     | `MART_CONVERSION_FUNNEL` | `STAGE_ORDER` | Number | **Min** | The funnel's sort key |
     | all seven | `CHANNEL` | **Text** | | The channel filter needs one type everywhere |

   - Every other field: the type the live source shows (Text for names and codes, Number for
     counts, money and the remaining ratios), with default aggregation **Sum** for numbers.
   - Check as in spec 0.6: `MART_CAMPAIGN_PERFORMANCE` and `MART_CHANNEL_PERFORMANCE` show no
     field with a calendar icon, and `MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT` and
     `FCT_CAMPAIGN_DAILY_ACTIVITY` exactly one each. A wrong type here moves numbers later: a
     `START_DATE` left as Date lets the date control filter the campaign tables (P1-11 would show
     50 campaigns in 2024 instead of 120), and a ratio left as Number shows `0.149888` instead
     of `14.99%` (affiliate's `LCR_CI_LOW` in P2-08).
   - Copy the **descriptions** from the live source too, if you added any.
8. **Calculated fields.** Add the calculated fields of the matching live Snowflake data source
   (the **fx** fields), and no others:
   1. Click **ADD A FIELD » Add calculated field**.
   2. Use the same **Field Name**, the same **Formula** and the same **Type**, and click **SAVE**.
   3. **Keep the names identical.** When a data source is replaced, Data Studio matches the
      report's fields to the new source by field ID and name (Google's replace-data-source
      documentation). A calculated field with another name is not found.

   The list below is [dashboard_spec.md](dashboard_spec.md) section 0.5: 22 fields in all. The
   formulas are in that table.
9. **Name the data source.** Click its name at the top left (by default *spreadsheet name -
   worksheet*) and rename it `<TABLE> (Sheets snapshot)`, for example
   `MART_CHANNEL_PERFORMANCE (Sheets snapshot)`. The data source saves itself; close the tab.

| Sheets data source | Calculated fields (spec 0.5) |
|---|---|
| `MART_MONTHLY_COHORT` | *Lead conversion rate*, *Mean days to convert*, *Cross-month share* |
| `MART_CHANNEL_PERFORMANCE` | *Click-through rate*, *Click-to-lead rate*, *Lead conversion rate*, *Cost per lead*, *Cost per conversion*, *Cost per purchase*, *ROAS (attributed)*, *Budget utilisation* |
| `MART_CAMPAIGN_PERFORMANCE` | *Lead conversion rate*, *Cost per lead*, *Cost per purchase*, *ROAS (attributed)*, *Budget utilisation* |
| `MART_LEAD_QUALITY` | *Lead conversion rate*, *Purchase rate*, *Average lead score*, *Mean days to convert* |
| `MART_CONVERSION_FUNNEL` | *Stage conversion*, *Share of top of funnel* |
| `MART_MONTHLY_MARKETING`, `FCT_CAMPAIGN_DAILY_ACTIVITY` | none |

## Step 5. Copy the report onto the Sheets data sources

Copying is the recommended route. One dialog re-points every chart at once. The live report
stays untouched as the reference for step 7 and as a fallback while the trial lasts.

1. Open the live report in **View** mode.
2. Top right: **⋮ (More options) » Make a copy**.
3. The dialog lists the report's data sources on the left. For each one, pick the matching
   `<TABLE> (Sheets snapshot)` source on the right. Leave no Snowflake source selected.
4. Click **CREATE REPORT**.
5. Rename the copy (click its title): `Marketing CRM & Conversion Funnel Analytics Report`. In
   Drive, the live one can be renamed `... (live Snowflake, build only)` so the two are never
   confused.
6. In the copy, choose **Resource » Manage added data sources**. It must list the 7 Sheets sources
   of step 4, each **Reusable**, and no Snowflake source. `DIM_CAMPAIGN` is not among them: the
   report does not use it.
   - If a Snowflake source is still listed, some component still uses it: fix it in step 6, then
     click **REMOVE** next to the Snowflake source.
7. **Check, and only if needed unify, the `CHANNEL` field IDs.** Google lists Google Sheets as a
   flexible-schema connector, whose data sources may not share field IDs; then one channel
   drop-down does not filter the other Sheets sources until the IDs are unified
   ([about controls](https://docs.cloud.google.com/data-studio/about-controls)).
   - **Result in the built copy (2026-10-18): not needed.** The Sheets sources gave `CHANNEL` the
     same ID in all seven (the IDs look derived from the column name, e.g. `LEADS` =
     `_72307831_`), and gate G2 passed without any override (record in
     [dashboard_validation.md](dashboard_validation.md#g2-one-channel-control-across-the-seven-sources)).
     The overrides below are the fallback if G2 fails.
   - In the copy: **Resource » Manage field names and IDs » Add field override**. Pick `CHANNEL`
     of one Sheets source, leave **New display name** empty, set **New ID** to `channel`. Repeat
     for `CHANNEL` of all 7 Sheets sources: the same ID, all Text (as spec 1.4).
   - Add any other override the live report lists under **Resource » Manage field names and IDs**
     the same way.
   - Do this before step 6. Changing a field ID that charts already use breaks those charts until
     the field is selected again, so reselecting afterwards fixes them in one pass.
   - **Re-run gate G2 on the copy** after step 6. Select **video** in the channel drop-down and
     check one component per source: P1-01 (`DAILY`) 24, P1-05 (`MM`) 25,799, P1-07 (`COH`)
     15.24%, P1-11 summary row (`CAMP`) leads 25,799, P2-03 (`CH`) 15.24%, P2-06 (`FUN`) leads
     25,799, P3-01 (`LQ`) 25,799. Record the result in the Pass 2 column of the sign-off in
     [dashboard_validation.md](dashboard_validation.md). If some stay at the all-channel value,
     use the page-level fallback of spec 1.5.

**What the copy did in practice (2026-10-18).** The dialog mapped the seven sources correctly, but
the Snowflake and Sheets connectors give fields different IDs, so Data Studio re-picked the fields
of many charts on its own: wrong metrics (for example the sum of the stored `CTR` column, 9.28%,
on P2-01), swapped dimensions, `CAMPAIGN_ID` instead of `CAMPAIGN_NAME`, every per-chart name
lost, card formats reset to `Default`, and the two `DAILY` filters invalid. Every component had to
be set back by hand against the final report (step 6); the full list is in the pass-2 build log
of [dashboard_validation.md](dashboard_validation.md#build-log-pass-2-the-google-sheets-copy).
Budget an afternoon for step 6.

The alternative is to re-point each component of the live report in place: select it, then
**Setup » Data source**, click the current source and pick the Sheets one. That works too, but it
loses the side-by-side reference and is slower.

## Step 6. Repair what the swap does not map

Google maps fields by ID and name. It does **not** re-map the fields used in calculated fields
and filters, and a component with an unmatched field shows **Chart configuration incomplete**. Go
through every page of the copy in **Edit** mode, with the live report open next to it:

1. **Broken charts.** For each chart that shows an error or a missing field: select it and re-select
   the missing dimension, metric, sort field or **Date range dimension** in **Setup**, as in the
   live report.
2. **Chart-level calculated fields.** These are metrics created inside a chart with **Add metric »
   Create field**. Re-create them with the same name and formula. Fields created in the data
   source (step 4) are already there.
3. **Filters.** Open **Resource » Manage filters**. Open each filter, re-select its field, and save.
   Then check:
   - every chart's **Setup » Filter**;
   - **Page » Current page settings** (filters and data source);
   - **File » Report settings** (filters and data source).
4. **Controls.** Check each control's **Setup » Data source** and **Control field**:
   - the date range control;
   - the channel and campaign drop-downs;
   - any other control.

   The date range control's default must still be the fixed range 2023-01-01 to 2025-12-31
   (decision 9).
5. **Date range dimensions.** In every chart's **Setup**, the **Date range dimension** must be
   the same field as in the live report:
   - charts on `MART_MONTHLY_MARKETING`: `MONTH_START`;
   - charts on `MART_MONTHLY_COHORT`: `COHORT_MONTH`;
   - charts on `FCT_CAMPAIGN_DAILY_ACTIVITY`: `ACTIVITY_DATE`, never `ACTIVITY_MONTH`;
   - charts on `MART_CAMPAIGN_PERFORMANCE`, `MART_CHANNEL_PERFORMANCE`, `MART_LEAD_QUALITY` and
     `MART_CONVERSION_FUNNEL`: **none**. These sources have no date field after step 4 (spec D3).
     If such a chart shows a date range dimension, a date column is still typed **Date**: fix its
     type in the data source (step 4, item 7), never pick a date here.
6. **Re-pointing one component.** To move a single component to another source: select it, then
   **Setup » Data source**, click the current source name and choose the Sheets source.

## Step 7. Verify every number

1. **With the default view.** Work through [dashboard_validation.md](dashboard_validation.md) on
   the copy: the fixed date range and no filter first, then every filter case it lists. Each value
   must equal the expected value. These are the same numbers the live report showed and that the
   Snowflake SQL computed.
2. **Side by side, while Snowflake is still up.** Set the same filters in the live report and the
   copy and compare a few charts on every page.
3. **If a value differs**, the cause is almost always one of these:
   - a field mapped to the wrong column;
   - a calculated field missing or typed differently;
   - a lost filter;
   - a wrong **Date range dimension**.

   Fix it and check that row again. The data itself is proven equal: `make export-check`
   compares the exported files with the live tables.

## Step 8. Provenance note and attribution

Both go into the report-level header that the live report already has
([dashboard_spec.md](dashboard_spec.md) sections 1.3 and 9). Work in the copy, in **Edit** mode.

1. **Add the snapshot note.** On page 1, choose **Insert » Text** and place the box in the gap
   between the date range control and the Channel drop-down (the two controls are stacked at the
   top right of the header), as wide as the space from the end of the provenance line to the
   controls' right edge. Paste this text, filling in the export date from step 1:

   > Snapshot: Snowflake MART tables exported on <EXPORT DATE, e.g. 2026-10-14> and served from
   > Google Sheets; figures are fixed at that export.

   The wording is true both while the trial runs and after it ends. It carries no repository
   link while the repository is not public; add one once it is.

   Then select the box and choose **Arrange » Make report-level** (or right-click » **Make
   report-level**), so it shows on every page.
   - **Format after making it report-level.** Making the box report-level reset its text
     formatting to the default 14 px in the built copy (2026-10-18). So set the format last, with
     the box selected but not in text-editing mode: 10 px, colour `#5F6368`, right-aligned (the
     two lines end at the controls' right edge), top padding 0 px so the two lines sit centred
     between the controls without touching either.
2. **Keep the provenance line.** The header's line `KPIs computed in Snowflake SQL / dbt
   (MARKETING_CRM.MART); data synthetic; revenue last-touch attributed` stays as it is. Together
   with the snapshot note it carries decision 8's provenance note.
3. **Check the attribution line in the report-level header** (spec 1.3). It is already there,
   copied from the live report, under the title. Do not add a second one. Its text must be exactly:

   > Data: Analytics Engineering, "Marketing Campaigns & Conversions Dataset v1.0.0"
   > (https://www.analyticsengineering.com/datasets/marketing-campaigns), CC BY 4.0
   > (https://creativecommons.org/licenses/by/4.0/). Typed, cleaned and aggregated by Hoedong Kim;
   > not endorsed by the publisher.

   Only if it is missing, add it as in spec 1.3 (x 24, y 74, w 760, h 40; 10 px) and make it
   report-level.
4. **Check every page.** Open each of the four pages in **View** mode: the title, the provenance
   line, the attribution and the snapshot note must show, and none may cover a control or chart.

## Step 9. Share the Sheets version, retire the live one

1. **Share the copy.** Use the same link settings as the live report in Phase 1: **Anyone with the
   link can view**, never an edit option.
2. **Test it signed out.** Open the link in an incognito window: every page must render without
   signing in.
3. **Update the links.** Point every link to the dashboard (README, portfolio, CV) at the copy.
4. **Keep the live report as a record.** Restrict it to yourself until the trial ends; after that
   its charts fail. Keep it or delete it. The repository holds everything needed to rebuild it.
5. **After the trial, check the files offline:**

   ```bash
   make export-check EXPORT_CHECK_ARGS=--offline
   ```

## When the MART tables change later

The snapshot must equal the tables it claims to show. After any dbt run that changes data:

1. Rerun step 1. If `make export-check` fails on the live checksums before the re-export, that
   is the change being detected.
2. Upload and convert the new workbook (steps 2-3) as a new Google Sheets file.
3. Point each of the 7 data sources at the new file. On the data source page, click **EDIT
   CONNECTION**, pick the new spreadsheet and the same worksheet name, and click **RECONNECT**.
   Accept the field changes only if none is listed as removed.
4. Repeat step 7 and update the export time in the provenance note.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| The spreadsheet does not appear in the connector's list | It is on a shared drive, still an `.xlsx` (the **.XLSX** badge), or owned by another account. Move it to My Drive or convert it (step 3), signed in with the owner account. |
| `SCORE_BAND` shows dates such as Jan 10 | A CSV was imported instead of the workbook. Start again from the `.xlsx` (step 2). |
| `MONTH_START`, `COHORT_MONTH` or `ACTIVITY_DATE` is typed **Text** in the data source | Change its **Type** to **Date & Time » Date** (step 4). Only these three are dates: `START_DATE`, `END_DATE`, `START_MONTH`, `START_YEAR` and `ACTIVITY_MONTH` stay **Text** on purpose. |
| **Chart configuration incomplete** | A field, sort or date range dimension was not mapped: step 6, item 1. |
| A ratio differs in the last digit from the expected value | Check that the calculated field formula matches exactly, and that the number format in **Style** has as many decimals as [dashboard_validation.md](dashboard_validation.md) shows. The cells hold the exact values. |
| `make export-marts` fails with "differ from a second query" | A dbt run rebuilt a table during the export. Run it again when dbt is done. |
| `make export-check` fails on live checksums | A table changed after the export: re-export ([When the MART tables change later](#when-the-mart-tables-change-later)). |
| `make export-check` cannot connect after mid-November | The trial has ended. Use `make export-check EXPORT_CHECK_ARGS=--offline`. |
