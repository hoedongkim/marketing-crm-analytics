{#-
    DIM_DATE: one row per calendar day of the documented coverage, 2023-01-01..2025-12-31
    (1,096 rows).
    - A gap-free spine keeps the 32 days without spend on a time axis (they show as 0).
    - ROW_NUMBER() over GENERATOR numbers the rows 1..N without gaps; SEQ4() alone does not
      guarantee a gap-free sequence, so it only orders the rows.
    - WEEK_START comes from DAYOFWEEKISO, so it is always the Monday of the ISO week, whatever
      the WEEK_START session parameter says.
    The bounds come from vars coverage_start / coverage_end (dbt_project.yml); the row count
    for GENERATOR is computed from them at compile time (it must be a constant).
-#}
{%- set first_day = modules.datetime.date.fromisoformat(var('coverage_start')) -%}
{%- set last_day = modules.datetime.date.fromisoformat(var('coverage_end')) -%}
{%- set n_days = (last_day - first_day).days + 1 -%}
WITH spine AS (   -- gap-free: ROW_NUMBER() is 1..N with no gaps; SEQ4() only orders the generated rows
  SELECT DATEADD('day', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '{{ var("coverage_start") }}'::DATE) AS DATE_DAY
  FROM TABLE(GENERATOR(ROWCOUNT => {{ n_days }}))
)
SELECT DATE_DAY,
       YEAR(DATE_DAY)::NUMBER(4,0)                             AS YEAR,
       QUARTER(DATE_DAY)::NUMBER(1,0)                          AS QUARTER,
       DATE_TRUNC('month', DATE_DAY)                           AS MONTH_START,
       TO_CHAR(DATE_DAY, 'MMMM')::VARCHAR                      AS MONTH_NAME,
       DATEADD('day', 1 - DAYOFWEEKISO(DATE_DAY), DATE_DAY)    AS WEEK_START,        -- Monday, whatever WEEK_START says
       DAYOFWEEKISO(DATE_DAY)::NUMBER(1,0)                     AS DAY_OF_WEEK_ISO,   -- 1 = Monday ... 7 = Sunday
       DECODE(DAYOFWEEKISO(DATE_DAY), 1, 'Monday', 2, 'Tuesday', 3, 'Wednesday', 4, 'Thursday',
                                      5, 'Friday', 6, 'Saturday', 7, 'Sunday')::VARCHAR AS DAY_NAME,
       DAYOFWEEKISO(DATE_DAY) IN (6, 7)                        AS IS_WEEKEND
FROM spine
WHERE DATE_DAY <= '{{ var("coverage_end") }}'::DATE
ORDER BY DATE_DAY
