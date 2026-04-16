# Merrittocracy NFL Draft Model — Feature Dictionary

All features feed into position-group XGBoost sub-models predicting
`av_residual_z`: a player's 4-year career AV minus the expected AV for their
draft slot, standardized within position group. Higher = outperformed pick expectations.

---

## Draft Context

| Feature | Type | Description |
|---|---|---|
| `log_pick` | numeric | log(draft pick estimate). Captures the diminishing marginal value of pick slot — the difference between pick 1 and pick 5 is not the same as 100 and 104. |
| `round_num` | integer | Estimated draft round (1–7). Captures the step-function in contract slots and roster guarantees that log(pick) misses. |
| `draft_year_scaled` | numeric | `(season − 2013) / 7`. Centers on training midpoint; lets the model detect secular trends (EDGE rush premium post-2010, QB AV inflation, etc.) without treating year as a raw integer. |

---

## Athleticism (NFL Combine / Pro Day)

| Feature | Type | Description |
|---|---|---|
| `ht` | numeric | Height in inches (converted from nflreadr "6-3" string format). |
| `wt` | numeric | Weight in pounds. |
| `forty` | numeric | 40-yard dash time (seconds). Lower = faster. |
| `bench` | numeric | Bench press reps at 225 lbs. |
| `vertical` | numeric | Vertical jump height (inches). |
| `broad_jump` | numeric | Broad jump distance (inches). |
| `cone` | numeric | 3-cone drill time (seconds). Lower = more agile. |
| `shuttle` | numeric | 20-yard shuttle time (seconds). Lower = more agile. |
| `athleticism_composite` | numeric | Mean of position-group z-scores with direction-corrected signs: `mean(−forty_z, bench_z, vertical_z, broad_jump_z, −cone_z, −shuttle_z)`. 0 = position-average athlete; +1 = one SD above average. |
| `speed_score_pctile` | numeric [0,1] | Percentile rank (within draft year × position group) of Speed Score = `(wt × 200) / forty⁴`. Rewards being big *and* fast — a 212-lb RB running 4.36 scores ~110; a 180-lb RB at the same speed scores ~93. Distinguishes Bijan Robinson / CMC athletes from "small and fast" backs. |
| `bmi_pctile` | numeric [0,1] | Percentile rank of BMI = `(wt / ht²) × 703` within position group. Captures size-relative-to-position; complements raw weight. |
| `n_combine_tests` | integer | Count of non-missing combine measurements (0–8). Low values mean the athleticism composite relies on fewer events. |
| `{feat}_src` | factor | Data source for each combine measurement. Values: `"combine"` (measured at NFL Combine), `"pro_day"` (measured at college pro day), `"missing"` (no measurement available). Lets the model learn whether a 4.35 at the Combine means something different than 4.35 at a pro day. |
| `missing_forty` | integer | 1 if forty time is missing (derived in recipe). |
| `missing_bench` | integer | 1 if bench reps are missing (derived in recipe). |
| `missing_agility` | integer | 1 if both cone and shuttle are missing (derived in recipe). |

---

## Age & Experience

| Feature | Type | Description |
|---|---|---|
| `draft_age` | numeric | Player age at time of draft (years). Younger players drafted at the same slot have more development upside. |
| `draft_age_pctile_in_group` | numeric [0,1] | Percentile rank of draft age within `(model_group × round_num)`. Captures "unusually young for a first-round CB" vs. just being young overall — a 20-year-old CB in round 1 is more notable than a 20-year-old QB. |
| `college_years` | integer | Estimated years in college (clamped 1–6). Derived from draft age. |
| `is_underclassman` | binary | 1 if `college_years ≤ 3` (declared early). Early entrants have less college data but more upside. |
| `is_te` | binary | 1 if position is TE (within the wr_te group). TE and WR have different evaluation baselines despite sharing a model. |

---

## College Production (Percentile-Ranked)

All stats are percentile-ranked **within draft year × position group**, neutralizing era-level stat inflation. A QB with a 0.90 `qb_ypa_pctile` threw for more yards per attempt than 90% of QBs drafted that year. Outside coverage windows, values are `NA` (flagged via `_NA` indicators in the recipe).

Coverage: passing/rushing/receiving 2006+; defensive/interceptions 2005+.

### Passing (QB only)
| Feature | Description |
|---|---|
| `qb_cmp_pct_pctile` | Completion percentage (2-year aggregate) |
| `qb_ypa_pctile` | Yards per attempt |
| `qb_td_pct_pctile` | Touchdown rate per attempt |
| `qb_int_pct_pctile` | Interception rate — **sign-flipped** so higher = fewer INTs = better |

### Rushing (QB, RB, WR/TE)
| Feature | Description |
|---|---|
| `rush_ypc_pctile` | Yards per carry |
| `rush_att_pctile` | Rush attempt volume (proxy for usage / workhorse role) |

### Receiving (RB, WR, TE — ranked within position for wr_te group)
| Feature | Description |
|---|---|
| `rec_ypr_pctile` | Yards per reception |
| `rec_rec_pctile` | Reception count (volume) |
| `rec_td_pctile` | Receiving touchdowns |

