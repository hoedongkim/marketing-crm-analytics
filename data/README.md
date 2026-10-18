# Data

## Source

**Marketing Campaigns & Conversions Dataset v1.0.0** by Analytics Engineering.

- Dataset page: https://www.analyticsengineering.com/datasets/marketing-campaigns
- License: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)
  - This applies to the data only. The code in this repository is MIT-licensed (see [LICENSE](../LICENSE)).
- Attribution, as suggested by the publisher:
  > Analytics Engineering, "Marketing Campaigns & Conversions Dataset v1.0.0".
  > https://www.analyticsengineering.com/datasets/marketing-campaigns
- **Changes (CC BY 4.0 §3(a)(1)(B)).** `RAW` in Snowflake holds byte-identical copies of the CSVs
  (`make load` proves it). `STAGING`, `MART`, the Data Studio dashboard and its Google Sheets
  snapshot are **typed, cleaned and aggregated** by Hoedong Kim and are not endorsed by the
  publisher. Every public report page and every Sheet carries the attribution, the license link
  and this change notice (see [docs/architecture.md](../docs/architecture.md), decision 8).

The data files are **not committed**: `make data` downloads them into `data/raw/`, which is
git-ignored except for `.gitkeep`. What is committed is derived data: [`exports/`](../exports/README.md)
holds the aggregated MART tables the dashboard is built on (Phase 6, `make export-marts`). It is under
the same CC BY 4.0 terms and carries the attribution and change notice.

## Caveats from the publisher (they shape every analysis here)

- **Synthetic.** It is generated to model a fictional business. It represents no real company, contains no real people and sets no industry benchmarks. The generator is deterministic (seed 2025090503).
- **Last-touch attribution.** Revenue is attributed to the last-touch campaign, so ROAS by channel or campaign describes attributed revenue, **not causal impact**.
- **Excluded conversions.** Offline and view-through conversions are not included.
- **No PII.**

## Files

`make data` downloads two zips, verifies them against pinned SHA-256 checksums, checks every zip
member name before extracting, and verifies every CSV.

| File | Bytes | SHA-256 |
|---|---:|---|
| `marketing-campaigns-v1.0.0-source-csv.zip` | 1,965,988 | `a69a8b189270f4292f4c8efe35c61353363b9e1de0cf8dc432c64b7aa7319f69` |
| `marketing-campaigns-v1.0.0-cleaning-challenge.zip` | 63,247 | `8cb1761ba89fc452b45c84275c1449fbf460e8c6e3a9100140fefeae2f4f1190` |

Download URL pattern:
`https://uhzz8xwe8uih5iol.public.blob.vercel-storage.com/datasets/marketing-campaigns/v1.0.0/<zip>?download=1`

### Clean release: `data/raw/source/`

| CSV | Rows | Grain | Bytes | SHA-256 |
|---|---:|---|---:|---|
| `campaigns.csv` | 120 | one row per campaign | 9,361 | `ee8a5e842a3a100c303a4a3b40ecef3b9f3c80d8b803cc84a30e8f3ac5cd638a` |
| `daily_spend.csv` | 11,240 | one row per campaign per active date | 528,707 | `e653b309c2209a876ca8590b41f7c8ef79e73d020594541342eba72341a7d8b5` |
| `leads.csv` | 261,684 | one row per lead | 11,022,084 | `b8e48b0317f1110abe65272c9a92e98dc744d5e5179bde806dc568bdfa692761` |
| `conversions.csv` | 39,696 | one row per converted lead (1:1 with leads) | 1,761,035 | `04816bfcfa48aa15ff1198f6f19ac509022a3657cd122771d855b54d14d83598` |

- **Other files.** The zip also holds `DATA_DICTIONARY.md`, `README.md`, `LICENSE.txt` and a `starter/` folder with a sample query and script.
- **Checksums.** The publisher's README mentions a `manifest.json` with checksums and reference outputs, but it is not in the zip. The per-CSV SHA-256 values above are therefore a local baseline, recorded on 2026-10-13 from the checksum-verified zip, not publisher-signed values.
- **File format.** All four files are:
  - comma-delimited;
  - UTF-8 without a BOM, pure ASCII;
  - LF line endings, header row first;
  - free of quote characters, empty fields and leading/trailing whitespace.

  These properties are what the lossless Snowflake file format in `sql/setup/01_raw_objects.sql` relies on, and `make load` re-checks them before every load.

**Control totals** (two independent local methods agreed exactly; `make load` reconciles Snowflake against them):

| Metric | Value |
|---|---:|
| total budget | 5,418,642.16 |
| total spend | 4,523,050.02 |
| impressions | 436,844,819 |
| clicks | 7,102,319 |
| sum of lead_score | 13,233,637 |
| conversions: trials / purchases | 23,005 / 16,691 |
| revenue (trials are always 0.00) | 21,561,839.01 |

### Cleaning challenge: `data/raw/cleaning-challenge/raw/`

The publisher also ships intentionally dirty extracts for a cleaning exercise. They contain:

- duplicate records;
- blank required values;
- casing/whitespace inconsistencies;
- non-ISO (slash) dates.

| CSV | Rows | Distinct keys | SHA-256 |
|---|---:|---:|---|
| `campaigns.csv` | 121 | 120 | `55eccd8a78ee6481d16cbb62f3c64d464bceb7aacaa80142a36b543ece5b05db` |
| `daily_spend.csv` | 2,001 | 2,000 | `25450222d97d0d0d469d72629504a42e3310a17944dd85aedaad5a155db1cc43` |
| `leads.csv` | 2,001 | 2,000 | `700278cb58930eb5f335c2de3493bd6ad78070fe39a272cb98ab3ccdb888176f` |
| `conversions.csv` | 2,001 | 2,000 | `ccf2deff63314e5b27f616020176c4dceb755adecd0dc6779c4e879c0078a03a` |

- **How they relate to the clean release.** Each extract is the first N keys of the clean release. Its first data row is repeated as the last line.
- **Purpose.** `make load-challenge` loads them into `RAW.CHALLENGE_*` (not run yet); they are **never unioned with the clean release** and feed the Phase 3 cleaning track only.
- **Reconciliation target.** The clean release remains the only one.
- **Defects.** The publisher's `KNOWN_ISSUES.md` lists the defect classes as acceptance criteria. Our profiling found 15 injected defects: 4 duplicate rows and 11 bad cells.

## Coverage: documented vs observed

The data dictionary documents coverage of **2023-01-01 to 2025-12-31**. The data actually observed
is narrower:

| Activity | Observed range |
|---|---|
| Campaign activity (spend dates, lead creation) | 2023-01-04 to 2025-12-02 |
| Conversions | 2023-01-05 to 2025-12-21 (conversion lag is 0-21 days) |

- Nothing falls outside the documented range.
- Late 2025 is thin because fewer campaigns run, not because data is missing: December 2025 has 1 active campaign and 65 leads.
- Use fixed date ranges in the dashboard; relative ranges such as "last 28 days" are empty.

## Re-downloading

```bash
make data                              # verify what is there; download only what is missing
make data DATA_DIR=/path/to/elsewhere  # or into another directory
```

If a zip or an extracted folder fails verification, `make data` stops and tells you which file is
affected. It never deletes or overwrites it: move it away and run `make data` again.
