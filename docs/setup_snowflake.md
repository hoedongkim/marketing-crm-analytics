# Snowflake setup: Day-1 runbook (Phase 1)

This runbook takes the project from "new Snowflake trial account" to "RAW loaded and reconciled,
MART connection-test table ready for Data Studio". Every SQL statement and command it refers to is
in this repository. The account was created on 2026-10-13; as of that date none of the tooling has
been run against it yet. The first run is the real test, so the troubleshooting section at the end
matters.

Facts below were checked against docs.snowflake.com and Google's Data Studio docs on 2026-10-13.
Claims that could not be verified are marked **(unverified)**.

## Who does what

| Step | Who | Why |
|---|---|---|
| Sign up, choose cloud/region/edition, set the admin password, enrol MFA | **You** | Account creation and passwords are personal; no script or assistant should handle them. |
| `make setup`, `make data`, `make keys`, `make bootstrap-sql` | You (or an assistant) on your laptop | Local only, no Snowflake access needed. Exception: with `ENCRYPT_PIPELINE_KEY=1`, **you** run `make keys` and type the passphrase (see the note below). |
| Paste `build/snowflake_bootstrap.sql` into Snowsight and **Run All**, then step 5b | **You**, as the admin user | Needs ACCOUNTADMIN. This is the only time the *tooling* needs an admin role; later admin use is for monitoring and break-glass only (raising a monitor quota, the Data Studio test queries, disabling a user). |
| Fill `.env`, `make sf-check`, `make load`, `make load-challenge`, `make connection-test-table` | You (or an assistant) | Uses the key-pair service user. No password; the optional key passphrase is entered by you only. |
| Authorise the Data Studio connector, paste the BI key | **You** | Google-account consent and a credential paste. |

**The key passphrase is yours alone.** If you choose `ENCRYPT_PIPELINE_KEY=1`, you run `make keys`
and type the passphrase at the openssl prompt, and you write `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` into
`.env` yourself. An assistant must never see, type or store it. With the default (unencrypted
pipeline key) there is no secret to type at all; the `.p8` files themselves are still secrets.

## 0. Sign-up decisions (made 2026-10-13)

The account for this project was created on 2026-10-13:

