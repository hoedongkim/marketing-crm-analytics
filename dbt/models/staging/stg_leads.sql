{#-
    STG_LEADS: RAW.LEADS typed and cleaned, one row per lead (261,684 rows). Clean release:
    an input of MART. The rules live in macros/staging/clean_leads.sql (shared by the clean
    and the challenge track); descriptions and tests are in _staging.yml.
-#}
{{ clean_leads(source('raw', 'leads')) }}
