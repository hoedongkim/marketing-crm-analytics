{% docs __overview__ %}
# Marketing CRM & Conversion Funnel Analytics

Grain-correct marketing funnel KPIs (spend, impressions, clicks, leads, trials, purchases,
attributed revenue) computed in Snowflake SQL and managed with dbt Core 1.12. Data: the
synthetic "Marketing Campaigns & Conversions Dataset v1.0.0" by Analytics Engineering
(CC BY 4.0); revenue is last-touch attributed, so ROAS describes attribution, not causal impact.

**Layers**

- `source raw`: the RAW landing tables, byte-identical to the published CSV files (all TEXT).
- `staging` (views, schema STAGING): typed and cleaned one-to-one with RAW; every problem is
  flagged in `DQ_ISSUES`, no row is dropped. `stg_challenge_*` run the same rules on the
  publisher's dirty extracts and are only reconciled, never used by MART.
- `intermediate` (ephemeral): `int_lead_conversions`, one row per lead with its conversion.
- `marts` (tables, schema MART): dimensions, the delivery / lead-cohort / daily activity facts
  and the campaign, channel, monthly, lead-quality and conversion-funnel marts that the Google
  Data Studio dashboard (Phase 6) is built on.
- `seeds` (schema STAGING): independent expected values from the CSV files (Python csv +
  decimal) and the publisher's reference output; inputs of the singular tests only.

**Rules that every model follows**: aggregate each fact to a common grain before joining;
ratios are ratios of sums, rounded once; activity-month and lead-cohort-month series are never
mixed. Details: `docs/architecture.md` and `docs/kpi_definitions.md` in the repository.
{% enddocs %}