| Decision | Choice | Consequence |
|---|---|---|
| Sign-up flow | Default page (https://signup.snowflake.com/): 30-day trial with $400 of usage | The trial ends about **2026-11-12**, or earlier if the $400 runs out. The Google Sheets snapshot of the dashboard data is due by about **2026-11-07**, so Phases 2-6 must be finished before then. Phase 7 (documentation) can come after. |
| Cloud / region | AWS US East 2 (Ohio), `CURRENT_REGION()` = `AWS_US_EAST_2` | Nothing in this project depends on the region. Credit prices are quoted for "AWS US East" in general. |
| Edition | **Not confirmed yet.** If your user has ORGADMIN, `USE ROLE ORGADMIN; SHOW ACCOUNTS;` lists it in the `edition` column; otherwise check the welcome email. | The bootstrap is written for both Standard and Enterprise. Record the edition in the trial record below. |

- **Confirm the end date** in Snowsight (trial banner / billing page) and record it below. The snapshot deadline is based on it.
- **MFA on your admin user.** Enrol a passkey or a TOTP authenticator app; Duo is not available on trial accounts.
  - Trial accounts are exempt from Snowflake's single-factor-password deprecation, but a trial converted to paid gets an MFA-required policy.
  - The service users this project creates never use passwords, so they are unaffected either way.

**If you reproduce this project with a new account:**

- A student flow, https://signup.snowflake.com/?trial=student, advertises a *"120-day free Snowflake trial which includes $400 worth of free usage"*. Whether 120 days are actually granted is **(unverified)**; the trial docs say 30 days. Either way the trial ends at the end date **or** when the $400 runs out, whichever comes first.
- Pick the region closest to you; any cloud works with this tooling.
- **Edition: Standard, if the form offers it.** The $400 then buys more credits (about 200 at ~$2/credit, against about 133 at ~$3/credit for Enterprise; third-party list prices, **unverified**). Enterprise also works: the bootstrap turns Query Acceleration off explicitly.
  - What Standard lacks: column-level security (dynamic masking, external tokenisation), row access policies, multi-cluster warehouses, Time Travel beyond 1 day and the Query Acceleration Service.
  - Nothing in this project needs those. The data is synthetic with no PII, and an X-Small single-cluster warehouse is plenty.
- Edition, cloud and region can most likely **not be changed later** on a trial account. Third-party guides say so; Snowflake's docs do not confirm it.

## 1. Local tooling: `make setup`

```bash
cd ~/Documents/Projects/marketing-crm-analytics
make setup            # .venv with Python 3.10-3.13, requirements.txt, prints versions
```

- Expect `Core: installed 1.12.x`, `Plugins: snowflake 1.12.x` and `snowflake-connector-python 4.8.x`.
- If your `python3` is 3.14, use `make setup PYTHON=python3.13`: dbt-snowflake 1.12 does not declare 3.14.
- Never `pip install dbt` into this venv. That installs dbt v2 (Fusion), a different distribution, which does not use the dbt-snowflake adapter.

## 2. Dataset: `make data`

```bash
make data
```

- Downloads the two zips only if they are missing, and checks their pinned SHA-256.
- Extracts them only after checking the member names: no absolute paths, no `..`, no symlinks.
- Then checks the SHA-256 of every CSV. Re-running only verifies.
- Details: [data/README.md](../data/README.md).

## 3. Key pairs: `make keys`

```bash
make keys                          # writes to $HOME/.snowflake/keys (mode 700)
# or: make keys ENCRYPT_PIPELINE_KEY=1   (passphrase-protect the pipeline key)
```

| File | User | Encrypted? |
|---|---|---|
| `svc_crm_pipeline.p8` / `.pub` | SVC_CRM_PIPELINE (loader, checks, dbt) | No by default; AES-256 with `ENCRYPT_PIPELINE_KEY=1` |
| `svc_crm_bi.p8` / `.pub` | SVC_CRM_BI (Data Studio) | **Never.** The Data Studio connector rejects encrypted keys |

- The script refuses to overwrite existing key files.
- It prints each public key's SHA-256 fingerprint. Keep that output; step 6 compares against it.
- Back up both `.p8` files somewhere private, such as a password manager. Never commit them: `.gitignore` blocks `*.p8`, but the keys live outside the repo anyway.

## 4. Admin SQL: `make bootstrap-sql`

```bash
make bootstrap-sql                 # -> build/snowflake_bootstrap.sql (git-ignored, mode 600)
```

- Validates both public keys (PEM, RSA ≥ 2048 bits, two different keys).
- Inserts them into [sql/setup/00_bootstrap.template.sql](../sql/setup/00_bootstrap.template.sql) as one-line bodies without BEGIN/END lines.
- Prints the fingerprints again.

## 5. Run the bootstrap in Snowsight (you, as admin)

1. Sign in to Snowsight with your admin user. On a trial this user has ACCOUNTADMIN.
2. Open a new SQL worksheet (Projects » Workspaces or Projects » Worksheets, depending on your UI version).
3. Paste the **whole** `build/snowflake_bootstrap.sql` and click **Run All**.

What it does, in order. Each section switches to the least-privileged system role that can do the job:

| Section | Role | Creates |
|---|---|---|
| 1 | SYSADMIN | `MARKETING_WH` (X-Small, Gen1, auto-suspend 60 s, initially suspended, 900 s statement timeout); QAS off; `MARKETING_CRM` with `RAW`, `STAGING`, `MART` |
| 2 | USERADMIN | Roles `CRM_LOADER`, `CRM_TRANSFORMER`, `CRM_REPORTER`, all granted to SYSADMIN |
| 3 | SYSADMIN | Warehouse/database/schema privileges per role |
| 4 | SECURITYADMIN | SELECT on all + future tables in RAW (transformer) and in MART, including views (reporter) |
| 5 | USERADMIN | `SVC_CRM_PIPELINE` and `SVC_CRM_BI` (TYPE = SERVICE, key-pair only), role grants, `DESC USER` |
| 6 | ACCOUNTADMIN | Resource monitors `RM_MARKETING_WH` (20 credits/month) and `RM_ACCOUNT_DAILY` (4 credits/day; 2 before 2026-10-14), created only if missing and then altered in place; auto-suspend 60 s on the trial's own warehouses |
| 7 | ACCOUNTADMIN | `SHOW WAREHOUSES` and a final one-row result |

Notes:

- **Run All shows only the last result.** It is one row:
  - `SNOWFLAKE_ACCOUNT`: copy this into `.env`.
  - `SVC_CRM_PIPELINE_KEY_FP` and `SVC_CRM_BI_KEY_FP`.
- The **QAS step** (statement 5) returns a text value: either *accepted* or *refused, skipped*. On Enterprise expect *accepted*. On Standard, which has no QAS, the docs do not say which one you get **(unverified)**. Both are fine, and **neither message reveals the edition**. Record the message in the trial record below.
- **If a statement fails**, Run All stops there. Fix the cause and Run All again: every statement is idempotent.
  - That includes the resource monitors. They are created only if missing and then altered in place, so a re-run neither resets their usage count nor resumes a warehouse they suspended.

## 5b. Three admin follow-ups (you, as admin, once)

1. **Turn on resource-monitor notifications.** Verify your email address and enable resource-monitor notifications in your Snowsight profile. Until you do, the NOTIFY triggers send nothing.
2. **Review every warehouse the trial created.** Run `SHOW WAREHOUSES;`. The bootstrap already set auto-suspend 60 s on `SNOWFLAKE_LEARNING_WH` and `COMPUTE_WH` if they exist. For any other warehouse, run `ALTER WAREHOUSE <name> SET AUTO_SUSPEND = 60;`. All of them are capped by `RM_ACCOUNT_DAILY`. The bootstrap also revokes the trial's `SNOWFLAKE_LEARNING_ROLE` from `PUBLIC` (it is granted to you directly instead), so the service users cannot switch to it; `make sf-check-bi` fails until that has run.
3. **If the final summary row failed**, recover `SNOWFLAKE_ACCOUNT` with:

   ```sql
   SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS SNOWFLAKE_ACCOUNT;
   ```

   For the fingerprints, see step 6.

## 6. Compare the key fingerprints

- The final row's `SVC_CRM_PIPELINE_KEY_FP` and `SVC_CRM_BI_KEY_FP` (format `SHA256:...`) must equal the fingerprints that `make keys` / `make bootstrap-sql` printed.
- If the last statement failed, run `DESC USER SVC_CRM_PIPELINE;` on its own and read the `RSA_PUBLIC_KEY_FP` row.
- To recompute a fingerprint locally:

```bash
openssl rsa -pubin -in "$HOME/.snowflake/keys/svc_crm_pipeline.pub" -outform DER \
  | openssl dgst -sha256 -binary | openssl enc -base64
```

## 7. Fill `.env`

```bash
cp .env.example .env && chmod 600 .env
```

| Variable | Value |
|---|---|
| `SNOWFLAKE_ACCOUNT` | the `SNOWFLAKE_ACCOUNT` value from step 5 (or 5b), e.g. `MYORG-MYACCOUNT` (no `https://`, no `.snowflakecomputing.com`). It lives in `.env` only; do not write it into committed files. |
| `SNOWFLAKE_PRIVATE_KEY_PATH` | absolute path, e.g. `/Users/<you>/.snowflake/keys/svc_crm_pipeline.p8` (no `~`: dbt does not expand it) |
| `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` | only if you used `ENCRYPT_PIPELINE_KEY=1`. **You** type it, in single quotes: `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE='...'` (unquoted, anything after ` #` is dropped) |
| `SNOWFLAKE_BI_PRIVATE_KEY_PATH` | absolute path to `svc_crm_bi.p8` |

The other variables already hold the right defaults.

## 8. `make sf-check`

```bash
make sf-check
```

Connects as `SVC_CRM_PIPELINE` with `CRM_LOADER` and prints PASS/FAIL/WARN lines for:

- the account identifier;
- role, warehouse and database in use;
- that no secondary roles and no admin roles are active;
- the warehouse settings from `SHOW WAREHOUSES` (size, type, auto-suspend 60, auto-resume, resource monitor, generation / QAS columns where they exist);
- a one-second query that resumes the warehouse;
- the loader's grants;
- `USE ROLE CRM_TRANSFORMER`, and that RAW, STAGING and MART are visible to it.

It exits non-zero on any FAIL. `--no-warehouse-query` skips the query that resumes the warehouse.

## 9. `make load` and `make load-challenge`

```bash
make load-dry-run        # optional, offline: what will be checked and sent
make load                # clean release   -> RAW.CAMPAIGNS, DAILY_SPEND, LEADS, CONVERSIONS
make load-challenge      # dirty extracts  -> RAW.CHALLENGE_CAMPAIGNS, ... (separate track)
```

Each run:

1. Verifies the CSVs locally: SHA-256, UTF-8, LF line endings, exact header, field count on every record.
2. Computes local control totals with `csv` + `Decimal`.
3. Connects as `CRM_LOADER` and runs [01_raw_objects.sql](../sql/setup/01_raw_objects.sql).
4. Uploads with `PUT`.
5. Pre-checks every staged record's field count before truncating anything.
6. `TRUNCATE` + `COPY` with lineage columns.
7. Recomputes the same totals in Snowflake SQL and compares them **exactly**.

Expected for the clean release:

| Table | Rows | Totals |
|---|---|---|
| campaigns | 120 | budget 5,418,642.16 |
| daily_spend | 11,240 | spend 4,523,050.02; impressions 436,844,819; clicks 7,102,319 |
| leads | 261,684 | lead_score 13,233,637 |
| conversions | 39,696 | revenue 21,561,839.01; purchases 16,691 |

The report goes to `build/load_report_<dataset>.json`. The run also prints the first `_SOURCE_ROW_NUMBER`. Snowflake does not document whether the skipped header line is counted, so record that value once (1 means it is not counted).

## 10. Load checks in Snowsight

Open [sql/setup/02_raw_load_checks.sql](../sql/setup/02_raw_load_checks.sql) in a worksheet. It runs as CRM_LOADER. Run its blocks one at a time:

| Block | Checks | Expected |
|---|---|---|
| 1 | Row counts per RAW table (all eight tables) | every row `STATUS = PASS` |
| 2 | Control totals of the clean release | every row `STATUS = PASS` |
| 3 | No NULLs, empty strings only where the files have them, lineage | every row `STATUS = PASS` |
| 3b | Total characters per table (whitespace and empty strings preserved) | every row `STATUS = PASS` |
| 4 | The 11 dirty challenge cells survived byte for byte | exactly the 11 rows listed in the block's comment (no STATUS column) |
| 5 | Exact-duplicate counts | every row `STATUS = PASS` |
| 6 | `COPY_HISTORY` | one row per file of the latest load with status *Loaded* and `ERROR_COUNT` 0 (Snowflake's load status, not PASS/FAIL) |

The same file also runs from the terminal: `.venv/bin/python scripts/run_sql.py --role CRM_LOADER sql/setup/02_raw_load_checks.sql`
exits 1 if any row says FAIL. It cannot judge blocks 4 and 6, so read those two yourself.

## 11. `make connection-test-table`, then the Data Studio test

```bash
make connection-test-table   # MART.CONNECTION_TEST as CRM_TRANSFORMER; exits 1 unless the check row says PASS
make sf-check-bi             # SVC_CRM_BI / CRM_REPORTER: sees MART, cannot read RAW
```

The last result printed by `make connection-test-table` must read
`159 | 4523050.02 | 436844819 | 7102319 | 2023-01-01 | 2025-12-01 | PASS`; on any mismatch its
STATUS is FAIL and the command exits 1. Then follow
[phase1_connection_test.md](phase1_connection_test.md) and fill in its results table.

## Cost notes

- **Rate.** `MARKETING_WH` is X-Small **Gen1**: 1 credit per running hour, billed per second with a **60-second minimum every time it resumes**. Each `make sf-check`, load or Data Studio cache miss therefore costs at least 1/60 credit. Gen2 (the default for new warehouses since mid-2026) bills a higher rate: about 1.35 credits/hour on AWS per third-party figures **(unverified)**.
- **Budget.** $400 of trial usage is roughly 80-200 credits, depending on edition and on whose per-credit price you believe (Snowflake University's FAQ: "about $5"; third-party list prices: $2-3). This whole project should use a few credits.
- **`RM_MARKETING_WH`: 20 credits a month on MARKETING_WH.**
  - Notifies at 50% and 75%.
  - Suspends at 90%, letting running queries finish.
  - Suspends immediately at 100%.
- **`RM_ACCOUNT_DAILY`: 4 credits a day across all warehouses** (raised from 2 on 2026-10-14, see below).
  - Notifies at 75% and suspends at 100%.
  - It is a runaway backstop, also covering the trial's `SNOWFLAKE_LEARNING_WH` / `COMPUTE_WH`.
  - MARKETING_WH is bounded separately by `RM_MARKETING_WH` (20 credits a month), so the daily cap mainly stops a runaway on the trial's other warehouses. Serverless features and storage are not covered (next bullet).
  - What happened on 2026-10-14: the original 2-credit cap tripped during the parallel Phase 5 dbt work (`Warehouse 'MARKETING_WH' cannot be resumed because resource monitor 'RM_ACCOUNT_DAILY' has exceeded its quota`). At that point `SHOW RESOURCE MONITORS` showed 2.10 used today and 2.19 used this month on MARKETING_WH, and Snowsight showed $395 of $400 left, so the cap was raised to 4 (`ALTER RESOURCE MONITOR RM_ACCOUNT_DAILY SET CREDIT_QUOTA = 4;`, now also in the bootstrap).
- **How the monitors behave.**
  - Usage resets at **00:00 UTC** (8 PM New York time in summer, 7 PM in winter).
  - Cloud-services credits count, even the unbilled part, so a monitor can trip slightly early.
  - Monitors do not cover serverless features or storage; QAS is off for that reason.
- **Notifications are off until you opt in.** Verify your email and enable resource-monitor notifications in your Snowsight profile (step 5b).
- **Result cache.** Identical queries on unchanged data can be answered from the 24-hour result cache. That helps Data Studio: use Owner's credentials and a long freshness interval.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `250001` *Could not connect to Snowflake backend* | `SNOWFLAKE_ACCOUNT` is wrong or contains `https://` / `.snowflakecomputing.com`. Use the org-account value from step 5. |
| `390144` *JWT token is invalid* | Three causes, in order of likelihood. (1) The account identifier is not this account's. (2) The `.p8` does not match the registered public key: `make sf-check` prints the local fingerprint, so compare it with `DESC USER ... RSA_PUBLIC_KEY_FP`, and if they differ re-run `make bootstrap-sql` and the bootstrap with the right `KEY_DIR` (safe: the bootstrap is idempotent, including the resource monitors). (3) The computer clock is off: JWTs are short-lived, so enable automatic time. |
| *JWT token has expired* / `JWT_TOKEN_INAVLID_EXPIRATION_TIME` (sic, the misspelling is in the reported error; seen in Data Studio) | Clock skew on the client side, or the connector's reported flakiness with key-pair (Dec 2025 forum report). See the fallback in phase1_connection_test.md. |
| `390189` *Role ... is not granted to this user* | Section 5 of the bootstrap did not finish. Run All again. |
| *Password was not given but private key is encrypted* / *encrypted but SNOWFLAKE_PRIVATE_KEY_PASSPHRASE is empty* | Set the passphrase in `.env`, or regenerate the pipeline key unencrypted (move the old files away first). |
| `PUT` fails in a Snowsight worksheet | Expected: `PUT` only runs from a driver or the Snowflake CLI. Use `make load`. |
| *Warehouse 'MARKETING_WH' cannot be resumed because resource monitor ... has exceeded its quota* | A monitor suspended it. Find out what used the credits first: `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (as ACCOUNTADMIN; up to a few hours of latency). Then, as ACCOUNTADMIN, raise the quota (`ALTER RESOURCE MONITOR ... SET CREDIT_QUOTA = ...`) or wait for the 00:00 UTC reset. |
| QAS statement says *refused, skipped* | Possible on Standard edition, which has no QAS: nothing to do. If the account turns out to be Enterprise, the refusal had another cause: read the error text it includes, fix that, and run `ALTER WAREHOUSE MARKETING_WH SET ENABLE_QUERY_ACCELERATION = FALSE;` as SYSADMIN. |
| `make sf-check` WARN *resource monitor ... as seen by CRM_LOADER* | Confirm as ACCOUNTADMIN with `SHOW WAREHOUSES LIKE 'MARKETING_WH'`. A non-owner role may not see the monitor name **(unverified)**. |
| `make load` FAIL in the stage pre-check | A staged record has the wrong number of fields. No table was truncated. Re-run `make data` to re-verify the CSVs. |
| `make load` FAIL after COPY | The table may be empty now. Fix the cause and re-run `make load` (it is a full refresh). |
| `make setup` refuses Python 3.14 | `make setup PYTHON=python3.13` (or `python3.12`). |
| A RAW table definition must change | `CREATE TABLE IF NOT EXISTS` keeps an existing table. `DROP TABLE` it as CRM_LOADER, then `make load`. |

## Trial record (fill in after sign-up)

The repository is public: record facts and formats here, never the account identifier or URL.

| Item | Value |
|---|---|
| Sign-up date | 2026-10-13 |
| Sign-up flow used (default / student) | default (30-day trial) |
| Trial end date shown in Snowsight | about 2026-11-12 (30 days); confirm in Snowsight |
| Sheets snapshot deadline | about 2026-11-07 |
| Cloud / region | AWS / `AWS_US_EAST_2` (US East 2, Ohio) |
| Edition | not confirmed yet |
| Account identifier (org-account) | keep in `.env` only; do not commit |
| Bootstrap run (date, message of the QAS step) | |
| First `_SOURCE_ROW_NUMBER` reported by `make load` | |
