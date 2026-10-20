# Marketing CRM & Conversion Funnel Analytics - developer commands.
# Run `make` (or `make help`) to list them. No virtualenv activation needed:
# Python tools run straight from .venv/bin.
#
# Nothing here creates the Snowflake account or runs the admin bootstrap: a human
# signs up and runs build/snowflake_bootstrap.sql in Snowsight (docs/setup_snowflake.md).

SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
VENV := .venv
VENV_BIN := $(VENV)/bin
# Stdlib-only scripts (render, dry-run) use the venv Python when it exists, else $(PYTHON).
PY := $(if $(wildcard $(VENV_BIN)/python),$(VENV_BIN)/python,$(PYTHON))

# Where `make keys` writes the key pairs and `make bootstrap-sql` reads the public keys.
# Outside the repo on purpose: private keys must never land in git.
KEY_DIR ?= $(HOME)/.snowflake/keys
# 1 = passphrase-protect the pipeline key (AES-256). The BI key is always unencrypted:
# the Data Studio connector rejects encrypted private keys.
ENCRYPT_PIPELINE_KEY ?= 0
# Dataset zips and extracted CSVs (git-ignored).
DATA_DIR ?= data/raw
# Extra flags for load_raw.py, e.g. LOAD_ARGS=--dry-run
LOAD_ARGS ?=
# Phase 2 profiling and the Phase 4 analyses: SQL run as CRM_TRANSFORMER (it owns every STAGING
# and MART object); the full output of each file is its evidence file.
EVIDENCE_DIR := docs/evidence
TRANSFORMER_SQL := $(VENV_BIN)/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200
# Phase 4 files: the command their headers document. The largest Phase 4 result has 120 rows,
# so neither cap truncates anything today; 300 keeps the evidence identical to a manual run.
ANALYSIS_SQL := $(VENV_BIN)/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300
# Phase 5: dbt Core 1.12 from the venv, always from the repository root, so dbt loads the root
# .env (it loads the first .env found from the working directory upward, and variables already
# set in the shell win). Never `pip install dbt` (that is dbt v2).
DBT := $(VENV_BIN)/dbt
DBT_FLAGS := --project-dir dbt --profiles-dir dbt --no-use-colors
# The full parse: no partial parse, every deprecation listed, and any deprecation is an error
# (a plain parse only warns and exits 0), so "0 deprecations" is enforced, not just observed.
DBT_PARSE_STRICT := --no-partial-parse --show-all-deprecations --warn-error-options '{"error": ["Deprecations"]}'
# dbt node selection for dbt-test (optional) and dbt-build-select (required), in dbt's own
# syntax, e.g. DBT_SELECT=stg_leads+ or DBT_SELECT="test_type:unit". Every dbt run writes the
# live STAGING and MART objects (one target), so select instead of rebuilding everything.
DBT_SELECT ?=
# Phase 6: where export-marts writes the dashboard tables (CSV, .xlsx, manifest.json), and extra
# flags for export-check, e.g. EXPORT_CHECK_ARGS=--offline (the files only, no Snowflake).
EXPORT_DIR ?= exports
EXPORT_CHECK_ARGS ?=

.PHONY: help setup data keys bootstrap-sql sf-check sf-check-bi load load-challenge \
	load-dry-run profile profile-challenge analyses expected-seeds expected-seeds-check seeds \
	seeds-check dbt-deps dbt-debug dbt-parse dbt-build dbt-build-select dbt-test dbt-freshness \
	dbt-docs export-marts export-check clean _require-venv

help: ## List the available targets
	@echo "Marketing CRM analytics - make targets:"
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo "Overridable: PYTHON=$(PYTHON)  KEY_DIR=$(KEY_DIR)  DATA_DIR=$(DATA_DIR)  ENCRYPT_PIPELINE_KEY=$(ENCRYPT_PIPELINE_KEY)"
	@echo "             DBT_SELECT=<dbt selector> (dbt-test, dbt-build-select)"
	@echo "             EXPORT_DIR=$(EXPORT_DIR) (export-marts, export-check)  EXPORT_CHECK_ARGS=--offline (export-check)"

