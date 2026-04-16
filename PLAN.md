# NFL Draft Model: Plan of Action

---
## Progress Log

### Session 1 — 2026-03-25
**Completed:**
- [x] All R packages installed globally (tidyverse, tidymodels, nflreadr, xgboost, finetune, baguette, probably, fuzzyjoin, rvest, polite, tabnet, torch, cli, glue, scales, reticulate)
- [x] torch backend installed and verified
- [x] TabPFN 7.0.0 installed in `nfl-tabpfn` Python virtualenv, smoke test passed
- [x] renv attempted and intentionally removed — will revisit after pipeline is validated
- [x] Fixed `source("R/00_config.R")` → `source("00_config.R")` in all 5 pipeline scripts
- [x] Fixed `career_av` (entirely empty in nflreadr) — outcome metric is now `w_av` (Weighted Career AV)
- [x] **Outcome metric decision:** `w_av` adopted as intentional choice (not proxy). PFR weights peak/early seasons heavily, which naturally addresses career-length bias without a strict 4-year cutoff. `01b_scrape_av.R` deferred — PFR is behind Cloudflare, rvest/polite cannot bypass it.
- [x] Replaced exact combine name join with `fuzzyjoin::stringdist_left_join()` (Levenshtein, max_dist=2) + name normalization (lowercase, strip Jr/Sr/II/III, strip punctuation)
- [x] `01_load_data.R` runs cleanly → `data/01_draft_combined.rds` (4,915 rows, 50 cols)

**Key data validation results from 01_load_data.R:**
- 4,915 draft picks (2006–2026), 7,021 combine records
- Combine match rate: 82.0% (4,031 / 4,915)
- w_av coverage (training years 2006–2020): 91.3% (3,421 / 3,746)
- Group sizes: db=761, dl=719, wr_te=702, ol=623, lb=419, rb=344, qb=178 — all above 300 floor
- Mean w_av=18.9, median=11, 10.9% zero AV — right-skewed, realistic

---

### Session 2 — 2026-03-27
**Completed:**
- [x] `02_feature_engineering.R` runs cleanly → `data/02_draft_features.rds`
  - Fixed `ht` column: nflreadr returns height as `"6-2"` strings — added conversion to numeric inches before z-score computation
- [x] **Outcome metric upgrade:** PFR account obtained, pivoting from `w_av` to true 4-year windowed AV via manual CSV exports
  - PFR exports player-season-team rows (one row per team per season per player)
  - Pagination limit: 200 rows per export; filter by draft year + season
  - Pull strategy: 15 draft years × 4 seasons = **60 CSVs**
  - Naming convention: `pfr_av_d{draft_year}_s{season}.csv` (e.g., `pfr_av_d2006_s2007.csv`)
  - Drop CSVs in `data/pfr_av_raw/` (directory created)
- [x] `01b_scrape_av.R` rewritten as CSV ingestion script (not a scraper)
  - Handles multi-team seasons (sums AV across teams within player-season)
  - Computes 4-year total AV + year-by-year features (`av_yr1`–`av_yr4`)
  - Additional features: `seasons_active_4yr`, `n_teams_4yr`
  - Output: `data/01b_av_4yr.rds`
- [x] `.gitignore` fixed (was named `gitignore` without the dot)
- [x] All pipeline scripts committed and pushed to GitHub (merrittocratic/nfl-draft-model)

---

### Session 3 — 2026-03-28
**Completed:**
- [x] Validated 2006 draft class CSVs (4 files, 725 rows across 4 seasons)
  - Column structure confirmed correct — `AV...3` and `AV...14` auto-renamed as expected
  - Both AV columns are identical (single-season filter means season AV = only AV present)
  - Zero missing `Player-additional` (pfr_id) values — join key is clean
  - No multi-team player-seasons in 2006 class
  - 224 unique players (vs ~255 picks — delta is kickers/punters/LSs, expected)
  - Row counts decline across seasons (194→192→169→166) — realistic attrition

---

