# Heisman "Discovery Curve" — Data Briefing for Redraft

You are helping redraft a Substack piece (working title: *The Discovery Channel*)
about why preseason Heisman favorites keep losing. An earlier draft exists and was
written **without** this data. The three CSVs here supersede any number in that draft.

Everything below is **regular-season only**, because **Heisman voting closes before
the postseason.** This is the single most important thing to preserve. The earlier
draft quoted full-season totals (including conference championship games and the
Playoff), which overstates what voters actually saw.

---

## The metric

`production` (called `hpi` in some raw files) is a deliberately crude,
scoreboard-shaped index:

```
production = total_yards / 10 + 6 * total_touchdowns
```

Total yards and TDs combine passing + rushing + receiving, so it works for QBs, RBs
and WRs on one scale. It is **not** an efficiency metric and does not reward
completion percentage or yards per attempt. That is on purpose: voters reward
counting stats, and the index is meant to approximate the stat line a voter sees.

Rankings are **within position, among Power 4 players only** (ACC, Big Ten, Big 12,
SEC, Pac-12, Big East, plus Notre Dame). Reason: all 15 winners in the study window
were P4, and an all-FBS ranking puts Group of 5 volume passers on top (the 2025
FBS leaders were South Florida, North Texas, UNLV, Texas State, Old Dominion,
Delaware) — that measures pace, not candidacy.

Qualifying thresholds: QB >= 150 pass attempts, RB >= 100 carries, WR >= 30 receptions.

---

## Files

### 1. `winners_leap_table.csv` — the core evidence
One row per Heisman winner, 2011-2025 (15 winners).

| column | meaning |
|---|---|
| `heisman_season` | year they won |
| `prior_season`, `prior_team`, `prior_team_rec` | the year *before* they won |
| `prior_yards`, `prior_td` | production the year before |
| `prior_natl_rank`, `prior_pool` | where they ranked among P4 players at their position (e.g. 35 of 67) |
| `heisman_*` | same fields for the winning season |
| `changed_schools` | TRUE if they transferred between the two seasons |
| `spots_climbed` | prior rank minus Heisman rank. **The headline number.** |
| `production_growth_pct` | % change in the production index |
| `team_wins_added` | change in regular-season wins |
| `had_prior_p4_season` | FALSE = they had no qualifying P4 season at all the year before |

Four winners (Manziel, Winston, Murray, Young) have `had_prior_p4_season = FALSE` —
they were backups or redshirts. Their `spots_climbed` is blank because there is no
"from" rank. Do not treat blank as zero.

### 2. `candidates_2026_targets.csv` — what the 2026 favorites need
One row per candidate. John Mateer appears **twice**: once off his injured 2025
season at Oklahoma, once off his healthy 2024 season at Washington State. Both are
legitimate framings and the contrast is the point.

| column | meaning |
|---|---|
| `baseline_season`, `baseline_team`, `baseline_team_rec` | the season this row is built from, and that team's regular-season record |
| `baseline_yards`, `baseline_td` | the candidate's actual production in that season |
| `rank_vs_2025_field`, `pool_2025_field` | where that line would rank **against the 2025 P4 field** at the position. Scored against a single fixed yardstick so Mateer's 2024 season and everyone else's 2025 season are directly comparable. |
| `bar_production` | production that has held **national rank 3** at that position (2021-25 median). Rank 3 is the target because it captures 15 of 15 winners — the worst any winner ranked was 3rd. |
| `growth_needed_pct` | % production increase required to reach that bar |
| `target_yards`, `target_td` | the bar expressed as a stat line, holding their current yards/TD mix |
| `target_td_if_yards_flat` | TDs required if yardage does not move (the Mendoza route) |
| `winners_who_leapt_further` | of the 11 winners with a prior P4 season, how many made a leap at least this big. **Low number = rare leap required.** |
| `wins_to_reach_12_1` | wins the baseline team must add to reach 12-1 |

**Caveat on `wins_to_reach_12_1` for the Mateer-2024 row:** it says 4, because
Washington State went 8-4. Mateer now plays for Oklahoma (10-2), so his real team
gap is 2. Use the 2025 row's value for team context.

### 3. `base_rates_by_starting_position.csv` — the honest counterweight
How often a P4 player at a given starting percentile reaches a top-3 national
finish the following season. n = 1,785 consecutive qualifying P4 seasons, 2010-2025.
Columns: `starting_percentile_band`, `n_player_seasons`, `n_reached_top_zone`,
`probability_pct`. **This is P(elite stat season), not P(wins Heisman)** —
roughly 15-30 players a year reach the zone and one wins.

---

## The findings that should drive the redraft

**1. The leap is real and large.** Ten of fifteen winners were either invisible or
outside the national top 20 the year before. Joe Burrow was **35th of 67** P4
quarterbacks in 2018 — literally mid-deck — before going 1st. Lamar Jackson 40th,
Caleb Williams 38th, Mendoza 30th, Travis Hunter 59th of 162.

**2. Touchdowns move, not yards.** TD growth beat yardage growth in 8 of 11 cases.
Mendoza is the extreme: his passing yards went **3,004 to 2,980 — down** — while his
TDs went 16 to 33. He climbed 27 spots on a +30% production increase, the smallest
of any big climber.