setup: ## Create .venv (Python 3.10-3.13), install requirements.txt, print dbt + connector versions
	@$(PYTHON) -c 'import sys; sys.exit(not ((3, 10) <= sys.version_info[:2] <= (3, 13)))' 2>/dev/null || { \
		echo "make setup: Python 3.10-3.13 is required (dbt-snowflake 1.12 does not declare 3.14),"; \
		echo "but $(PYTHON) is $$($(PYTHON) --version 2>&1). Try: make setup PYTHON=python3.12"; exit 1; }
	@if [ -x $(VENV_BIN)/python ] && ! $(VENV_BIN)/python -c 'import sys; sys.exit(not ((3, 10) <= sys.version_info[:2] <= (3, 13)))' >/dev/null 2>&1; then \
		echo "Removing stale $(VENV) (unsupported Python)"; rm -rf $(VENV); fi
	test -x $(VENV_BIN)/python || $(PYTHON) -m venv $(VENV)
	$(VENV_BIN)/python -m pip install --upgrade pip
	$(VENV_BIN)/python -m pip install -r requirements.txt
	$(VENV_BIN)/dbt --version
	@$(VENV_BIN)/python -c 'import snowflake.connector as c; print("snowflake-connector-python", c.__version__)'

data: ## Download the two dataset zips if missing, verify SHA-256, extract safely, verify the CSVs
	DATA_DIR="$(DATA_DIR)" bash scripts/download_data.sh

keys: ## Generate RSA key pairs for SVC_CRM_PIPELINE and SVC_CRM_BI in KEY_DIR (never overwrites)
	KEY_DIR="$(KEY_DIR)" ENCRYPT_PIPELINE_KEY="$(ENCRYPT_PIPELINE_KEY)" bash scripts/generate_keys.sh

bootstrap-sql: ## Render build/snowflake_bootstrap.sql (admin SQL for Snowsight) with the public keys from KEY_DIR
	$(PY) scripts/render_bootstrap.py --key-dir "$(KEY_DIR)"

sf-check: _require-venv ## Connect as SVC_CRM_PIPELINE/CRM_LOADER; check account, warehouse, monitor, schemas, roles
	$(VENV_BIN)/python scripts/check_connection.py

sf-check-bi: _require-venv ## sf-check plus SVC_CRM_BI/CRM_REPORTER: must see MART and must NOT see RAW
	$(VENV_BIN)/python scripts/check_connection.py --bi

load: _require-venv ## Verify the 4 source CSVs, PUT + COPY into RAW.*, reconcile local vs Snowflake control totals
	$(VENV_BIN)/python scripts/load_raw.py --dataset source --data-dir "$(DATA_DIR)" $(LOAD_ARGS)

load-challenge: _require-venv ## Same for the dirty cleaning-challenge extracts into RAW.CHALLENGE_* (kept separate)
	$(VENV_BIN)/python scripts/load_raw.py --dataset challenge --data-dir "$(DATA_DIR)" $(LOAD_ARGS)

load-dry-run: ## Offline: local CSV checks + control totals for both datasets, and print the SQL load would run
	$(PY) scripts/load_raw.py --dataset source --data-dir "$(DATA_DIR)" --dry-run
	$(PY) scripts/load_raw.py --dataset challenge --data-dir "$(DATA_DIR)" --dry-run

# tee keeps the output on screen and writes it to build/ (git-ignored); pipefail keeps
# run_sql.py's exit code (1 if any STATUS row says FAIL, 2 if it cannot connect), so a failed
# check still fails make. Only a run that exits 0 is copied over the evidence file: a failed
# or interrupted run cannot truncate the committed evidence, and its output stays in build/.
profile: _require-venv ## Phase 2: profile the clean RAW tables (read-only SQL) -> docs/evidence/01_data_profiling.txt
	@mkdir -p build $(EVIDENCE_DIR)
	set -o pipefail; $(TRANSFORMER_SQL) sql/01_data_profiling.sql | tee build/01_data_profiling.txt
	cp build/01_data_profiling.txt $(EVIDENCE_DIR)/01_data_profiling.txt

profile-challenge: _require-venv ## Phase 2: profile the dirty RAW.CHALLENGE_* extracts -> docs/evidence/01b_challenge_profiling.txt
	@mkdir -p build $(EVIDENCE_DIR)
	set -o pipefail; $(TRANSFORMER_SQL) sql/01b_challenge_profiling.sql | tee build/01b_challenge_profiling.txt
	cp build/01b_challenge_profiling.txt $(EVIDENCE_DIR)/01b_challenge_profiling.txt

