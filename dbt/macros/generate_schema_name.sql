{#-
  Schema naming: a model or seed lands in EXACTLY the schema it names (upper-cased), so dbt
  builds MARKETING_CRM.STAGING and MARKETING_CRM.MART, the schemas the admin bootstrap created.
  dbt's default would prefix the target schema (STAGING_MART). A node without a custom schema
  falls back to target.schema; with flags.require_valid_schema_from_generate_schema_name a
  null result would be a parse error.

  What this costs (the dev/prod tradeoff, accepted for this one-person trial project):
  - There is one target, named `prod` in profiles.yml because that is what it is: EVERY dbt run
    replaces the live STAGING views and MART tables that Data Studio and the analyses in
    sql/03-06 read. There is no development copy to try a change in first.
  - dbt build stops the nodes downstream of a failure, but the nodes upstream of it are already
    rebuilt: a failed run can leave new upstream tables next to the previous downstream ones
    until the next green run.
  - Isolation would need a second database or per-developer schemas (e.g. STAGING_DEV) plus a
    `target.name != 'prod'` branch here that adds a suffix. CRM_TRANSFORMER cannot create
    schemas (no CREATE SCHEMA), so that needs an admin change first.
  Until then: limit the blast radius with --select (only the changed nodes and their
  descendants, e.g. --select stg_leads+), and run the full build only to refresh everything.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema | trim }}
    {%- else -%}
        {{ custom_schema_name | trim | upper }}
    {%- endif -%}
{%- endmacro %}
