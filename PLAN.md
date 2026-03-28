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

**Next session starts here:**
1. Finish collecting remaining 56 PFR CSVs (2007–2020 draft classes, 4 seasons each)
2. Run `source("01b_scrape_av.R")` — verify `av_4yr_total` distribution looks reasonable
3. Update `01_load_data.R` to join `data/01b_av_4yr.rds` on `pfr_id`, replace `av_4yr = w_av` with `av_4yr = av_4yr_total`
   - Verify join key: confirm `pfr_player_id` in nflreadr matches `Player-additional` slug from PFR
4. Re-run `02_feature_engineering.R` with true 4-year AV
5. Check outcome distribution (expect ~15–20% boom/bust)
6. Proceed to `03_model_spec.R` → `04_train_evaluate.R`

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
| 3 | Phase 2c: 01b PFR CSV ingestion | 🔄 In progress — collecting 60 CSVs | Yes for accurate labels |
| 4 | Update 01_load_data.R to join 01b output | ⏳ Waiting on CSVs | Yes |
| 5 | Phase 3: Feature engineering validation | 🔄 Partial — ran once with w_av, re-run needed after 01b | Yes |
| 6 | Phase 4: Model training | ⏳ Not started | Yes |
| 7 | Phase 5: 2026 scoring | ⏳ Not started | Needs mock picks |
| 8 | Phase 6: Pro day integration | ⏳ Not started | No — enhancement |
| 9 | Phase 7: Diagnostics + viz | ⏳ Not started | No — but high value |

---

## Critical Files
- `00_config.R` — ready to run
- `01_load_data.R` — needs column name validation + fuzzy join fix
- `01b_scrape_av.R` — needs full implementation
- `02_feature_engineering.R` — ready, needs conference table
- `03_model_spec.R` — ready to run
- `04_train_evaluate.R` — depends on package installs
- `05_predict_2026.R` — needs mock picks input

---

## Open Questions
1. **Mock picks source:** Build manually from consensus mocks (Jeremiah, Kiper, McShay + 2), or build a pick projection layer?
2. **Conference mapping:** Hand-build lookup from cfbfastR, or use a static CSV? Needs realignment handling (Texas → SEC 2024, etc.)
3. **01_load_data.R join key:** nflreadr draft picks have `pfr_player_id` — confirm this matches `Player-additional` slug from PFR exports before running 01b join.