### Session 4 — 2026-04-01
**Completed:**
- [x] All 60 PFR CSVs collected and dropped in `data/pfr_av_raw/`
- [x] Fixed rookie-year bug in `01b_scrape_av.R` (`season > draft_year` → `season >= draft_year`)
- [x] Fixed headerless CSV bug in `01b_scrape_av.R` — 4 files (d2020_s2022, d2020_s2023, d2021_s2023, d2021_s2024) had no header row; switched to per-file header detection with explicit column names
- [x] `01b_scrape_av.R` run successfully → `data/01b_av_4yr.rds` (3,432 players)
- [x] Rewired `01_load_data.R` to join real 4yr AV from `01b_av_4yr.rds` on `pfr_player_id`; ~91% coverage vs training classes
- [x] Fixed critical DB position mislabeling: nflreadr labels most pre-2015 CBs as generic "DB"; routing all DB → S inflated round-1 S count to 64 (should be ~25) and deflated CB to 24 (should be ~55). Fix: resolve DB using combine `pos` column after fuzzy join, exclude unresolvable DBs
- [x] **Architecture change: split CB and S into separate sub-models (7 → 8 groups)**
  - CB: ~4% boom, ~14% bust — high risk, scheme-dependent, hardest position to evaluate
  - S: ~12% boom, ~8% bust — safer, athleticism-driven
  - Sample sizes support split: S=545, CB=162 in training data
  - `00_config.R` `position_model_map` updated; re-ran 01 → 02
- [x] `01_load_data.R` and `02_feature_engineering.R` re-run with correct positions and real AV
- [x] Created `content_downs_positional_value.R` — standalone article table script reading from `02_draft_features.rds`; retired `01b_compute_4yr_av.R`
- [x] Created `install_check.R` — post-R-upgrade package verification script
- [x] Scoped OpenClaw/Mac Mini as future post-draft project in CLAUDE.md and INSTRUCTIONS.md
- [x] EDGE/IDL split evaluated and rejected — outcome profiles similar enough, sample sizes fine combined
- [x] Data quality findings documented:
  - QB boom rate elevated by cross-position pick bin baseline + historically strong 2017–2020 class; keep as-is, contextualize in content
  - RB boom rates high due to AV rewarding volume not value; zero bust rates in rounds 5-7 are a mechanical floor artifact; keep as-is with content caveat
  - S numbers now realistic after DB fix (~25 round-1 Ss, ~55 round-1 CBs over 15 years)

### Session 5 — 2026-04-02
**Completed:**
- [x] Identified cross-position pick bin baseline was distorting outcome variable —
  S boom rates suppressed, RB boom rates inflated due to benchmarking against all
  positions at a pick slot rather than position-specific history
- [x] **Outcome variable overhaul:** replaced pick bin averages with per-group log-pick
  curves — `lm(av_4yr ~ log_pick + factor(round_num))` fitted on training data per
  model group. Residuals standardized within group. Boom/bust thresholds (±1 SD)
  are now position-specific.
- [x] `02_feature_engineering.R` updated and re-run — new outcome distribution:
  503 booms (15%), 357 busts (11%), 2,554 expected (77%). R² by group: 0.32–0.49.
- [x] Created `02b_feature_engineering.R` — preserves original cross-position pick
  bin approach for comparison; outputs `data/02b_draft_features.rds`
- [x] Created `content_1b_downs_positional_value.R` → `table_1.png` (old baseline)
- [x] Renamed existing table to `table_2.png`; updated `content_downs_positional_value.R`
  to match
