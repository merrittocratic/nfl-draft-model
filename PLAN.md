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

**Next session starts here:**
1. **Source `01c_load_college_stats.R`** — verify match rates by group, fix any column name
   mismatches in cfbfastR API response, fix college name normalization gaps
2. **Update `02_feature_engineering.R`** — join college stats, derive position-specific
   features (qb_cmp_pct, qb_ypa, rush_ypc, rec_ypg, def_sacks_pg, etc.)
3. **Add college features to `00_config.R`** (`college_features` constant) and `03_model_spec.R`
4. **Re-run `02` → `03` → `04`** — expect meaningful RMSE improvement once college
   production features are in
5. **Check `04` checkpoint results** — if current run completed, evaluate group-level RMSEs
   before deciding whether to re-run or wait for college features
6. **Finish Downs article** — add Track Record section, find Saban quote, verify Berry
   Pro Bowl count, publish
7. **Source 2026 mock draft picks** → `data/2026_mock_picks.csv`
8. **Run `source("05_predict_2026.R")`**

---

## Context
The 2026 NFL Draft is April 24–26, 2026 (~30 days away). The pipeline code exists and is largely complete, but has never been run end-to-end against real data. The goal is to get the model producing accurate predictions for the 2026 draft class. Social media content is out of scope for now.

Key gaps blocking a working model:
1. ~~Environment not validated~~ — **RESOLVED**
2. ~~`career_av` proxy~~ — **RESOLVED**: true 4-year AV via PFR CSV exports (in progress)
3. ~~Column name mismatches in `01_load_data.R`~~ — **RESOLVED**
4. ~~Combine join fuzziness~~ — **RESOLVED**: fuzzyjoin implemented
5. ~~`ht` stored as string~~ — **RESOLVED**: converted to numeric inches in `02_feature_engineering.R`
6. **PFR CSV collection in progress** — 60 CSVs needed, drop in `data/pfr_av_raw/`
7. `01_load_data.R` needs update to join `01b_av_4yr.rds` once CSVs are collected
8. Conference mapping is a placeholder
9. 2026 mock draft picks not yet sourced

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

## Phase 6: Pro Day Data Integration (Enhancement)
*Do after baseline model is running. Strong content angle.*

From CLAUDE.md TODO #8:
- Scrape pro day measurements from NFLCombineResults.com (rvest + polite, same pattern as 01b)
- For each combine measurable: store actual value (combine OR pro day), add `{measurable}_source` indicator ("combine" / "pro_day" / "missing")
- Only impute when BOTH are missing
- Lets model learn whether data source matters (pro day 4.35 ≠ combine 4.35)
- Adds content angle: "Why pro day numbers lie"

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
| 3 | Phase 2c: 01b PFR CSV ingestion | ✅ Done — 60 CSVs, `01b_av_4yr.rds` generated | — |
| 4 | Update 01_load_data.R to join 01b output | ✅ Done — real 4yr AV wired, DB fix applied | — |
| 5 | Phase 3: Feature engineering validation | ✅ Done — position-specific log-pick curves, re-run with real AV + 8 groups | — |
| 6 | Fix 03_model_spec.R (7→8 group message) | ⏳ Next — trivial | No |
| 7 | Verify TabPFN R API in 04_train_evaluate.R | ⏳ Next — potential blocker | Yes for TabPFN |
| 8 | Phase 4: Model training (03 → 04) | ⏳ Not started | No (XGB/TabNet can run without TabPFN) |
| 9 | Source 2026 mock draft picks | ⏳ Not started | Yes for scoring |
| 10 | Phase 5: 2026 scoring (05) | ⏳ Not started | Needs mock picks + trained models |
| 11 | Phase 6: Pro day integration | ⏳ Not started | No — enhancement |
| 12 | Phase 7: Diagnostics + viz | ⏳ Not started | No — but high value |

---

## Critical Files
- `00_config.R` — ✅ clean, 8 model groups defined (cb/s split)
- `01_load_data.R` — ✅ real 4yr AV joined, DB resolution via combine pos
- `01b_scrape_av.R` — ✅ run, output exists (`data/01b_av_4yr.rds`)
- `02_feature_engineering.R` — ✅ position-specific log-pick curves, re-run; conference table still a placeholder
- `02b_feature_engineering.R` — ✅ new; cross-position pick bin baseline preserved for comparison → `data/02b_draft_features.rds`
- `03_model_spec.R` — ⚠️ minor: says "7 model groups" in final message; will auto-handle 8 groups from data
- `04_train_evaluate.R` — ⚠️ TabPFN API unverified; XGBoost + TabNet sections look correct
- `05_predict_2026.R` — ⚠️ DB routing for 2026 prospects uses combine pos directly (less of an issue); needs mock picks

---

## Open Questions
1. **Mock picks source:** Build manually from consensus mocks (Jeremiah, Kiper, McShay + 2), or build a pick projection layer? (From memory: consensus from 5 analysts)
2. **Conference mapping:** Hand-build lookup from cfbfastR, or use a static CSV? Needs realignment handling (Texas → SEC 2024, etc.). Currently a placeholder in 02.
3. **TabPFN R API:** Session 1 confirmed TabPFN 7.0.0 installed in `nfl-tabpfn` Python virtualenv. Need to verify `tab_pfn()` function name and predict API in `04_train_evaluate.R` matches actual reticulate-backed interface.
