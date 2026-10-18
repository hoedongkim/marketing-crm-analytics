# Phase 1: early Google Data Studio connection test

**Goal:** prove on day 1, before any modelling, that Google Data Studio (formerly Looker Studio;
Google renamed it in April 2026) can read `MARKETING_CRM.MART` through the Snowflake connector
with the key-pair service user. If key-pair fails, the trial-only fallback is decided now rather
than in Phase 6.

**Status:** core test run on 2026-10-13: the connector signed in with the key-pair service user and a first
chart read `MART.CONNECTION_TEST`. The pushdown, public-link and durability checks (sections D-F) are
deferred to Phase 6, when the real MART tables exist. Results are in the table at the end.
**Before committing a screenshot, redact the account URL / account identifier** (and any key material):
the repository is public, and the account URL plus the documented user names would be a ready-made
login target. Record the *format* that worked, never the real value.

Background, checked 2026-10-13:

- **The connector.** Snowflake publishes the "Snowflake Connector for Google Looker Studio". Its docs still use the old product name. It is an Apps Script partner (community) connector.
- **Authentication.** It supports username + password and key-pair, and **does not support encrypted private keys**. It is not compatible with interactive MFA.
- **Queries.** One SQL statement per data source: `SELECT`, `SHOW` or `DESCRIBE` only, with **no trailing semicolon** and no table picker.
- **Limits.** Google caps a result at **1,000,000 rows / 50 MB**.
- **Filters.** They are pushed down to Snowflake, **except on DATE/TIME/TIMESTAMP columns**: a date-range change pulls the unfiltered result set.
- **Known risk.** A Google developer-forum thread (Dec 2025) reports that pasting a private key into the password field worked only intermittently (`JWT_TOKEN_INAVLID_EXPIRATION_TIME`, sic). Neither Snowflake nor Google documents whether the pasted key should keep its BEGIN/END lines.

## Prerequisites

- [ ] `make load` passed (RAW reconciled)
- [ ] `make connection-test-table` exited 0 and its last printed result reads `159 | 4523050.02 | 436844819 | 7102319 | 2023-01-01 | 2025-12-01 | PASS` (the check row turns FAIL, and the command exits 1, on any mismatch)
- [ ] `make sf-check-bi` passed: SVC_CRM_BI with CRM_REPORTER sees MART and cannot read RAW
- [ ] `svc_crm_bi.p8` is **unencrypted** (first line `-----BEGIN PRIVATE KEY-----`)

## Checklist

### A. Google account

- [ ] Use a **personal Gmail account**, not LionMail / any Workspace account, to own the report, the data sources and later the Google Sheets snapshot. Three reasons:
  - A Workspace admin can block sharing outside the organisation, or block Apps Script community connectors.
  - A university account is deprovisioned after graduation, and the dashboard would die with it.
  - Ownership transfers have been reported to break extracts (a 2024 Google forum thread; Google does not document it).
- [ ] Never transfer ownership of the report or its data sources later.

### B. Create the data source