**3. The stat jump and the team jump are the same event.** Median winner's team
finished **12-1**. Eleven of fifteen had two or fewer regular-season losses. **No
winner's team has ever lost more than three.** The four biggest stat jumps all came
with big team jumps: Mendoza +7 wins (Cal 6-6 to Indiana 13-0), Hunter +5 (4-8 to
9-3), Manziel +4, Burrow +4. Lone exception is Derrick Henry (+22 spots, +0 wins) —
Alabama was already 12-1 and had nowhere to climb. That is a ceiling effect, worth a
parenthetical so the rule does not look overstated.

**4. The transfer portal is a team-jump machine.** Mendoza did not improve Cal, he
left Cal. Caleb Williams did the same (Oklahoma to USC). Two of the last four
winners bought their team jump rather than earning it.

**5. Cam Coleman is standing exactly where Travis Hunter stood.** Hunter's
pre-Heisman year: 721 yards, 5 TD, 59th of 162. Coleman's 2025: **725 yards, 5 TD,
53rd of 175.** Four yards apart, same touchdowns, same slot. Coleman needs a +86%
leap, which only 5 of 11 winners matched — rare, but the most recent person to do it
started from the identical line.

**6. Mateer needs no leap at all.** His healthy 2024 line (3,986 yards, 44 total TD)
*already clears the bar* — run against the 2025 P4 field it finishes **first in the
country**. He is the only candidate who does not need to improve, only to be who he
already was. His 2024 team went 8-4, so the stats were Heisman-grade and the team
never was; Oklahoma is his version of the Mendoza transaction.

**7. The counterweight — do not skip this.** The base rate rises monotonically with
where you start: 1.1% from the bottom band, 21.4% from the top. Being already elite
is the best single predictor of being elite again. So the draft's thesis conflates
two different things:
- P(was not already famous | won) is high — **true**
- P(wins | not already famous) is low — **also true**

Both hold because the non-elite pool is roughly ten times larger. The honest version
is: *the winner will probably be someone you cannot name today, and that is exactly
why you cannot name him.* The field of unknowns collectively owns the trophy; each
individual unknown is a 2-4% shot. Do not write "bet on the unknown" — write "the
unknowns as a group will beat the favorites, and you cannot pick which one."

---

## Corrections to the earlier draft — apply these

1. **Dante Moore.** Draft says 3,565 yards, 30 TD, 10 INT. Voters saw **2,733
   passing yards, 24 TD, 6 INT** plus 191 rushing and 1 score. The smaller number
   makes the point better: he was **30th of 73** P4 quarterbacks in production, which
   is *why* he got zero votes, not a mystery alongside it.

2. **Jeremiah Smith.** Draft says 87 catches, 1,243 yards, 12 TD. Regular season was
   **80-1,086-11** (plus 20 rushing yards and a score).

3. **DeVonta Smith 2020.** Draft says 105-1,641-20. Regular season: **1,522 yards,
   18 TD.**

4. **"Eleven for eleven" needs a caveat.** Two of fifteen winners (Mayfield, DeVonta
   Smith) were already top-5% nationally the prior year. The streak of preseason
   favorites losing is real; "nobody already famous ever wins" is not.

5. **The "It will be number 10, not number 4" section is the weakest part.** Jeremiah
   Smith needs a **+4%** leap — smaller than any of the eleven winners required.
   DeVonta Smith, the draft's own vote-splitting example, entered his Heisman year at
   the 98th percentile, almost exactly where Jeremiah Smith sits now. The
   already-famous receiver path exists and the draft cites its best example while
   arguing against it.

6. **Arch Manning deserves more respect than the draft gives him.** Texas went 9-3,
   so he needs a **three-win team improvement** that only four winners in fifteen
   years matched — but his *production* gap is only +25%, which 9 of 11 winners
   exceeded. He is a team-quality problem, not a talent problem. That is a more
   interesting objection than "he was hyped."

7. **Dante Moore's real obstacle is play-calling.** If his yardage stays flat he
   needs **59 touchdowns**. The Mendoza route is arithmetically unavailable to him
   because his yardage base is too low. He cannot win this without Oregon throwing
   meaningfully more — a concrete, falsifiable claim to put in print in August.

---

## Known limitations — state them, do not hide them

- **No team-quality term in the production bar.** It measures what it takes to be
  *visible*, not to win. A 12-0 team can drag a 6th-place stat line onto the podium;
  an 8-4 team can bury a 1st-place one. Mendoza won from rank 3 on the back of 13-0.
- **Cam Newton (2010) is absent** from the source data entirely and is excluded.
- **Window is 2011-2025.** Earlier seasons are unusable: 2008 carries only 77
  qualifying QBs for 122 teams, so percentiles there are computed against a pool
  missing 45 starting quarterbacks.
- **Cam Coleman's Texas transfer is an assumption**, supplied by the author. The
  data ends at 2025, where he is at Auburn.
- Sacks count as rushing attempts in NCAA statistics, which slightly depresses QB
  rushing yardage relative to NFL conventions.

---

## Tone notes

Author is @Merrittocratic (Substack: themerrittocracy.substack.com). Voice in the
existing draft is confident, dry, short-paragraph, section headers with wordplay,
comfortable with a hard number in the middle of a sentence. Keep it. Do not add
hedging throughout — the piece states a position and prices it. Where the data
undercuts a claim, the move is to say so plainly and turn the tension into the
argument, not to soften every sentence.

Source: cfbfastR / College Football Data API, player-season stats and team records.
Everything here regenerates from `content_heisman_discovery_curve.R` in the project
root. This briefing is hand-written and is the one file that script does not touch.
