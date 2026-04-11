# NFL Draft Boom/Bust Model

## Project Summary
NFL Draft prospect evaluation model predicting boom/bust probabilities relative
to draft position. Built for content publication on X (@Merrittocratic) and
Substack (themerrittocracy.substack.com). Initial launch targets the 2026 NFL
Draft, but the project is the foundation for a broader sports analytics brand
(Merrittocracy).

## Who You're Working With
Merrittocracy is run by a director-level data scientist with deep R expertise
(tidymodels, Shiny, dplyr) and strong NFL domain knowledge. Day job is
healthcare analytics — this project is fully separate. Preferences:
- Concise, direct responses — no fluff
- Merrittocracy handles domain judgment calls; you handle boilerplate and
  implementation
- When in doubt on architecture decisions: **ask before proceeding**
- When in doubt on implementation details: **make reasonable assumptions, note
  them, keep moving**
- If you disagree with a locked-in decision below: **flag the concern and pause
  for input** — do not silently proceed with the documented approach or
  unilaterally change direction

## Experimentation Mindset
This is a side project and the goal is to push envelopes, try new things, and
have fun. **Do not raise timeline concerns or ask about deadlines until we are
less than 1 week from the draft (April 17, 2026).** Until then: innovate
aggressively, experiment freely, and propose bold ideas. If something is
interesting, try it. If something might work, build it. The spirit is
"f*** shit up and have fun" — not ship-safe and conservative.

## Tech Stack
- **Modeling:** R + tidymodels + nflreadr + XGBoost + TabPFN + TabNet
- **Visualization:** Observable / D3.js for interactive content embeds
- **Content:** X threads, Substack posts, data viz
- **LLM APIs available:** Claude, ChatGPT, Gemini (language-agnostic by design)
- **R over Python for modeling** — nflreadr/nflverse ecosystem is R-first and
  significantly more mature. Python is not part of the current project scope.
- **Automation (future/separate):** OpenClaw on Mac Mini M4 is planned for a
  future content automation project. It is not part of the 2026 draft model.

---

## Architecture Decisions (Locked In)

### Outcome Variable
- **Primary:** Draft-pick-adjusted Career Approximate Value (4-year window)
- Compute expected AV per pick bin using historical averages, model the residual
  (actual AV minus expected AV)
- **Classification labels** derived from regression output:
  - Boom: standardized residual > 1
  - Bust: standardized residual < -1
  - Expected: everything else
- **Rationale:** Regression-first gives more flexibility to define thresholds
  after the fact and produces richer output for content than pure classification

### 8 Tiered Sub-Models
| Group  | Positions   | n (train) | Rationale |
|--------|-------------|-----------|-----------|
| qb     | QB          | —         | Unique evaluation features (passing production, arm metrics) |
| wr_te  | WR, TE      | —         | Shared receiving/route-running evaluation DNA |
| dl     | EDGE, IDL   | —         | Pass rush production + athletic testing |
| ol     | OT, IOL     | —         | Blocking metrics, fundamentally different from skill positions |
| cb     | CB          | ~162      | Split from S — high bust rate (~14%), hard to evaluate, scheme-dependent |
| s      | S, FS, SS   | ~545      | Split from CB — safer pick profile (~12% boom, ~8% bust), athleticism-driven |
| lb     | LB          | —         | Hybrid coverage + run defense |
| rb     | RB          | —         | Rushing + receiving + athleticism |

**CB/S split rationale:** Outcome profiles are meaningfully different — CBs bust
at nearly 3x their boom rate; Safeties are net positive. Combining them masked
signal. Sample sizes support the split (S=545, CB=162). CB's small n is
acceptable for tree models and TabPFN specifically. Also a strong content angle:
CB is the riskiest first-round position.

**Rationale for groupings over fully separate models:** Data sparsity. Positions
like TE (~150 total) don't have enough observations for standalone models with
15+ features. Groupings keep each sub-model at 300–600+ observations while
respecting fundamentally different evaluation criteria. Do NOT merge groups
that have different feature spaces, and do NOT split groups further without
discussing the sample size implications.

### Program Pipeline Features (Novel Differentiator)
- Rolling **10-year window** of program-by-position-group draft outcomes
- Leave-one-out computation to prevent leakage
- Features: `prog_pos_n`, `prog_pos_av_mean`, `prog_pos_boom_rate`,
  `prog_pos_bust_rate`, `prog_pos_avg_pick`, `prog_all_n`, `prog_all_av_mean`,
  `prog_all_boom_rate`