1. [ ] Open https://datastudio.google.com and choose **Create » Data source** from the home page. A data source created this way is **reusable**; one created from inside a report (*Add data* with a connector) is **embedded**, and Google states that embedded data sources become accessible to anyone with the report link. This project uses reusable data sources only.
2. [ ] Search "Snowflake". Pick the **card with the Snowflake logo** (the one Snowflake's docs describe) and confirm that its publisher label shows Snowflake; record the label in the results table. Do not pick "Snowflake by Supermetrics" or "Snowflake by Windsor.ai": those are paid third-party connectors. Authorise it when asked.
3. [ ] Sign-in fields:
   - **Username:** `SVC_CRM_BI`
   - **Password or private key:** the contents of `svc_crm_bi.p8`
   - Do not paste it anywhere else, and clear the clipboard afterwards (`pbcopy < /dev/null`).
   - **Use the base64 body only** (BEGIN/END lines and newlines removed): `grep -v -- '-----' "$HOME/.snowflake/keys/svc_crm_bi.p8" | tr -d '\n' | pbcopy`. This is what worked on 2026-10-13; the full PEM was rejected as a wrong password.
4. [ ] Connection fields:
   - **Account URL.** Try in this order and record which works:
     1. `<orgname>-<account>.snowflakecomputing.com`
     2. `https://<orgname>-<account>.snowflakecomputing.com`
     3. the account-locator URL shown under Snowsight » account menu » View account details
   - **Role:** `CRM_REPORTER`
   - **Warehouse:** `MARKETING_WH`
   - **Database:** `MARKETING_CRM`
   - **Schema:** `MART`
   - **SQL query:** `SELECT * FROM MARKETING_CRM.MART.CONNECTION_TEST` (no trailing semicolon)
5. [ ] Click **Connect**.
6. [ ] Data credentials: **Owner's credentials**. This is required for a public report, and all viewers share one cache.
7. [ ] Check the field types:
   - `SPEND_MONTH` is a Date (YEAR_MONTH_DAY)
   - `CHANNEL` is Text
   - `SPEND`, `IMPRESSIONS` and `CLICKS` are Numbers
8. [ ] Data freshness: note which options the connector offers (Google documents community connectors as "varies"). Pick the longest.

### C. Build a throwaway report

- [ ] Create the report **from the reusable data source**: on the data source page, click **Create report**. If you start from a blank report instead, attach the source with **Add data » My data sources**. Never pick the Snowflake connector inside a report: that creates an embedded copy.
- [ ] Scorecard: SUM(SPEND). It must show 4,523,050.02.
- [ ] Time series: SPEND by SPEND_MONTH, 2023-01 to 2025-12.
- [ ] Table: CHANNEL × SUM(SPEND), SUM(CLICKS). Totals must equal the RAW totals (clicks 7,102,319).
- [ ] Drop-down filter control on CHANNEL. Change it a few times; then change the date range a few times.
- [ ] Set a fixed custom default date range of 2023-01-01 to 2025-12-31. Relative ranges such as "last 28 days" are empty: the data ends in December 2025.

### D. What Snowflake saw (as the admin in Snowsight)

```sql
-- ACCOUNTADMIN sees every user's queries; MARKETING_WH runs the table functions.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE MARKETING_WH;

-- Wrapped queries sent by the connector (INFORMATION_SCHEMA covers the last 7 days).
SELECT START_TIME, EXECUTION_STATUS, TOTAL_ELAPSED_TIME, ROLE_NAME, WAREHOUSE_NAME,
       QUERY_TAG, LEFT(QUERY_TEXT, 300) AS QUERY_TEXT
FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
       USER_NAME => 'SVC_CRM_BI', RESULT_LIMIT => 200))
ORDER BY START_TIME DESC;

-- Credits used by the warehouse in the last day. Needs ACCOUNTADMIN or MONITOR USAGE.
SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(
  DATEADD('DAY', -1, CURRENT_TIMESTAMP()), CURRENT_TIMESTAMP(), 'MARKETING_WH'));
```

- [ ] The connector's wrapped `SELECT` queries are visible. Note how the SQL is wrapped.
- [ ] The CHANNEL filter appears in the SQL (pushdown). The date filter does not; it is documented as not pushed down.
- [ ] Repeating an identical view creates no new query, or a result-cache reuse.
- [ ] Metered credits for the test are a small fraction of one credit.
- [ ] `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` / `WAREHOUSE_METERING_HISTORY` keep longer history, with ingest latency. Use them for evidence captured later.

### E. Public link

Before the link is made public:

- [ ] **Resource » Manage added data sources** lists every source with type **Reusable**, none **Embedded**. Fix an embedded one first (*Make reusable* in the same dialog, or rebuild the chart on the reusable source).
- [ ] **Attribution text box** on every page, in a header or footer (the Phase 6 dashboard puts it in a report-level header, [dashboard_spec.md](dashboard_spec.md) section 1.3), as CC BY 4.0 requires for shared adaptations: *Data: Analytics Engineering, "Marketing Campaigns & Conversions Dataset v1.0.0" (https://www.analyticsengineering.com/datasets/marketing-campaigns), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Typed, cleaned and aggregated by Hoedong Kim; not endorsed by the publisher.*

Then:

- [ ] Share » Manage access » link setting **"Anyone with the link can view"**. Never choose an "edit" option.
- [ ] Open the link in an incognito window. The charts must render without signing in.
- [ ] Optional: File » Embed report » Enable embedding. Test the iframe in a local HTML file.

### F. Durability rehearsal (the Snowflake trial will end)

The plan is to serve the final public dashboard from a frozen Google Sheets snapshot of the final MART tables, with a provenance note. A suspended trial account cannot answer queries, so live charts break once their cache expires. Rehearse the swap now:

- [ ] Export CONNECTION_TEST to a Google Sheet in **My Drive**, not a shared drive: one worksheet, same UPPERCASE column names. Use the Snowsight result download (CSV), then import. Put the attribution text from section E in a note or a header cell outside the data range.
- [ ] Add a Google Sheets data source (**Create » Data source**, so it is reusable too) and swap **one** chart to it (chart » Data source). Calculated fields and filters are not remapped by the swap; redo them.
- [ ] The chart shows identical numbers.
- [ ] Optional: create an Extract Data source on the Snowflake source and note whether it keeps serving while `SVC_CRM_BI` is disabled. Google does not document this.
  - Disable as admin: `ALTER USER SVC_CRM_BI SET DISABLED = TRUE;`
  - Re-enable it afterwards: `ALTER USER SVC_CRM_BI SET DISABLED = FALSE;`

## Fallback if key-pair fails (trial-only)

Use this only if key-pair fails with both key formats and all Account URL variants, or proves flaky over several refreshes.

- **Why a password user is possible here.** Snowflake's single-factor password deprecation explicitly does not apply to trial accounts. `TYPE = SERVICE` users cannot have passwords at all, so the fallback needs a separate user.
- **What to try.**
  1. Try `TYPE = LEGACY_SERVICE` first. It is being phased out and may be refused.
  2. If it is refused, use `TYPE = PERSON` without MFA, because the connector cannot do interactive MFA.
- **Handling.**
  - Generate a long random password locally (e.g. `openssl rand -base64 32`) and type it yourself.
  - **Never commit it.** Keep it out of `.env`, the repo, screenshots and chat logs.
  - **A Snowsight worksheet is a saved file.** Snowsight autosaves worksheet edits every three seconds and stores a new version every time a worksheet is run, so the password literal stays in the worksheet and its history. Query history may also keep the statement text: Snowflake's docs do not say whether `PASSWORD` literals are redacted there **(unverified)**. Therefore:
    1. Run the statement below in a **new, dedicated worksheet**, used for nothing else and never shared.
    2. As soon as it succeeds, **delete the whole worksheet** (not just the line).
    3. Treat the password as exposed to anyone who can read this account's query history, and drop the user (cleanup below) as soon as it is no longer needed.
  - Do not attach a network policy: Google calls come from ephemeral IPs.
- **Limits.** Mark the user as trial-only. It stops working if the account is converted to paid, because the deprecation phases then apply.
- **Cleanup (required, not optional).** Drop the user when the test is over, or at the latest when the Sheets snapshot takes over: `USE ROLE USERADMIN; DROP USER IF EXISTS SVC_CRM_BI_PW;`. Record the date in the results table.

```sql
-- TRIAL-ONLY FALLBACK. Run as the admin in a NEW, dedicated Snowsight worksheet, then delete
-- that worksheet. Never put the password in a file.
USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS SVC_CRM_BI_PW
  TYPE = LEGACY_SERVICE               -- if refused: TYPE = PERSON (and no MFA enrolment)
  PASSWORD = '<type a long random password here, in Snowsight only>'
  DEFAULT_ROLE = CRM_REPORTER
  DEFAULT_WAREHOUSE = MARKETING_WH
  DEFAULT_NAMESPACE = MARKETING_CRM.MART
  DEFAULT_SECONDARY_ROLES = ()
  COMMENT = 'TRIAL-ONLY password fallback for the Data Studio test. Drop after Phase 1 / before converting to paid.';
GRANT ROLE CRM_REPORTER TO USER SVC_CRM_BI_PW;
-- REQUIRED cleanup later (see above): DROP USER IF EXISTS SVC_CRM_BI_PW;
```

A programmatic access token is not a practical fallback here. The connector does not document PAT
support at all, and PATs for SERVICE users need a network policy unless an authentication policy
relaxes that requirement; Google's IPs are ephemeral, so a network policy cannot list them.

## Results (fill in; do not invent)

| # | Check | Result (PASS / FAIL / note) | Date | Evidence (screenshot / query ID) |
|---|---|---|---|---|
| 1 | Connector found (publisher label as shown on the card) and authorised | PASS (label not recorded) | 2026-10-13 | |
| 2 | Key-pair sign-in with full PEM (BEGIN/END lines kept) | FAIL: `Incorrect username or password was specified` (the connector treated the PEM as a password) | 2026-10-13 | connector error dialog |
| 3 | Key-pair sign-in with base64 body only | **PASS**: BEGIN/END lines removed, newlines removed (`grep -v -- '-----' svc_crm_bi.p8 \| tr -d '\n'`) | 2026-10-13 | |
| 4 | Account URL format that worked (the format only, e.g. `<org>-<account>.snowflakecomputing.com`, no `https://`; never the real value) | `<org>-<account>.snowflakecomputing.com`. With a scheme the connector refuses: `Account URL should not start with 'https://' or 'http://'` | 2026-10-13 | |
| 5 | Field types (Date / Text / Number) correct | PASS (reported by the user) | 2026-10-13 | |
| 6 | Data freshness options offered | | | |
| 7 | Scorecard SUM(SPEND) = 4,523,050.02 | PASS (reported by the user) | 2026-10-13 | |
| 8 | CHANNEL filter pushed down (visible in QUERY_HISTORY) | PASS: e.g. `... FROM (SELECT * FROM MARKETING_CRM.MART.MART_LEAD_QUALITY) WHERE (IDENTIFIER('"CHANNEL"') IN (?, ?, ?, ?, ?)) AND (IDENTIFIER('"LEAD_SCORE_SEGMENT"') IN (?, ?, ?))`; 148 of 1,540 connector queries carried a WHERE (bind parameters, values not logged) | 2026-10-17 | SVC_CRM_BI query history |
| 9 | Date filter not pushed down (as documented) | PASS: queries on `MART_MONTHLY_MARKETING` select `MONTH_START` and the metrics with no WHERE, so the date range is applied in Data Studio | 2026-10-17 | SVC_CRM_BI query history |
| 10 | Repeated view served from cache / result cache | | | |
| 11 | Credits used by the test (WAREHOUSE_METERING_HISTORY) | | | |
| 12 | Public link renders in incognito | | | |
| 13 | Google Sheets swap of one chart shows identical numbers | | | |
| 14 | Extract Data behaviour with SVC_CRM_BI disabled (optional) | | | |
| 15 | Key-pair stable over several refreshes / days | | | |
| 16 | Fallback needed? Which user type was accepted? | No: key-pair works | 2026-10-13 | |
| 17 | All data sources reusable (Resource » Manage added data sources) | | | |
| 18 | Attribution text box (header or footer) on every public page, and the note in the Sheet | | | |
| 19 | Fallback user `SVC_CRM_BI_PW` dropped (date), or never created | Never created | 2026-10-13 | |