# Phase 4 analyses (read-only: USE and SELECT only), one per dashboard page. Each file checks
# its own printed numbers (STATUS rows), so run_sql.py exits 1 on any FAIL. All four outputs
# go to build/ first; the four evidence files are replaced together, only after all four exit
# 0, so docs/evidence/ never mixes runs. Run after `make dbt-build`.
analyses: _require-venv ## Phase 4: run the 4 analysis files (03-06) -> docs/evidence/03_overview.txt, 04_funnel.txt, 05_lead.txt, 06_efficiency.txt
	@mkdir -p build $(EVIDENCE_DIR)
	set -o pipefail; $(ANALYSIS_SQL) sql/03_marketing_overview.sql | tee build/03_overview.txt
	set -o pipefail; $(ANALYSIS_SQL) sql/04_conversion_funnel.sql | tee build/04_funnel.txt
	set -o pipefail; $(ANALYSIS_SQL) sql/05_lead_analysis.sql | tee build/05_lead.txt
	set -o pipefail; $(ANALYSIS_SQL) sql/06_marketing_efficiency.sql | tee build/06_efficiency.txt
	cp build/03_overview.txt $(EVIDENCE_DIR)/03_overview.txt
	cp build/04_funnel.txt $(EVIDENCE_DIR)/04_funnel.txt
	cp build/05_lead.txt $(EVIDENCE_DIR)/05_lead.txt
	cp build/06_efficiency.txt $(EVIDENCE_DIR)/06_efficiency.txt

# Phase 5: dbt. The seeds of independent expected values are generated from the raw CSV files
# (Python csv + decimal, no Snowflake) and committed; expected-seeds-check proves they are current.
expected-seeds: ## Phase 5: regenerate dbt/seeds/expected_*.csv from data/raw/source (offline, csv + decimal)
	$(PY) scripts/independent_check.py

expected-seeds-check: ## Phase 5: regenerate the seeds in a temp dir and fail on any difference from the committed ones (offline)
	$(PY) scripts/independent_check.py --check

# The previous names of the two targets above, kept as aliases (the Phase 5 parity report used
# them: https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/evidence/05_dbt_parity.txt).
seeds: expected-seeds
seeds-check: expected-seeds-check

dbt-deps: _require-venv ## Phase 5: install the dbt packages pinned in dbt/package-lock.yml (dbt_utils) into dbt/dbt_packages/
	$(DBT) deps $(DBT_FLAGS)

dbt-debug: _require-venv ## Phase 5: dbt debug: versions, profile (from the root .env), dbt_project.yml, Snowflake connection
	$(DBT) debug $(DBT_FLAGS)

dbt-parse: _require-venv ## Phase 5: full parse (no partial parse), every deprecation listed and fatal; queries nothing in Snowflake
	$(DBT) parse $(DBT_FLAGS) $(DBT_PARSE_STRICT)

# dbt build runs seeds, the 8 staging views, the ephemeral intermediate model, the 11 MART
# tables, 258 data tests and 7 unit tests in DAG order; it stops downstream nodes of a failure.
# It replaces the live STAGING and MART objects (one target, `prod`: see
# dbt/macros/generate_schema_name.sql); to rebuild less, use dbt-build-select.
# The same evidence rule as the SQL targets: output goes to build/ first and replaces the
# evidence file only after the parse, the build, source freshness and docs generate exit 0.
# sed strips the absolute repository path from the log; dbt never prints credentials.
dbt-build: _require-venv expected-seeds-check ## Phase 5: parse (any deprecation fails), dbt build, source freshness, docs generate -> docs/evidence/05_dbt_build.txt
	@mkdir -p build $(EVIDENCE_DIR)
	set -o pipefail; { \
	  echo '== dbt parse --no-partial-parse --show-all-deprecations --warn-error-options {"error": ["Deprecations"]}' && \
	  $(DBT) parse $(DBT_FLAGS) $(DBT_PARSE_STRICT) && \
	  echo && echo "== dbt build" && \
	  $(DBT) build $(DBT_FLAGS) && \
	  echo && echo "== dbt source freshness" && \
	  $(DBT) source freshness $(DBT_FLAGS) && \
	  echo && echo "== dbt docs generate" && \
	  $(DBT) docs generate $(DBT_FLAGS); \
	} 2>&1 | sed -e "s|$(CURDIR)/||g" | tee build/05_dbt_build.txt
	cp build/05_dbt_build.txt $(EVIDENCE_DIR)/05_dbt_build.txt

# A partial rebuild for day-to-day changes: dbt build of the selected nodes only (models with
# their data and unit tests, in DAG order), e.g. DBT_SELECT=stg_leads+ for the model and
# everything downstream of it. The evidence file is left alone: it records the full build.
dbt-build-select: _require-venv ## Phase 5: dbt build of DBT_SELECT only (required, e.g. DBT_SELECT=stg_leads+) -> build/dbt_build_select.txt
	@test -n "$(DBT_SELECT)" || { echo "make dbt-build-select: set DBT_SELECT, e.g. DBT_SELECT=stg_leads+ (the full build is make dbt-build)"; exit 2; }
	@mkdir -p build
	set -o pipefail; $(DBT) build $(DBT_FLAGS) --select $(DBT_SELECT) 2>&1 \
	  | sed -e "s|$(CURDIR)/||g" | tee build/dbt_build_select.txt