- [x] Sanity checked round-1 RB and S boom/bust player lists — all classifications
  correct. Saquon Barkley as bust (#2, 29 AV vs 40.0 expected) is defensible and
  a deliberate content callout (availability IS the outcome)
- [x] OL/RB/S showing near-zero boom-bust delta in round 1 investigated — RB (7/7)
  and S (5/5) are small sample coincidence; OL near-zero is a real finding
  (teams efficiently price round-1 OL)
- [x] Added social media risk signal as future model feature (item 9) in CLAUDE.md
- [x] Building in public log updated: log-pick curve methodology decision +
  availability-as-outcome angle

### Session 6 — 2026-04-04
**Completed:**
- [x] Fixed multiple `03_model_spec.R` issues:
  - Base R `|>` pipe `.` placeholder fix (set_names)
  - `batch_size` fixed at 128L (removed from tuning grid — dials incompatibility)
  - `step_zv` added before `step_normalize`; recipe step order corrected (dummy before zv)
  - `local()` closure to capture free variables (`combine_features`, `shared_features`, `SEED`)
    so they serialize with the function into RDS and are available in parallel workers
  - `nthread = 1` for XGBoost and ranger (over-subscription fix for parallel CV)
  - `make_folds` wrapped in `local()` for consistency
- [x] Fixed `04_train_evaluate.R`:
  - `library(tabpfn)` → `library(callr)`; TabPFN runs in isolated subprocess via `callr::r()`
    to avoid R torch / Python torch dylib symbol clash
  - `doFuture` parallel backend added for XGBoost CV (`parallel_over = "resamples"`)
  - `allow_par = FALSE` added to TabNet `control_grid()` — torch crashes in parallel workers
  - MPS disabled — tabnet nn_module operations not compatible with Apple MPS backend
  - Per-group checkpoint writes added (`data/04_checkpoint_*.rds`)
  - `av_residual` → `av_residual_z` throughout `03`, `04`, `05` — model was predicting
    raw AV residuals instead of z-scores; RMSE now on correct scale (~1.0 null model)
  - TabNet `tryCatch` for graceful failure handling
  - `comparison_winner` vs `deploy_winner` split — TabPFN comparison-only, final model
    always XGBoost or TabNet
- [x] EDA findings:
  - Program pipeline features ARE working — early years (2006-2009) near-zero by design,
    2015-2020 averaging prog_all_n=23-30, prog_pos_n=3-4. Not a bug.
  - Individual feature correlations with av_residual_z are weak (r < 0.08 for all features)
  - RMSE ~1.0 reflects genuine difficulty of predicting AV residuals from pre-draft features
  - **College production features identified as highest-ROI improvement** — not yet built
- [x] Built `01c_load_college_stats.R` — cfbfastR integration (not yet sourced)
  - Pulls passing, rushing, receiving, defensive, interception stats 2002–2025
  - File-cached raw data (`data/01c_college_stats_raw.rds`)
  - Fuzzy join to draft prospects on name + college
  - Match rate diagnostics by model group
- [x] `PICK_LADDER` added to `00_config.R`
  - `c(seq(1, 64, by=4), seq(64, 260, by=10))` — avoids round-number anchoring bias
- [x] cfbfastR installed; API key in `.Renviron`; `register_cfbd()` moved to `01c` (not config)
- [x] `04_train_evaluate.R` kicked off — CB complete (XGB 0.97, TabPFN 1.01, TabNet 0.99),
  remaining groups likely running or checkpointed
- [x] Downs article reviewed; "Track Record" section drafted (Berry, Smith, Hamilton, Barron);
  Saban placeholder placed in "The Prospect" section

### Session 7 — 2026-04-06
**Completed:**
- [x] Diagnosed three structural problems suppressing college stats signal (RMSE 0.963–0.996):
  1. `step_impute_median` for college pctiles was creating spurious "real vs imputed 0.5" splits —
     LB `int_int_pctile` gain=0.6578 with RMSE=0.991 is the textbook artifact signature
  2. WR/TE rec_* percentiles computed within `(season, model_group)` mixed WR and TE scales,
     diluting both signals and leaving `log_pick` as top WR/TE feature
  3. RB `rec_ypr_pctile` imputed to 0.5 for 77% of observations drowned a known r=0.60 signal
- [x] **Priority 1 (imputation fix):** Removed `step_impute_median` for college pctile features
  from shared recipe in `03_model_spec.R`; added `make_tabnet_recipe()` (imputation only for TabNet)
- [x] **Priority 2 (WR/TE percentile):** rec_* features for wr_te group now ranked within
  `(season, position)` not `(season, model_group)`; added `is_te` indicator feature
- [x] **Priority 3 (domination features):** Added team stats pull (`cfbd_stats_season_team()`)
  to `01c`; computes `rec_yds_share`, `rush_yds_share`, `qb_yds_per_play` (share of team production)
- [x] **Priority 4 (YOY trajectory):** Added `extract_yoy_stat()` helper to `01c`; produces
  yr1/yr2 separate values for qb_ypa, rec_ypr, rush_ypc, def_tot; YOY pctile features in B3 section of `02`
- [x] **Priority 5 (age percentile):** Added `draft_age_pctile_in_group` within `(model_group × round_num)`
- [x] All three college stats caches deleted for clean re-pull
- [x] Code committed and pushed

---

### Session 8 — 2026-04-11
**Completed:**
- [x] **Pro day data integration (Phase 6 complete):**
  - `01e_scrape_pro_day.R`: Two-phase MockDraftable API fetch (slug resolution + batch measurements)
  - Fills ~10% of missing combine measurables: 58 forty times, 144 bench, 148 cone, 166 shuttle
  - `01_load_data.R`: hybrid coalesce (combine → pro day), `{measurable}_src` indicator columns added
  - `02_feature_engineering.R`: src columns added to `shared_features`
  - `03_model_spec.R`: src columns handled as categoricals (step_unknown + step_novel + step_dummy)
- [x] **TabNet disabled** (`RUN_TABNET <- FALSE`): was taking 12-14 hours, never beating null model
  on any group. One flag to re-enable for final pre-draft run if desired. Runtime: 12-14h → 2-3h.
- [x] `qb_int_pct_yoy` added to `01c` and wired through `02` — year-over-year INT rate trajectory
- [x] Team development leaderboard: `content_team_dev_leaderboard.R` + lollipop chart
  - Both relocated franchises (STL→LAR, SDG→LAC) improved dramatically post-move
- [x] Various bug fixes: `normalize_franchise` coalesce, `qb_int_pct_yr1/yr2` missing from `yoy_cols`,
  `01c` re-run to regenerate with new columns
- [x] `02` → `03` → `04` kicked off (04 running overnight)

### Session 9 — 2026-04-12
**Completed:**
- [x] Fixed `step_novel`/`step_unknown` ordering bug — `_src` columns must be sanitized before
  `step_impute_bag` (bagged trees errored on unseen factor levels in CV assessment folds)
- [x] **04 results reviewed** — per-group RMSE baseline established:

| Group | XGBoost | TabPFN | vs. Session 7 |
|-------|---------|--------|---------------|
| cb    | 0.959   | 1.010  | —             |
| qb    | 0.948   | 1.030  | ▲ (was 0.956) |
| dl    | 0.984   | 0.998  | —             |
| wr_te | 0.989   | 0.999  | —             |
| s     | 0.991   | 1.000  | —             |
| lb    | 0.995   | 1.010  | —             |
| ol    | 0.998   | 1.000  | ≈ (was 0.997) |
| rb    | 1.000   | 1.020  | null model    |

- [x] **`05_predict_2026.R` built and running** — full scoring pipeline:
  - Mock board + combine join; pick_est = mock_pick or big_board_rank
  - Boom/bust probabilities from regression output + CV RMSE uncertainty
  - SHAP values via `shapviz` (waterfall per R1/R2 player, beeswarm per group)
  - Player cards to `output/2026_player_cards.csv`

---

### Session 10 — 2026-04-13
**Completed:**
- [x] **College stats wired into `05_predict_2026.R`** (Section C2):
  - `01c_load_college_stats.R` now exports `data/01c_player_stats_base.rds` (per-player rate stats,
    no draft record needed — keyed by name_norm + college_norm)
  - `05` fuzzy-matches 2026 prospects to stats by name + college, computes within-2026-cohort
    percentile ranks by model_group (same within-(season × group) scheme as training)
  - YOY trajectory features computed and ranked
  - WR/TE rec_* and rush_* re-ranked within (model_group, position) — same split as training
- [x] **Fixed domination features in `01c`**: `school` → `team` column name; added `rename(any_of(...))`
  to handle cfbfastR API column name variants (`net_pass_yds`, `pass_atts`, `rush_atts`)
- [x] **Speed Score added to model**:
  - `speed_score_pctile` and `bmi_pctile` added to `shared_features` in `02_feature_engineering.R`
    (were computed but not fed into model)
  - B3b section added to `05` to compute speed_score and bmi for 2026 prospects
  - Fixes J. Love athleticism SHAP — model now distinguishes 4.36/212 lbs from 4.36/180 lbs
- [x] **Fixed missing non-combine prospects** (Caleb Downs, Sonny Styles):
  - Section A4 added to `05` — pulls all mock board players not in combine data, adds with NA
    measurables (model handles natively)
  - Top-64 audit check added: warns if any top-64 mock players still missing after A4
- [x] **College name canonicalization** (`canonicalize_college()` in `00_config.R`):
  - nflreadr abbreviates "Ohio St.", "Penn St." etc.; cfbfastR and mock board use full names
  - Regex-based `canonicalize_college()` expands all "X St." → "X State" patterns + named exceptions
  - Applied in: `normalize_college()` in `01c`, `normalize_college_local` in `05` C2,
    `school` column in A1 of `05`, `draft_fe$college` at top of `05`
  - Fixes program pipeline lookup (was silently failing for mock-only players at "Ohio State" schools)
  - Fixes college stats join (was "ohio st" ≠ "ohio state" for combine players)
- [x] **`feature_dictionary.md`** created — full feature reference with descriptions, all 50+ features
- [x] **`RUN_TABNET <- TRUE`** — overnight run kicked off: `02` → `03` → `04` (XGB + TabPFN + TabNet)
  → `05`. Expected completion: tomorrow morning (~14-16 hrs).

### Session 11 — 2026-04-14
**Completed:**
- [x] **Removed `athleticism_composite` from `shared_features`** — low Gain for all groups except RB,
  where it dominated non-intuitively negative (composite is collinear with raw events already in model;
  "elite composite + top RB pick = disappoints" artifact). Re-ran `02` → `03` → `04` → `05`.
  Love's SHAP waterfall now clean: bench/speed_score/wt driving positive, no composite distortion.
- [x] **Three-way model comparison finalized:**
  - XGBoost wins all 8 groups (RMSE 0.951–1.000)
  - TabPFN beats null on dl/wr_te only; fails on 6 of 8
  - TabNet all NA — permanently disabled (`RUN_TABNET <- FALSE`)
- [x] **SHAP waterfall analysis** — reviewed Love (RB), Lemon (WR), Bailey vs. Reese (DL), Styles (LB)
- [x] **Fixed Sonny Styles / Alex Styles nickname bug:**
  - nflreadr stores legal name "Alex Styles"; mock board uses "Sonny Styles"
  - Combined join failed → added as mock-only with all-NA combine measurables
  - College stats join also failed → def_tot_pctile = NA (his biggest driver)
  - Fix: `name_aliases` applied to `mock_raw` in A2 (before combine-mock join)
  - `college_stats_name_overrides` (inverse of aliases) applied in C2 name normalization
  - Display name restored to "Sonny Styles" before `player_cards` output
  - Predicted z: NA-version +0.09 → incomplete +0.01 → correct +0.13
- [x] **Fact-checked front seven article claims against actual data:**
  - First-round LB bust rate is 32.6% (not 11% as drafted — that was the all-rounds rate misapplied)
  - First-round EDGE: 18.3% boom / 29.6% bust (-11.3%)
  - First-round IDL: 26.1% boom / 15.2% bust (+10.9%) — strongest position in front seven
  - All-rounds LB: 14.6% boom / 10.7% bust — the "11%" was this number, wrong context
- [x] **EDGE sack specialist scatter plot:** `content_front_seven_scatter.R` created
  - Finding: no booms with sacks pctile < 0.50; elite sacks necessary but not sufficient
  - Real insight: position is volatile regardless of production profile (30% bust rate persists
    even among elite-production EDGE prospects)
- [x] **Roadmap updated:** nickname crosswalk added as quick win; cfb_player_id as architectural fix

**Next session starts here (draft night April 24):**
1. **Re-run `05_predict_2026.R`** with actual picks and actual drafting teams
2. **Update team dev features** — `team_pos_bust_rate`, `team_all_resid_mean` etc. are NA for 2026;
   after picks are known, these resolve from training data by drafting team
3. **Verify all top picks present** — run top-64 audit check from console

---

## Context
The 2026 NFL Draft is April 24–26, 2026 (10 days away). Pipeline is complete and scoring.
`RUN_TABNET <- FALSE` permanently. XGBoost is the deployment model for all 8 groups.

Key gaps resolved:
1. ~~Environment not validated~~ — **RESOLVED**
2. ~~`career_av` proxy~~ — **RESOLVED**: true 4-year AV via PFR CSV exports
3. ~~Column name mismatches~~ — **RESOLVED**
4. ~~Combine join fuzziness~~ — **RESOLVED**: fuzzyjoin implemented
5. ~~`ht` stored as string~~ — **RESOLVED**
6. ~~PFR CSV collection~~ — **RESOLVED**: 60 CSVs, `01b_av_4yr.rds` generated
7. ~~Pro day data missing~~ — **RESOLVED**: MockDraftable API, src indicators in model
8. ~~2026 scoring~~ — **RESOLVED**: `05_predict_2026.R` complete
9. ~~College stats not wired into 05~~ — **RESOLVED**: Session 10
10. ~~Missing non-combine prospects~~ — **RESOLVED**: A4 mock-board backfill
11. ~~College name mismatch (Ohio St. vs Ohio State)~~ — **RESOLVED**: `canonicalize_college()`
12. **Conference mapping** — still a placeholder; low priority given time constraint

---

## Phase 1: Environment Setup
**Goal:** Reproducible, runnable R environment with all dependencies confirmed.

### 1a. Initialize renv
- `renv::init()` to snapshot the project
- Add `renv.lock` to git (not .gitignore)
- This gives reproducibility and makes it obvious when packages are missing

### 1b. Validate all package installs
Install and confirm:
- Core: `tidyverse`, `tidymodels`, `nflreadr`, `xgboost`, `finetune`, `baguette`, `probably`
- Fuzzy join: `fuzzyjoin`
- Scraping: `rvest`, `polite`
- ML: `tabnet`, `torch`
- TabPFN: `reticulate` + Python virtualenv with `tabpfn` Python package
- Diagnostics: `cli`, `glue`, `scales`

### 1c. Validate Python environment for TabPFN
- `reticulate::virtualenv_create("nfl-tabpfn")`
- `reticulate::py_install("tabpfn", envname = "nfl-tabpfn")`
- Quick smoke test: import tabpfn from R

**Decision point:** If TabPFN setup is painful, we can drop it from the initial run and run XGBoost + TabNet only. Flag and discuss.

---

## Phase 2: Data Foundation (Highest Priority)

### 2a. Fix `01_load_data.R` — column name validation
- Run with actual nflreadr and inspect column names from `load_draft_picks()` and `load_combine()`
- Fix any mismatches (CLAUDE.md TODO #3)
- Add `cli::cli_alert_info()` column name diagnostics at load time

### 2b. Improve combine join — fuzzyjoin
- Replace exact `pfr_player_name` match with `fuzzyjoin::stringdist_left_join()`
- Normalize: lowercase, strip suffixes (Jr., Sr., II, III), strip punctuation
- Report match rate before and after (goal: >90% match for main combine measurables)

### 2c. Implement `01b_scrape_av.R` — 4-year windowed AV
**Recommendation: Implement this before any model training.** `career_av` systematically overstates AV for older classes (more career seasons = more AV), which biases boom/bust labels.

Implementation:
- `scrape_player_av(pfr_id)`: `polite::bow()` + `rvest::read_html()` → parse Approximate Value table → filter to seasons 1–4 → sum
- Cache each player's HTML to `data/pfr_cache/` (avoids re-scraping on reruns)
- 3-second delay between requests (polite)
- Run overnight: ~3,750 players × 3s = ~3 hours
- Store result as `data/01b_av_4yr.rds`
- Update `01_load_data.R` to join this instead of using `career_av`

---

## Phase 3: Feature Engineering Validation

### 3a. Run `02_feature_engineering.R` against real data
- Check outcome distribution: expect ~15–20% boom, ~15–20% bust, ~60–70% expected
- Check group sample sizes (CLAUDE.md table: expect 300–600+ per group)
- Validate program pipeline feature computation — ensure leave-one-out is working (current player excluded from their own school window)

### 3b. Conference mapping
- Current implementation is a placeholder
- Minimum viable fix: map all schools to a conference using a static lookup table
- Recommended source: hand-build from `cfbfastR::cfbd_team_info()` or scrape Wikipedia's historical conference membership
- Include realignment handling: Texas → Big 12 through 2023, → SEC from 2024
- This affects `college_av_pctile` (currently a within-season percentile, not conference-adjusted)

---

## Phase 4: Model Training

### 4a. Run `03_model_spec.R`
- Verify recipes compile against actual feature names from `02_feature_engineering.R`
- Check that `position_in_group` levels are correct per group

### 4b. Run `04_train_evaluate.R`
- **XGBoost:** `tune_race_anova()`, 50-point grid, 10-fold CV — expect 30–90 min per group
- **TabPFN:** zero-shot forward pass — fast (seconds per group)
- **TabNet:** `tune_grid()`, 30-point grid — slowest; torch training
- Save `data/04_best_models.rds` and `output/model_comparison.csv`

### 4c. Calibration check
- Verify boom/bust probabilities are well-calibrated (not systematically over/under-confident)
- Plot predicted probability vs. actual outcome rate per bin
- If miscalibrated: add `probably::cal_estimate_isotonic()` calibration step

---

## Phase 5: 2026 Draft Scoring

### 5a. Source 2026 mock draft picks
- Pull consensus picks from 3–5 major mocks (The Athletic, ESPN, PFF, NFL.com)
- Build a `data/2026_mock_picks.csv` with player name, position, school, projected pick
- Assign `pick_bin` for expected AV baseline computation

### 5b. 2026 combine data validation
- `nflreadr::load_combine(seasons = 2026)` — check what's available (combine was in late February, data may be partially populated)
- Check for missing measurables per prospect; imputation will handle these but flag high-missingness players

### 5c. Run `05_predict_2026.R`
- Score all 2026 prospects with trained sub-models
- Output: `output/2026_predictions.csv` with player, position, school, pick, p_boom, p_bust, p_expected, verdict

---

## Phase 6: Pro Day Data Integration ✅ COMPLETE

- Source: MockDraftable.com open JSON API (NFLCombineResults blocked)
- `01e_scrape_pro_day.R`: two-phase slug resolution + batch fetch; file-cached
- Fill rate: ~10% of missing values recovered (~58 forty, ~144 bench, ~148 cone)
- `{measurable}_src` indicator features ("combine"/"pro_day"/"missing") in model
- Content angle: "Why pro day numbers lie" — Substack post material

---

## Phase 7: Diagnostics & Visualization (Makes It Come to Life)
*These make the model credible and content-ready.*

### 7a. Variable importance plots
- Horizontal bar charts per model group (top 15 features)
- Saved to `output/figures/`
- Shows: how much of QB evaluation is arm strength vs. college production vs. program pipeline

### 7b. Program pipeline leaderboard
- Which programs have the best 10-year track record by position group
- Immediately shows whether the novel feature is doing something meaningful
- Example output: "Alabama has produced 8 top-100 picks at WR/TE since 2015 with 37% boom rate"

### 7c. Calibration plots per model group
- Predicted probability vs. observed rate
- Shows model honesty

### 7d. Historical validation: notable hits/misses
- Apply trained model to 2015–2020 draft classes (in training data) and flag biggest prediction surprises
- Shows where the model diverges from draft position consensus — the most interesting content angle

---

## Execution Order

| Priority | Task | Status | Blocker? |
|----------|------|--------|----------|
| 1 | Phase 1: Environment setup | ✅ Done | — |
| 2 | Phase 2a–2b: Data load + fuzzy join | ✅ Done | — |
| 3 | Phase 2c: 01b PFR CSV ingestion | ✅ Done | — |
| 4 | Phase 3: Feature engineering | ✅ Done — college stats, YOY, domination, pro day src, team dev, speed score | — |
| 5 | Phase 6: Pro day integration | ✅ Done — MockDraftable API, src indicator features in model | — |
| 6 | Phase 5: 2026 scoring (05) | ✅ Done — player cards, SHAP, boom/bust probs | — |
| 7 | Phase 4: Model training | ✅ Done — XGB wins all 8; TabNet permanently disabled; TabPFN comparison complete | — |
| 8 | Phase 7a: Variable importance plots | ⏳ Post-draft — `output/variable_importance.csv` generated | No |
| 9 | Calibration check | ⏳ Post-draft | No |
| 10 | Conference mapping | ⏳ 2027 offseason — placeholder acceptable | No |
| 11 | Draft night re-run | ⏳ April 24 — re-run 05 with actual picks + actual drafting teams | No |

---

## Critical Files
- `00_config.R` — ✅ 8 model groups, RMSE thresholds, `canonicalize_college()` helper
- `01_load_data.R` — ✅ real 4yr AV, DB resolution, pro day hybrid coalesce + src columns
- `01b_scrape_av.R` — ✅ `data/01b_av_4yr.rds` (3,432 players)
- `01c_load_college_stats.R` — ✅ stats 2002–2025; exports `01c_player_stats_base.rds` for 05
- `01e_scrape_pro_day.R` — ✅ MockDraftable API, `data/01e_pro_day.rds` (cached)
- `02_feature_engineering.R` — ✅ all features: college pctiles, YOY, domination, team dev, speed_score_pctile, bmi_pctile
- `03_model_spec.R` — ✅ XGBoost + TabPFN + TabNet specs; updated shared_features
- `04_train_evaluate.R` — ✅ complete; RUN_TABNET=FALSE permanently; XGB wins all 8
- `05_predict_2026.R` — ✅ complete: combine + mock backfill, college stats C2, SHAP, player cards, Styles alias fix
- `content_front_seven_scatter.R` — ✅ EDGE sack specialist vs. broad disruptor scatter
- `feature_dictionary.md` — ✅ full feature reference (50+ features)

---

## Open Questions
1. **Mock picks source:** Build manually from consensus mocks (Jeremiah, Kiper, McShay + 2), or build a pick projection layer? (From memory: consensus from 5 analysts)
2. **Conference mapping:** Hand-build lookup from cfbfastR, or use a static CSV? Needs realignment handling (Texas → SEC 2024, etc.). Currently a placeholder in 02.
3. **TabPFN R API:** Session 1 confirmed TabPFN 7.0.0 installed in `nfl-tabpfn` Python virtualenv. Need to verify `tab_pfn()` function name and predict API in `04_train_evaluate.R` matches actual reticulate-backed interface.

---

## Pinned Investigation: TabPFN Combined-Position Run

**Status:** Pinned — investigate after per-group models complete

**Hypothesis:** TabPFN's zero-shot foundation model may benefit disproportionately from
a larger training sample. The 8-group sub-model architecture constrains each group to
300–600 rows; a combined-position run would give TabPFN ~3,400 rows. XGBoost and TabNet
are already tuned to work well at small-n, but TabPFN's in-context learning may scale
differently.

**Proposed approach:**
- Run TabPFN on all positions combined (single model, no group splits) as a **4th one-off
  run** — not a replacement for the 8-group architecture
- Use the same CV folds (restructured to span all groups) and same outcome metric
  (`av_residual_z`) for comparability
- Key design question: feature masking — position-inappropriate stats will be NA for most
  rows; confirm TabPFN handles this gracefully vs. needing a reduced feature set
- Compare RMSE/MAE against the per-group TabPFN weighted average (not per-group individually)

**Content angle:** "Does TabPFN get smarter with more data?" — if combined TabPFN beats
per-group TabPFN, that's a finding about foundation model scaling on small tabular datasets.
If it doesn't, that validates the sub-model architecture choice.

**Do not build until:** all 8 per-group models complete and `output/model_comparison.csv`
is populated.