### Defensive (DL, LB, CB, S)
| Feature | Description |
|---|---|
| `def_tot_pctile` | Total tackles (solo + assisted) |
| `def_sacks_pctile` | Sacks |
| `def_tfl_pctile` | Tackles for loss |
| `def_pbu_pctile` | Pass breakups |

### Interceptions (LB, CB, S)
| Feature | Description |
|---|---|
| `int_int_pctile` | Interception count |
| `int_yds_pctile` | Interception return yards |

---

## Year-Over-Year Trajectory

Percentile rank of the **season-over-season percentage change** in the final two college seasons. Captures "breakout" or "regression" trajectory independent of absolute production level. A 0.90 pctile means the player's improvement ranked in the top 10% of prospects at that position drafted that year.

| Feature | Base stat | Note |
|---|---|---|
| `qb_ypa_yoy_pctile` | QB yards per attempt | yr1 = final season, yr2 = penultimate |
| `qb_int_pct_yoy_pctile` | QB INT rate | Sign-flipped: improvement = fewer INTs |
| `rec_ypr_yoy_pctile` | Yards per reception | |
| `rush_ypc_yoy_pctile` | Yards per carry | |
| `def_tot_yoy_pctile` | Total tackles | |

---

## Domination (Share of Team Production)

Percentile rank of a player's share of their team's total production in their final college season. Captures "alpha option" status independent of scheme and era. A WR with 35% of team passing yards is fundamentally different from one with 12%, regardless of air-raid vs. pro-style.

| Feature | Positions | Description |
|---|---|---|
| `rec_yds_share_pctile` | WR, TE, RB | Player receiving yards / team total passing yards |
| `rush_yds_share_pctile` | RB | Player rushing yards / team total rushing yards |
| `qb_yds_per_play_pctile` | QB | Player passing yards / team total plays (rewards efficiency in all schemes) |

---

## Coverage Era Flags

| Feature | Description |
|---|---|
| `pass_coverage_era` | 1 if draft year ≥ 2006 (passing/rushing/receiving stats available). Lets model distinguish "no data" from "no production." |
| `def_coverage_era` | 1 if draft year ≥ 2005 (defensive/INT stats available). |

---

## Program Pipeline (Rolling 10-Year Window)

Historical track record of the prospect's college program at developing their position group for the NFL. Computed on a **leave-one-out** basis (excludes the prospect's own eventual outcome). Window = 10 years prior to draft year, capturing current coaching staff rather than all-time history.

| Feature | Description |
|---|---|
| `prog_pos_n` | Players from same school × position group drafted in prior 10 years |
| `prog_pos_av_mean` | Mean 4-year AV of those players |
| `prog_pos_av_median` | Median 4-year AV of those players |
| `prog_pos_boom_rate` | Fraction who were "booms" (av_residual_z > 1) |
| `prog_pos_bust_rate` | Fraction who were "busts" (av_residual_z < −1) |
| `prog_pos_avg_pick` | Average draft slot of those players |
| `prog_all_n` | Total players from same school drafted (all positions) in prior 10 years |
| `prog_all_av_mean` | Mean 4-year AV across all positions |
| `prog_all_boom_rate` | Overall program boom rate across all positions |
| `college_av_pctile` | Program's `prog_all_av_mean` ranked across all programs that draft year. Proxy for overall program quality. |

---

## Conference Tier

| Feature | Values | Description |
|---|---|---|
| `conf_tier` | `"power4"`, `"group5"`, `"fcs"` | College conference tier. Handled as categorical (step_dummy). Missing = `"unknown"` (handled by step_unknown in recipe). |

---

## NFL Team Development Features (Rolling 10-Year Window)

Historical track record of the **drafting franchise** at developing picks into productive NFL players. Computed leave-one-out on a 10-year rolling window. Uses **pick-adjusted AV** (av_residual_z) so teams that draft in the top-5 every year don't get credit for expected production.

| Feature | Description |
|---|---|
| `team_pos_n` | Picks at this position group by this franchise in prior 10 years |
| `team_pos_resid_mean` | Mean pick-adjusted AV (av_residual_z) at this position |
| `team_pos_boom_rate` | Boom rate at this position |
| `team_pos_bust_rate` | Bust rate at this position |
| `team_pos_retention_2yr` | % of picks at this position still on roster in year 2. Teams that draft and immediately cut signal both evaluation failure and development failure. |
| `team_all_n` | Total picks by this franchise in prior 10 years |
| `team_all_resid_mean` | Mean pick-adjusted AV across all positions |
| `team_all_boom_rate` | Overall boom rate |
| `team_all_retention_2yr` | Overall year-2 retention rate |

> **Note:** Team dev features are `NA` for 2026 predictions until draft night, when actual drafting teams are known. The model handles `NA` natively via XGBoost's missing value splits.

---

## Outcome Variable

| Feature | Description |
|---|---|
| `av_residual_z` | (4-year career AV − expected AV for pick slot) ÷ position-group SD. Expected AV fit from `lm(av_4yr ~ log(pick) + factor(round))` per position group on training data. |
| `outcome_class` | Derived: `"boom"` if av_residual_z > 1, `"bust"` if < −1, `"expected"` otherwise. |

---

*Last updated: 2026-04-13*
*Model training window: 2006–2020 draft classes (n ≈ 3,750 players)*
*8 position-group sub-models: qb, wr_te, dl, ol, cb, s, lb, rb*