# dbt test: the data tests and unit tests on the objects already deployed, without rebuilding
# anything (dbt build runs the same tests right after each node it builds). Unit tests need
# their parent objects to exist, which any earlier dbt build provides. DBT_SELECT narrows the
# run, e.g. DBT_SELECT=mart_channel_performance or DBT_SELECT="test_type:unit".
dbt-test: _require-venv ## Phase 5: dbt test (258 data + 7 unit tests) on the deployed objects, no rebuild -> build/dbt_test.txt (DBT_SELECT narrows it)
	@mkdir -p build
	set -o pipefail; $(DBT) test $(DBT_FLAGS) $(if $(DBT_SELECT),--select $(DBT_SELECT)) 2>&1 \
	  | sed -e "s|$(CURDIR)/||g" | tee build/dbt_test.txt

dbt-freshness: _require-venv ## Phase 5: dbt source freshness of the RAW tables (loose thresholds: static data)
	$(DBT) source freshness $(DBT_FLAGS)

# dbt docs: manifest.json, catalog.json (column types read from Snowflake) and index.html in
# dbt/target/, and with --static also static_index.html: the same site in one file with the
# manifest and catalog embedded, which opens straight from disk. The site's lineage graph shows
# the whole dbt DAG. dbt/target/ is git-ignored.
dbt-docs: _require-venv ## Phase 5: dbt docs generate --static -> dbt/target/index.html + catalog.json and the single-file dbt/target/static_index.html (git-ignored)
	$(DBT) docs generate $(DBT_FLAGS) --static
	@echo "Open dbt/target/static_index.html in a browser, or serve the site: $(DBT) docs serve $(DBT_FLAGS)"

# Phase 6: the frozen data of the dashboard (architecture decision 8; the Google Sheets copy is
# recorded in docs/dashboard_validation.md, build log pass 2).
# export-marts reads every MART table the dashboard uses (EXPORT_TABLES in scripts/export_marts.py)
# as SVC_CRM_BI / CRM_REPORTER, the identity of the Data Studio connector, and writes $(EXPORT_DIR)/:
# one CSV per table, marketing_crm_dashboard_snapshot.xlsx (one sheet per table, for Google Sheets)
# and manifest.json (rows, columns, SHA-256, query IDs, HASH_AGG, column sums, provenance). The
# files are replaced together, only after the rows fetched equal a second COUNT/SUM query on each
# table and the new files pass the offline checks. Read-only in Snowflake: SELECTs only.
# The same evidence rule as above: the log goes to build/ and replaces the evidence file only on
# exit 0. export-check also writes its evidence file only when it queried Snowflake (no
# EXPORT_CHECK_ARGS); EXPORT_CHECK_ARGS=--offline checks the files alone, e.g. after the trial.
export-marts: _require-venv ## Phase 6: export the dashboard's MART tables as the BI user -> exports/ (CSVs, .xlsx for Google Sheets, manifest.json) -> docs/evidence/06_export_marts.txt
	@mkdir -p build $(EVIDENCE_DIR)
	set -o pipefail; $(VENV_BIN)/python scripts/export_marts.py --out-dir $(EXPORT_DIR) \
	  | sed -e "s|$(CURDIR)/||g" | tee build/export_marts.txt
	cp build/export_marts.txt $(EVIDENCE_DIR)/06_export_marts.txt

export-check: _require-venv ## Phase 6: exports/ vs manifest.json (SHA-256, sums, workbook cell by cell) and vs the live tables as the BI user (rows, HASH_AGG, sums); exit 1 on any difference
	@mkdir -p build $(EVIDENCE_DIR)
	set -o pipefail; $(VENV_BIN)/python scripts/export_marts.py --check --out-dir $(EXPORT_DIR) $(EXPORT_CHECK_ARGS) \
	  | sed -e "s|$(CURDIR)/||g" | tee build/export_check.txt
	$(if $(strip $(EXPORT_CHECK_ARGS)),@echo "($(EXPORT_CHECK_ARGS): $(EVIDENCE_DIR)/06_export_check.txt left unchanged)",cp build/export_check.txt $(EVIDENCE_DIR)/06_export_check.txt)

clean: ## Remove build/ (rendered SQL, load reports, last profiling, model and analysis output) and Python caches; keeps .venv, data/, docs/evidence/, exports/ and keys
	rm -rf build
	find scripts -type d -name __pycache__ -prune -exec rm -rf {} +

_require-venv:
	@test -x $(VENV_BIN)/python || { echo "No $(VENV) yet: run 'make setup' first."; exit 1; }
