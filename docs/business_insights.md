# Business insights (DRAFT)

> **DRAFT, Phase 4 (2026-10-14). Finalised in Phase 7.** These are the Phase 4 answers to the
> seven business questions, written from the SQL evidence. Every number is copied from a file in
> [`evidence/`](evidence/) and cited as *file [statement]*; no number is typed in by hand or
> rounded from memory. Percentages are printed fractions × 100, rounded to two decimals; the few
> other derived values (a spread, a ratio of two printed values) are named as such where they
> appear. Phase 6 (dashboard) and Phase 7 (final write-up) may change the wording,
> not the numbers. Nothing here is a recommendation to move money: the budget section is a set of
> hypotheses and the tests that would decide them.

## Contents

1. [How to read this draft](#how-to-read-this-draft)
2. [The programme at a glance](#the-programme-at-a-glance)
3. [Q1. Which channels generate the most leads?](#q1-which-channels-generate-the-most-leads)
4. [Q2. Which channels have the highest lead-to-conversion rate?](#q2-which-channels-have-the-highest-lead-to-conversion-rate)
5. [Q3. Which campaigns acquire customers most cost-efficiently?](#q3-which-campaigns-acquire-customers-most-cost-efficiently)
6. [Q4. How does the conversion rate change with lead score?](#q4-how-does-the-conversion-rate-change-with-lead-score)
7. [Q5. How long does it take a lead to convert?](#q5-how-long-does-it-take-a-lead-to-convert)
8. [Q6. Which channels and campaigns have the highest ROAS?](#q6-which-channels-and-campaigns-have-the-highest-roas)
9. [Q7. Where should the budget go first? Hypotheses and tests](#q7-where-should-the-budget-go-first-hypotheses-and-tests)
10. [Trend context: why 2025 volumes fall](#trend-context-why-2025-volumes-fall)
11. [Pitfalls the SQL avoids](#pitfalls-the-sql-avoids)
12. [What this data cannot tell us](#what-this-data-cannot-tell-us)
13. [Next steps](#next-steps)

## How to read this draft

**Caveats that apply to every answer:**

- **Synthetic data.** The dataset models a fictional business. Regular patterns (a fixed CPM per
  channel, a flat 0-21 day conversion lag, a 35-lead daily ceiling per campaign) are properties of
  the generator, not market facts. Every finding is a finding about this dataset.
- **Last-touch attribution.** Each lead, conversion and unit of revenue is credited to one
  campaign by the dataset's last-touch rule. ROAS and revenue by channel describe attributed
  revenue, **not the causal effect** of the spend.
- **Association, not causation.** No spend, channel or score was ever varied at random, so no
  comparison here identifies a cause or the return of the next unit of budget.
- **Aggregate funnel.** Impressions → clicks → leads → conversions counts different units across
  campaigns; it is not one person's journey. A lead converts at most once, to a trial **or** a
  purchase, so no trial can be followed to a purchase.
- **Two time bases.** Activity figures (spend by spend date, leads by created date, conversions
  by converted date) and lead-cohort figures (what the leads created in a month later did) are
  never mixed. Conversion rates are cohort figures.
- **Volume follows the portfolio.** 22 campaigns started in 2025 against 50 in 2024 (`03 [12]`),
  so 2025 totals fall; trends are read next to the number of running campaigns.

**Citations.** `03 [8]` means [`evidence/03_overview.txt`](evidence/03_overview.txt), statement
[8]; the statement map in each SQL file's header names the block. Tags: `01` =
[`01_data_profiling.txt`](evidence/01_data_profiling.txt), `02cT` =
[`02c_analysis_marts_tests.txt`](evidence/02c_analysis_marts_tests.txt), `03` =
[`03_overview.txt`](evidence/03_overview.txt), `04` = [`04_funnel.txt`](evidence/04_funnel.txt),
`05` = [`05_lead.txt`](evidence/05_lead.txt), `06` = [`06_efficiency.txt`](evidence/06_efficiency.txt).
Every analysis query is followed by checks against independent expected values; all check rows
PASS, 0 FAIL. KPI formulas: [kpi_definitions.md](kpi_definitions.md).

## The programme at a glance

2023-01-01 to 2025-12-31, all channels (`03 [6]`, block 1; cost per conversion and per purchase
`04 [13]`, block 3.1).

| Stage | Volume | Ratio |
|---|---:|---|
| Campaigns | 120 (24 per channel) | budget 5,418,642.16, utilisation 0.834720 |
| Spend | 4,523,050.02 | |
| Impressions | 436,844,819 | |
| Clicks | 7,102,319 | CTR 0.016258, CPC 0.6368 |
| Leads (last-touch attributed) | 261,684 | click-to-lead 0.036845, cost per lead 17.2844 |
| Converted leads | 39,696 = 23,005 trials + 16,691 purchases | lead conversion rate 0.151694, purchase rate 0.063783, cost per conversion 113.9422, cost per purchase 270.9874 |
| Attributed revenue | 21,561,839.01 | ROAS 4.767102 |

## Q1. Which channels generate the most leads?

**Answer.** Affiliate, with 67,849 of 261,684 attributed leads (25.93%), narrowly ahead of
paid_search (65,268, 24.94%); video has the fewest (25,799, 9.86%). Per unit of spend the order is
the same, and it holds in every year; the channel with the most leads in a given year does not.

| Channel | Leads | Leads share | Spend share | Leads per 1,000 spend | Cost per lead |
|---|---:|---:|---:|---:|---:|
| affiliate | 67,849 | 0.259278 | 0.189659 | 79.0933 | 12.6433 |
| paid_search | 65,268 | 0.249415 | 0.198338 | 72.7551 | 13.7447 |
| paid_social | 57,619 | 0.220185 | 0.217714 | 58.5124 | 17.0904 |
| display | 45,149 | 0.172533 | 0.211206 | 47.2617 | 21.1588 |
| video | 25,799 | 0.098588 | 0.183083 | 31.1547 | 32.0979 |
| all channels | 261,684 | | | 57.8557 | 17.2844 |

Source: `03 [8]` (block 3); totals `03 [6]`.

- Affiliate and paid_search together account for 0.508694 of the leads on 0.387996 of the spend
  (cumulative shares at rank 2, computed from unrounded sums, `03 [8]`).
- Every channel ran 24 campaigns, so the gap is not a campaign count.
- **By year** (`03 [9]`, block 4): the volume leader is paid_social in 2023 (24,520 leads),
  paid_search in 2024 (29,566) and affiliate in 2025 (22,733); affiliate was fourth in 2023 with
  the fewest campaign-days (494). Leads per 1,000 of spend rank affiliate > paid_search >
  paid_social > display > video in all three years (affiliate 85.7150 / 72.9714 / 83.2843, video
  31.6631 / 31.2292 / 30.0963).

**Method.** `sql/03_marketing_overview.sql` blocks 3-4: campaigns, spend and leads are each
aggregated to one row per channel (or year × channel) in their own CTE and only then joined 1:1;
`RANK()` orders the channels and `SUM() OVER ()` gives the shares.

**Caveats.** Lead volume is not lead value (Q2, Q6). Leads per unit of spend are averages over
the campaigns that ran, not what extra spend would buy (Q7). The unchanged per-spend order across
years is a regularity of this synthetic data, likely a generator property, not an established
channel trait; it rests on 15 cells and no test.

## Q2. Which channels have the highest lead-to-conversion rate?

**Answer.** No channel converts its leads detectably better than the others. paid_search ranks
first at 0.153506 and display last at 0.149372, a spread of 0.004134 (0.41 points, `05 [11]`), and
a test of equal rates is not rejected. The ranking is not a finding.

| Channel | Leads | Converted leads | Lead conversion rate | Wilson 95% interval |
|---|---:|---:|---:|---|
| paid_search | 65,268 | 10,019 | 0.153506 | 0.150760 - 0.156291 |
| affiliate | 67,849 | 10,352 | 0.152574 | 0.149888 - 0.155299 |
| video | 25,799 | 3,933 | 0.152448 | 0.148113 - 0.156886 |
| paid_social | 57,619 | 8,648 | 0.150089 | 0.147196 - 0.153029 |
| display | 45,149 | 6,744 | 0.149372 | 0.146114 - 0.152690 |
| all leads | 261,684 | 39,696 | 0.151694 | 0.150325 - 0.153074 |

Source: `04 [8]` (block 2.1).

- **Test across channels** (`04 [9]`, block 2.2): chi-square 5.231237 on 4 degrees of freedom,
  below the 5% critical value 9.487729; p = 0.264383; Cramér's V 0.004471. All five intervals
  contain the pooled rate and no two are disjoint (`02cT [22]`).
- **The same holds at every other cut:** objective within channel, no channel rejects
  independence (p 0.619337 to 0.999400, `04 [10]`); 120 campaigns, chi-square 98.971941 on 119 df
  below 145.460740, and 4 intervals exclude the pooled rate where about 6 would by chance
  (`04 [12]`); 36 monthly cohorts, chi-square 21.684675 on 35 df below 49.801850 (`04 [17]`);
  channels within each score segment, p 0.436476 to 0.516096 (`05 [12]`).
- **What the test could have seen** (power computed outside Snowflake, quoted in the block 2.2
  comment of `sql/04_conversion_funnel.sql`): a channel one point off the others would very likely
  have been flagged; gaps of a few tenths of a point would not, so they cannot be ruled out.
- Campaign rates run from 0.096552 (CMP0084, 145 leads) to 0.187364 (CMP0054, 459 leads): both
  extremes are small campaigns, consistent with sampling noise (`04 [11]`, `04 [12]`).

**Method.** `sql/04_conversion_funnel.sql` section 2: converted leads over leads of the same leads
(lead-cohort basis), Wilson 95% intervals and chi-square tests of independence computed in SQL
(expected counts from window sums).

**Caveats.** The tests treat every lead as an independent trial; leads of one campaign may share
unobserved factors. Not rejecting is not proof of equal rates. Last-touch attribution decides which
channel a lead belongs to. A rate that does not move by channel, objective, campaign or month is
consistent with a generator that draws every lead at one rate.

## Q3. Which campaigns acquire customers most cost-efficiently?

A customer here is a **purchase**: a trial is a conversion but carries no revenue, so cost per
purchase = spend / purchases is the cost of a paying customer.

**Answer.** Small affiliate campaigns. CMP0040 (Affiliate 2023 040) has the lowest cost per
purchase, 102.1979 (146 purchases on 14,920.90 of spend), then CMP0070 (103.7036) and CMP0080
(104.0941). 9 of the 10 cheapest campaigns are affiliate; the tenth is paid_search CMP0086
(115.7615). 9 of the 10 most expensive are video, plus display CMP0018; the most expensive is
CMP0084 (video) at 872.1900 on 7 purchases (`06 [19]`, block 7; `04 [15]`, block 3.3).

At channel level a purchase costs (`04 [13]`, block 3.1):

| Channel | CPM | CPC | Cost per lead | Cost per conversion | Cost per purchase |
|---|---:|---:|---:|---:|---:|
| affiliate | 9.0001 | 0.3594 | 12.6433 | 82.8666 | 198.0229 |
| paid_search | 18.0004 | 0.5155 | 13.7447 | 89.5390 | 213.3900 |
| paid_social | 11.0001 | 0.6144 | 17.0904 | 113.8682 | 270.0855 |
| display | 6.5000 | 1.0857 | 21.1588 | 141.6514 | 332.7402 |
| video | 15.0002 | 1.6814 | 32.0979 | 210.5504 | 505.5522 |

- **In this data the cost gap is made at the click.** The channel order of cost per click is the order
  of cost per lead and of cost per purchase (ranks 1/1/1 to 5/5/5, `04 [13]`). It is not explained
  by how many clicks a lead needs: clicks per lead run nearly the other way (affiliate 35.1789,
  the most; video 19.0895, the fewest). Downstream the channels look alike: lead conversion
  0.149372-0.153506 (Q2) and purchase share of conversions 0.416476-0.425712 (`04 [6]`).
- By cost per lead, the cheapest campaign is CMP0070 (6.6944) and the most expensive CMP0084
  (42.1057) (`03 [15]`).

**Method.** `sql/06_marketing_efficiency.sql` block 7 (`RANK()` over the campaign-grain
`COST_PER_PURCHASE`, also within channel) and `sql/04_conversion_funnel.sql` blocks 3.1-3.3
(channel costs from sums aggregated on their own; cheapest and most expensive campaigns).

**Caveats.** The campaign ranking largely restates the channel ranking; a campaign manager should
read the rank within the channel. The extremes rest on few purchases (CMP0084 7, CMP0018 11,
CMP0099 15, `06 [19]`), and a top-10 list of noisy ratios selects lucky and unlucky campaigns, so
expect the next flight of a "best" campaign to move toward its channel average. Cost per purchase
divides all spend by last-touch attributed purchases: not a causal acquisition cost. The CPM
structure (near-round per channel) is a generator constant.

## Q4. How does the conversion rate change with lead score?

**Answer.** In this data the conversion rate rises steadily with the score: 9.12% of Low leads
(score 1-40), 16.18% of Medium (41-70) and 22.19% of High (71-100) converted, and every 10-point
band converts more than the one below it. This is an association within this dataset, not
evidence that the score predicts or causes conversion.

| Segment | Leads | Share of leads | Converted | Conversion rate | Wilson 95% interval | Purchase rate | Revenue per lead |
|---|---:|---:|---:|---:|---|---:|---:|
| Low (1-40) | 104,245 | 0.398362 | 9,505 | 0.091179 | 0.089447 - 0.092942 | 0.038035 | 48.6922 |
| Medium (41-70) | 78,862 | 0.301363 | 12,758 | 0.161776 | 0.159223 - 0.164363 | 0.067789 | 87.6004 |
| High (71-100) | 78,577 | 0.300274 | 17,433 | 0.221859 | 0.218967 - 0.224778 | 0.093921 | 121.8878 |
| all leads | 261,684 | 1.000000 | 39,696 | 0.151694 | 0.150325 - 0.153074 | 0.063783 | 82.3965 |

Source: `05 [6]` (block 1a).

- **Bands** (`05 [8]`, block 2a): 0.062689, 0.079515, 0.101911, 0.120666, 0.141635, 0.160280,
  0.183323, 0.203025, 0.222303, 0.240152 for scores 1-10 through 91-100: up at all 9 steps.
- **Strength** (`05 [7]`, `05 [9]`): chi-square 6,035.0180 on 2 df (critical 5.991), Cramér's V
  0.151863, a small association at the level of a single lead; the lead-level correlation of score and conversion is
  0.161215. Over the 100 single scores the rate rises by about 0.020 per 10 points (regression
  slope × 10 = 0.020034, R² 0.985549), from 0.055244 at score 1 to 0.253581 at score 100, but
  single scores are noisy: 57 of 99 score-to-score steps go up and 42 go down.
- **Value per purchase is flat** (1,280.1806 / 1,292.2459 / 1,297.7746 by segment, `05 [6]`), so
  revenue per lead follows the purchase rate.
- **No channel brings better-scored leads** (`05 [10]`-`05 [12]`): mean score 50.4742-50.6614,
  channel × segment chi-square 6.9982 on 8 df (p 0.536825); within each segment the channels
  convert alike (p 0.436476-0.516096).
- **Campaigns are too noisy to confirm it** (`05 [19]`, block 5c): across the 120 campaigns the
  correlation between the share of High leads and the conversion rate is -0.071858, while the
  score mix alone would imply only about 0.146086.

**Method.** `sql/05_lead_analysis.sql` blocks 1-3 and 5: `CASE WHEN` segments with `ROLLUP`, Wilson
intervals and chi-square tests in SQL, `NTILE` with a deterministic tie-breaker, `REGR_SLOPE` /
`REGR_R2`, `PERCENTILE_CONT`, `CUBE` + `PIVOT`. The bands come from `MART_LEAD_QUALITY`.

**Caveats.** How the score is produced, and when it is assigned, is undocumented: if it is updated
after a lead engages, it could partly reflect the conversion itself. The score is near-uniform on
1-100 and the rate is almost a straight line in it, both likely generator properties. Even in the
High segment most leads do not convert.

## Q5. How long does it take a lead to convert?

**Answer.** Between 0 and 21 days: median 10, mean 10.5056; a quarter convert by day 5, three
quarters by day 16, 90% by day 19 (`04 [18]`, block 5.1). 36.22% convert within 7 days, 68.28%
within 14, all within 21.

- **The distribution is flat** (`04 [19]`, block 5.2; `05 [16]`): every day from 0 to 21 holds
  0.043833-0.046881 of the conversions (1,740 to 1,861), consistent with a uniform lag (chi-square
  13.9823 on 21 df, below 32.671).
- **It does not differ by group** (`05 [13]`, `05 [16]`): means 10.3766-10.6084 by conversion type,
  channel and score segment; F statistics 0.0068 / 0.6944 / 1.6899, none above its 5% critical
  value.
- **Consequences for reporting:**
  - 13,675 of 39,696 conversions (34.45%) land in a later calendar month than their lead
    (`02cT [16]`, `04 [17]`). Monthly conversion rates therefore use the lead cohort.
  - 4,716 conversions (11.88%) happen after their campaign ended, carrying 2,532,266.74 of
    attributed revenue (11.74%): 2,583 within 7 days of the end, 1,568 in days 8-14 and 565 in
    days 15-21 (`05 [15]`, block 4c). A dashboard filter on the campaign window would drop them;
    the daily activity spine runs to `END_DATE + 21` for this reason (`02cT [9]`).

**Method.** `sql/04_conversion_funnel.sql` section 5 and `sql/05_lead_analysis.sql` block 4:
`DATEDIFF`, `PERCENTILE_CONT`, `GROUPING SETS`, a `GENERATOR` day spine and running totals.

**Caveats.** A flat lag with a hard stop at 21 days is most likely a generator property; nothing
here says a real lag would look like this, so this shape should not be carried into attribution
windows or forecasts. The youngest cohorts are assumed complete at the as-of date 2025-12-31. On the observed
data alone, the 65 leads created on 2025-12-01/02 have not had a full 21 days and 54 of them have
not converted (`05 [16]`), so the all-lead rate could be understated by at most 54 / 261,684
(`sql/05_lead_analysis.sql` header, G3).

## Q6. Which channels and campaigns have the highest ROAS?

**Answer.** Among channels, affiliate (6.540536) and paid_search (6.063294) have the most
last-touch attributed revenue per unit of spend, then paid_social (4.762857), display (3.908855)
and video (2.520913); the portfolio is 4.767102 (`06 [7]`, block 1). Among campaigns, CMP0080
(Affiliate 2024 080) is highest at 13.013216 and CMP0084 (Video 2023 084) lowest at 1.823364; 9 of
the top 10 are affiliate (the tenth is paid_search CMP0086, 10.849844) and 9 of the bottom 10 are
video (plus display CMP0018, 2.174672) (`06 [15]`, block 5).

- **The gap is a cost-per-lead gap** (`06 [9]`, block 2). ROAS = purchase rate × revenue per
  purchase / cost per lead. Across channels ROAS varies 2.595-fold and cost per lead 2.539-fold,
  while the purchase rate varies only 1.018-fold and revenue per purchase 1.021-fold: the channels
  differ in what a lead costs, not in what a lead is worth.
- **Stable over time** (`06 [13]`, block 4): paid_social, display and video rank 3-5 in every
  year. The top two swap once, in 2025 (activity basis: paid_search 7.306610, affiliate 7.180052;
  acquisition-year basis: 7.012011 and 6.838595).
- **ROAS differs more by channel than by objective** (`06 [11]`, block 3): pooled over channels acquisition
  (5.138426) beats awareness (4.776849) and lead_gen (4.491290), but the order is not consistent
  within channels, and every objective of affiliate (lowest 4.918439) and paid_search (lowest
  5.591099) beats every objective of display (highest 4.021415) and video (highest 2.626224). One
  exception to the channel order: among lead_gen campaigns paid_social is highest (6.173294),
  ahead of paid_search (5.591099) and affiliate (4.918439).
- **Campaigns overlap across channels** (`06 [17]`, block 6): the best campaign's ROAS is 4.27 times
  the worst's inside affiliate, 4.09 in paid_search, 2.79 in paid_social, 2.24 in display and 1.91 in
  video, and the worst affiliate campaign (CMP0085, 3.046811, rank 92) has a lower ROAS than the best
  video campaign (CMP0054, 3.486709, rank 85).
- **Over time the cumulative ROAS settles early** (`06 [31]`, block 13): from 2023-07 on it stays
  between 4.513790 and 4.898360 and ends at 4.767102. Single months swing at the data edges (2025-12:
  38.517298, one campaign spending 807.04 while 31,085.00 was booked).

**Method.** `sql/06_marketing_efficiency.sql` blocks 1-6 and 13: one CTE per fact joined at channel
grain, `UNPIVOT` with `MIN_BY` / `MAX_BY`, window sums by partition, `RANK` / `DENSE_RANK` with
`QUALIFY`, rolling and cumulative window frames.

**Caveats.** ROAS is last-touch attributed revenue / spend: it ranks attribution, not causal return,
and an average ROAS is not the return of the next unit of spend (Q7). Small campaigns have noisy
ratios (CMP0084 has 7 purchases). Near-identical conversion and revenue per purchase across
channels is most likely a property of the synthetic generator, not evidence that real channels
bring equally valuable leads.

## Q7. Where should the budget go first? Hypotheses and tests

This section is deliberately **not** a recommendation. It states what the data shows, what it only
suggests, the hypotheses that follow, and how each would be tested before any budget moves.

### What the data shows (descriptive, last-touch)

- affiliate and paid_search are the top two and display and video the bottom two in every
  channel-level view: average ROAS (`06 [7]`), each year on both time bases (the top two swap in
  2025, `06 [13]`), each spend tercile (`06 [35]`) and the largest campaigns of each channel
  (`06 [39]`).
- Share of spend vs share of attributed revenue (`06 [33]`, block 14):

  | Channel | Spend share | Revenue share | Difference |
  |---|---:|---:|---:|
  | affiliate | 0.189659 | 0.260214 | +0.070556 |
  | paid_search | 0.198338 | 0.252266 | +0.053929 |
  | paid_social | 0.217714 | 0.217520 | -0.000194 |
  | display | 0.211206 | 0.173182 | -0.038025 |
  | video | 0.183083 | 0.096817 | -0.086266 |

- Budget utilisation is 0.834720 overall and 0.831179-0.839336 in every channel; it is barely
  correlated with ROAS (0.0895 across campaigns, `06 [25]`, block 10). Unspent budget (895,592.14)
  is not a lever this data can evaluate.

### What the data suggests but does not measure

- **Larger campaigns have lower ROAS in the best channels** (`06 [35]`, block 15). By spend tercile
  of campaigns, affiliate ROAS falls 11.641415 → 6.932542 → 4.859721 (correlation of spend and ROAS
  across its 24 campaigns -0.8235) and paid_search 8.084848 → 6.521346 → 5.027759 (-0.7502);
  paid_social 5.474721 → 4.477259 → 4.717755 (-0.5517). display (-0.0055) and video (0.0861) are
  flat. The largest affiliate and paid_search campaigns still have a higher ROAS than the largest
  display (3.988662) and video (2.518050) campaigns. This compares different campaigns; it is not a
  measured response of one campaign to more spend.
- **A daily lead ceiling** (`06 [37]`, block 16). No campaign ever gets more than 35 leads on a day,
  and 4,168 of the 11,240 campaign-days sit exactly at 35: 0.680930 of affiliate's days, 0.634313 of
  paid_social's, 0.513654 of paid_search's, but 0.117448 of display's and 0.012749 of video's. CPM is
  fixed per channel. On their highest-spend fifth of days, affiliate, paid_search and paid_social pay
  22.3294, 21.8814 and 24.7676 per lead, against 6.7360, 9.5667 and 11.9126 on their lowest-spend
  fifth. This reads like a cap on leads per day at a fixed price of reach: past it, more daily spend
  buys reach and clicks but no more leads. Both the cap and the fixed CPM are almost certainly
  generator mechanics, not market behaviour.
- **Allocation scorecard** (`06 [39]`, block 17): ranked by average ROAS and by the ROAS of each
  channel's 8 largest campaigns (paid_search 5.027759, affiliate 4.859721, paid_social 4.717755,
  display 3.988662, video 2.518050), the two rankings agree on the set. The rule-based labels are
  "increase (test)" for affiliate and paid_search, "hold" for paid_social and "decrease (test)" for
  display and video. The label is a rule over descriptive ranks, not an optimisation.

### Hypotheses

| # | Hypothesis | Supporting evidence | What could make it wrong |
|---|---|---|---|
| H1 | Moving part of the video budget (then display) to paid_search and affiliate raises **total** revenue per unit of spend. | Average ROAS and every spend tercile rank them top and bottom (`06 [7]`, `06 [35]`); revenue share vs spend share (`06 [33]`). | Last-touch hides assists (H3); returns at scale are lower than the averages (`06 [35]`); averages are not marginal returns. |
| H2 | In affiliate and paid_search, extra budget returns more as **additional campaigns or campaign-days** than as higher daily spend on existing campaigns. | Cost per lead on the highest-spend fifth of days about 3.3 times (affiliate, 22.3294 vs 6.7360) and 2.3 times (paid_search, 21.8814 vs 9.5667) that on the lowest fifth (`06 [37]`); most of their days sit at the 35-lead ceiling (0.680930 and 0.513654). | The ceiling is most likely a generator mechanic; real saturation may be gradual or absent. The comparison is across days, not a test of added spend. |
| H3 | Video and display **assist** conversions that last-touch credits to other channels, so cutting them would also lower the receivers' revenue. | None in this data (one attributed campaign per lead, no touch history); it is the main risk to H1. | A holdout showing no incremental revenue from video. |

### Test designs

- **T1, matched-market (geo) reallocation test, for H1.** Pair comparable regions on pre-period
  revenue and lead volume and randomise one of each pair to treatment. In treatment, cut video
  spend by a fixed share and add the same amount to new paid_search and affiliate campaigns;
  control regions keep the current plan, so total spend is equal across arms. Primary metric:
  **total** revenue per region (all channels, not last-touch) over the test window plus the 21-day
  conversion lag. Secondary: leads, purchases, cost per lead by channel. Size the test with a power
  calculation on the primary metric before launch and fix the decision rule in advance (shift only
  if the treatment's revenue per unit of spend is higher with an interval that excludes zero).
- **T2, video holdout, for H3.** Withhold video in a random subset of regions (or audiences) for a
  fixed window and compare total revenue across all channels with the regions where video runs.
  The difference is video's incremental revenue; if its incremental revenue per unit of spend is
  at least the marginal return of the receiving channels in T1, H1 fails.
- **T3, scale-shape test, for H2.** Within affiliate and paid_search, randomly assign new campaigns
  to "more campaign-days at the current daily spend" or "the same days at a higher daily spend",
  with equal total budgets. Compare cost per lead, the share of days at the ceiling and revenue
  per unit of spend.

### Why these are hypotheses, not findings

1. **Attribution.** Last-touch credits only the final touch; assists can be neither shown nor ruled
   out here.
2. **No experiment.** Spend was never varied at random, so neither the average ROAS nor the tercile
   comparison identifies the causal or marginal return of a reallocated unit of budget.
3. **Synthetic mechanics.** The fixed CPM per channel, the 35-lead daily ceiling and near-identical
   conversion across channels are most likely generator settings; nothing here says a real media
   market behaves like this.

The recommendation block at the end of `sql/06_marketing_efficiency.sql` states the same
hypothesis and test in the SQL itself.

## Trend context: why 2025 volumes fall

| Year | Campaigns started | Active | Campaign-days | Spend | Leads | Conversions | Revenue | Cost per lead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2023 | 48 | 48 | 3,848 | 1,458,262.41 | 87,549 | 12,779 | 7,075,482.35 | 16.6565 |
| 2024 | 50 | 60 | 4,405 | 1,971,198.34 | 107,371 | 16,148 | 8,677,647.82 | 18.3588 |
| 2025 | 22 | 35 | 2,987 | 1,093,589.27 | 66,764 | 10,769 | 5,808,708.84 | 16.3799 |

Source: `03 [12]` (block 7), activity basis.

- In 2025 spend fell 44.52%, leads 37.82%, conversions 33.31% and revenue 33.06% against 2024
  (`03 [12]`). Fewer campaigns ran: 22 started against 50, 35 were active against 60.
- **Decomposition** (`03 [13]`, block 8): the 2025 change in leads (-0.3782) is campaign-days
  (-0.3219) × spend per campaign-day (-0.1818) × leads per unit of spend (+0.1208). Most of the fall
  is volume. The per-unit answer depends on the denominator: leads per unit of spend rose 12.08%,
  leads per campaign-day fell 8.30%, and leads per active campaign rose 6.60% (active campaigns
  fell more than campaign-days). Part of the cost-per-lead fall (18.3588 → 16.3799) is channel mix:
  the 2025 mix at 2024 channel CPLs would cost 17.7287 per lead, the 2024 mix at 2025 CPLs 16.7297,
  so mix accounts for roughly a fifth to a third of the fall, depending on the order.
- **Monthly** (`03 [11]`, block 6): leads move with the number of running campaigns (correlation
  0.9403 over 36 months, 0.8734 over the 31 months with at least 10 active campaigns), and the
  year-over-year direction of leads and active campaigns agrees in 22 of 24 months, and in all 12 of
  2025.
- **No detectable change in conversion:** the monthly cohort conversion rate shows no detectable
  change over the three years (chi-square 21.684675 on 35 df, `04 [17]`; Q2). Not rejecting is not
  proof of a constant rate.

**Caveat.** This is an accounting decomposition, not a causal one. The data records which campaigns
ran, not why fewer ran in 2025, so it cannot say that 2025 "performed worse" or "better".

## Pitfalls the SQL avoids

Each pitfall is computed on purpose in the evidence, labelled as wrong, so it is never charted.

| Pitfall | Wrong result | Correct result | Source |
|---|---|---|---|
| Joining daily spend to leads row by row | spend inflated 2,495 times (4.52 M → 11.3 B) | aggregate each fact first: 4,523,050.02 | `01 [29]`; [architecture.md](architecture.md#design-decisions), decision 6 |
| Activity conversions / leads of the same month as a "conversion rate" | 0.083019 to 0.938462 by month | lead-cohort rate 0.139402 to 0.169231 | `04 [17]` |
| Averaging daily cost per lead | 20.8479 | ratio of sums 17.2844 | `04 [14]` |
| Year-over-year ROAS on the activity basis | paid_social 4.273831 → 5.247262 (139,172.12 of its 2025 booked revenue came from 2024 leads) | acquisition-year basis 4.585577 → 4.554426 | `06 [13]` |
| Reporting conversions only inside the campaign window | drops 4,716 conversions and 2,532,266.74 of revenue | a daily spine to `END_DATE + 21` keeps all 39,696 | `05 [15]`, `02cT [9]` |

## What this data cannot tell us

1. **Causal effects.** Whether any channel or campaign *caused* its leads, conversions or revenue,
   or what a reallocated unit of budget would return: nothing was randomised.
2. **Assists and multi-touch paths.** Each lead has one attributed campaign and no touch history, so
   the contribution of upper-funnel channels (video, display) to conversions credited elsewhere is
   invisible.
3. **Marginal returns.** All efficiency figures are averages over the campaigns that ran; the
   scale comparisons (Q7) are associations across different campaigns and days.
4. **Individual journeys.** A lead converts once, to a trial or a purchase; whether a trial later
   becomes a purchase, repeat purchases, retention and lifetime value are not in the data.
5. **Profit.** Revenue is attributed revenue at purchase; there is no margin, cost of goods, or cost
   of handling leads, so ROAS is not a profit measure.
6. **The lead score's meaning.** How and when the score is produced is undocumented, so its
   predictive value outside this dataset is unknown.
7. **Real-market benchmarks.** The data is synthetic: the fixed CPM per channel, the flat 0-21 day
   lag and the 35-lead daily ceiling are generator settings, not market facts.
8. **Excluded conversions.** Offline and view-through conversions are not included.
9. **Decisions behind the data.** Why campaigns underspend their budgets, and why fewer campaigns ran
   in 2025, are not recorded.
10. **Completeness of the last cohorts.** The as-of date 2025-12-31 is an assumption; the data alone
    does not prove the youngest cohorts complete.

## Next steps

- **Phase 5 (dbt), done 2026-10-14:** dbt Core now builds the STAGING and MART models, the five
  analysis marts included, under the same names and with identical rows; the analysis files behind
  this page print identical output on the dbt build ([dbt.md](dbt.md)).
- **Phase 6 (dashboard):** build the four Data Studio pages from the MART tables with the calculated
  fields of [kpi_definitions.md](kpi_definitions.md), and re-check each chart against the numbers
  above.
- **Phase 7 (documentation):** finalise this document: re-verify every number against the latest
  evidence, tighten the wording, and keep the budget section as hypotheses unless real test results
  exist.