- **Rationale for 10-year window:** Coaching changes and scheme evolution matter.
  Saban's Alabama WR pipeline ≠ Shula's Alabama. All-time history would dilute
  the signal from current program quality. This is the project's primary novel
  angle — most public draft models treat college program as a flat categorical.

### Three-Way Model Comparison
The project runs a three-way comparison on the same CV folds and metrics:

| Model   | Package        | Role | Tuning |
|---------|----------------|------|--------|
| XGBoost | `xgboost`      | Tried-and-true tree model, primary baseline | `tune_race_anova()`, 50-point space-filling grid |
| TabPFN  | `tabpfn`       | Foundation model for tabular data (zero-shot) | None — single forward pass, no hyperparameters |
| TabNet  | `tabnet`       | Attention-based deep learning with interpretability | `tune_grid()`, 30-point grid |

- **TabPFN** uses `reticulate` under the hood — requires Python virtual environment
- **TabNet** supports self-supervised pre-training on all positions before
  fine-tuning per group (helps with small group sizes)
- TabNet attention maps are content-valuable ("here's what the model focuses on
  when evaluating this QB")
- The comparison itself is a Substack post. If TabPFN beats tuned XGBoost with
  zero tuning on NFL data — that's a headline.

### Training Data
- Draft classes 2006–2020 (~3,750 players)
- 4-year AV window for outcome labeling
- Combine measurables + college production + draft context + program pipeline

---

## Pipeline (Run in Order)
```
R/00_config.R              # Constants, packages, position mappings
R/01_load_data.R           # nflreadr ingestion, draft + combine join
R/01b_scrape_av.R          # PFR scraper for 4-year windowed AV (TODO)
R/02_feature_engineering.R # Program pipeline features, AV residuals, composites
R/03_model_spec.R          # tidymodels recipes, XGBoost/RF/TabNet specs, grids
R/04_train_evaluate.R      # Training loop, CV eval, variable importance
R/05_predict_2026.R        # Score 2026 draft class, generate player cards
```

## Known Issues / TODOs (Priority Order)
1. **TabPFN integration:** No official R package exists — interface is via
   `reticulate` directly. `tab_pfn()` in `04_train_evaluate.R` is aspirational
   and needs replacement. Confirmed approach: manual CV loop (`run_tabpfn_cv()`)
   outside tidymodels, using the same folds as XGBoost/TabNet. Smoke test first:
   `reticulate::import("tabpfn"); names(tabpfn)` — confirm `TabPFNRegressor`
   is exported before building the wrapper.
   **Future (post-draft):** Consider Option B — register TabPFN as a custom
   parsnip engine for full tidymodels integration. Deferred due to April 24
   deadline and parsnip registration complexity.
2. **College-to-conference mapping:** `02_feature_engineering.R` has a placeholder.
   Need a lookup table handling realignment (Texas → SEC 2024, etc.). Consider
   `cfbfastR` or manual build.
3. **2026 mock draft picks:** `05_predict_2026.R` needs projected picks. Consensus
   from 5 analysts (Jeremiah, Kiper, McShay + 2). Build `data/2026_mock_picks.csv`.
4. **College production features:** Position-specific college stats not yet
   integrated. Would come from `cfbfastR` or manual sourcing.
8. **Pro day data integration (hybrid approach):** Combine non-participants
   have real measured data from college pro days that we're currently losing to
   imputation. **Source confirmed: NFLCombineResults.com** — no Cloudflare, plain
   Apache/PHP, no bot protection. URL structure:
   `https://nflcombineresults.com/nflcombinedata.php?year=YYYY&pos=POS&college=0`
   Pro day values displayed in italics (`<i>` tags in HTML) — source detection
   is native from the HTML, no name matching required.
   - Script: `01e_scrape_pro_day.R` — loop year × position, parse table, flag italics
   - For each combine measurable, store the actual value (combine OR pro day)
   - Add a `{measurable}_source` indicator feature: "combine" / "pro_day" / "missing"
   - Let the model learn whether the data source matters (pro day 4.35 ≠ combine 4.35)
   - Only impute when BOTH combine and pro day are missing
   - Do NOT use the site's "Adjust Pro Day Scores" checkbox — want raw values
   - Coverage gap: 645 players (17%) missing forty time, 1,309 missing bench
   - Content angle: "Why pro day numbers lie" is a Substack post
9. **Social media risk signal (future model feature):** Explore whether prospect
   social media behavior is a predictive signal for bust probability — specifically
   "peak physical condition" content (heavy lift videos, physique posts) posted
   close to the draft. Hypothesis: conspicuous peak-condition signaling correlates
   with injury risk in early NFL career (Barkley, Chubb as recent examples; Henry
   as the durability outlier). Best sources are Instagram and YouTube (public,
   accessible) rather than X (API now $100–$500/month, post-2023 pricing) or
   Discord (no public API, server-gated). Signal extraction would require LLM-based
   image/video classification. **Do not build before 2026 draft — this is a
   2027-model enhancement.**

---

## OpenClaw Automation Architecture (Future Project — Not 2026 Draft)

**Status:** Mac Mini M4 is on order. OpenClaw will not be running before the
2026 draft. Do not build toward this architecture in the current project.

This is a planned capability for **future content series** (post-draft). When
the time comes, the design decisions below will need to be revisited:

**Planned capabilities (future):**
1. RSS feed monitoring → LLM summarization → draft insight summaries
2. X list monitoring → flag breaking news → model-informed reaction drafts
3. Scheduled data refresh → push updated outputs

**Output flow (OPEN — do not lock in without explicit discussion):**
- GitHub commits as both versioning and automation trigger
- GitHub for versioning, direct push (rsync/scp) for automation
- GitHub for versioning, shared cloud storage (S3/GCS) for automation trigger

**Do NOT build any automation infrastructure for the 2026 draft project.**

---

## Git Hygiene
Binary outputs (figures, model files) are never committed — they're regenerated from scripts.
When creating new output types, add them to `.gitignore` before committing:
- `output/figures/` — `*.png`, `*.jpg`, `*.svg`
- `output/models/` — `*.rds`
- `data/` — `*.rds`, `*.csv` (raw and intermediate data)

## Code Style
- tidyverse style: pipes, dplyr verbs, snake_case
- `cli::` for console output (`cli_h1`, `cli_alert_success`, `cli_alert_info`)
- Intermediate data: `.rds` in `data/`
- Final outputs: `.csv` in `output/`
- Comments explain *why*, not *what*

## Key Packages
tidyverse, tidymodels, nflreadr, xgboost, ranger, tabnet, tabpfn, finetune,
baguette, probably, glue, scales, cli, rvest, polite, fuzzyjoin, torch

## Debugging Approach
When a fix fails twice in a row, stop iterating on the same approach. Step back,
question the assumption, and consider whether the parameter/feature causing the
error should be simplified or removed entirely rather than patched. Ask the user
before attempting a third variation of the same fix.

## Pipe Compatibility — Base R `|>` vs magrittr `%>%`
This codebase uses base R `|>`. When writing or reviewing R code, scan for these
magrittr-only patterns that **silently fail or error** with `|>`:

- **`.` placeholder** — `|> set_names(map_chr(., ...))` → assign first, then call
- **`%>%` with `.` in non-first argument position** — e.g., `lm(y ~ x, data = .)`
- Any function where the pipe target needs to appear in a non-first argument

**Fix pattern:** Break the chain, assign the intermediate result, then pass it explicitly.

---

## Do NOT
- Suggest switching to Python for the modeling pipeline
- Build any automation infrastructure for the 2026 draft project
- Over-engineer toward future OpenClaw/Mac Mini architecture — that's a post-draft project
- Add features without discussing data sparsity implications
- Merge position groups that have fundamentally different evaluation criteria
- Split position groups further without sample size analysis
- Silently change a locked-in decision — flag and pause instead

---

## Building in Public Log

**IMPORTANT: Ask at the end of EVERY session, not just when something feels notable.**
The user has flagged this as easy to forget. Do not wait to be asked — proactively
prompt at natural stopping points (end of session, after a major decision, after an
unexpected finding):

> "Any candidates for the building in public log?"

The log lives at `/Users/stephenmerritt/content/draft/building_in_public_log.md`.
Add a dated entry in this format:

```
## YYYY-MM-DD | Short title
- What we did/decided
- Why it's interesting to an audience
- Any context needed to write about it later
```

Good candidates: anything that would make a non-obvious Substack section or
tweet — not routine implementation, but decisions, tradeoffs, or surprises worth
showing readers. When in doubt, surface it and let the user decide.
