{#-
    STG_CHALLENGE_LEADS: the dirty RAW.CHALLENGE_LEADS extract through the same rules as
    STG_LEADS (2,001 RAW rows, 2,000 after de-duplication). Reconciliation only; MART never
    reads it. The rules live in macros/staging/clean_leads.sql (shared by the clean and the
    challenge track); descriptions and tests are in _staging.yml.
-#}
{{ clean_leads(source('raw', 'challenge_leads')) }}
