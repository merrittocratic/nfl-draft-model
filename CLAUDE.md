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

## Tech Stack
- **Modeling:** R + tidymodels + nflreadr + XGBoost + TabPFN + TabNet
- **Visualization:** Observable / D3.js for interactive content embeds
- **Automation:** Python + OpenClaw on Mac Mini M4 (separate from modeling machine)
- **Content:** X threads, Substack posts, data viz
- **LLM APIs available:** Claude, ChatGPT, Gemini (language-agnostic by design)
- **R over Python for modeling** — nflreadr/nflverse ecosystem is R-first and
  significantly more mature. Python is fine for automation/OpenClaw integration.

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

### 7 Tiered Sub-Models
| Group  | Positions | Rationale |
|--------|-----------|-----------|
| qb     | QB        | Unique evaluation features (passing production, arm metrics) |
| wr_te  | WR, TE    | Shared receiving/route-running evaluation DNA |
| dl     | EDGE, IDL | Pass rush production + athletic testing |
| ol     | OT, IOL   | Blocking metrics, fundamentally different from skill positions |
| db     | CB, S     | Coverage + ball production |
| lb     | LB        | Hybrid coverage + run defense |
| rb     | RB        | Rushing + receiving + athleticism |

**Rationale for groupings over fully separate models:** Data sparsity. Positions
like S (~180 total) and TE (~150) don't have enough observations for standalone
models with 15+ features. Groupings keep each sub-model at 300–600+ observations
while respecting fundamentally different evaluation criteria. Do NOT merge groups
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
1. **4-year AV scraper (01b):** Stub only. Need to scrape season-level AV from
   PFR using `pfr_player_id`. `career_av` from nflreadr overcounts for older
   classes. Use `rvest` + `polite`, cache HTML, respect rate limits. ~3,750
   players × 3s delay = ~2 hours.
2. **Combine join fuzziness:** `01_load_data.R` uses exact name match. Will break
   on Jr/Sr suffixes, hyphens, name formatting differences. Needs `fuzzyjoin` or
   string normalization.
3. **nflreadr column names:** Scripts assume column names that may not exactly match
   current nflreadr output. Run `01_load_data.R` first and inspect actual columns.
4. **TabPFN + TabNet integration:** Spec exists (see architecture above), needs
   implementation in `03_model_spec.R` and `04_train_evaluate.R`.
5. **College-to-conference mapping:** `02_feature_engineering.R` has a placeholder.
   Need a lookup table handling realignment (Texas → SEC 2024, etc.). Consider
   `cfbfastR` or manual build.
6. **2026 mock draft picks:** `05_predict_2026.R` needs projected picks. Source from consensus mocks or build pick projection layer.
7. **College production features:** Position-specific college stats not yet
   integrated. Would come from `cfbfastR` or manual sourcing.
8. **Pro day data integration (hybrid approach):** Combine non-participants
   have real measured data from college pro days that we're currently losing to
   imputation. Scrape pro day measurements from NFLCombineResults.com (or
   similar structured source), then implement a hybrid feature approach:
   - For each combine measurable, store the actual value (combine OR pro day)
   - Add a `{measurable}_source` indicator feature: "combine" / "pro_day" / "missing"
   - Let the model learn whether the data source matters (pro day 4.35 ≠ combine 4.35)
   - Only impute when BOTH combine and pro day are missing
   - Scraping task is similar to 01b: rvest + polite, cache HTML, respect rate limits
   - NFLCombineResults.com publishes per-position adjustment factors between
     combine and pro day — useful for validation but NOT used to adjust the raw
     values (the source indicator handles this instead)
   - Content angle: "Why pro day numbers lie" is a Substack post

---

## OpenClaw Automation Architecture (In Progress)

**Status:** Not yet set up. Architecture is an open design decision.

**Planned capabilities (phased):**
1. RSS feed monitoring (ESPN, The Athletic, PFF) → LLM summarization → draft
   insight summaries and social post drafts
2. X list monitoring → flag breaking draft news → auto-generate model-informed
   reaction drafts
3. Scheduled data refresh (nflreadr pull + model rescore) → push updated outputs

**Infrastructure:**
- OpenClaw runs on Mac Mini M4
- R model runs on a separate machine
- LLM APIs: Claude, ChatGPT, Gemini (project is language-agnostic for LLM calls)

**Output flow (OPEN DESIGN DECISION — do not lock in without discussion):**
Options under consideration:
- GitHub commits as both versioning and automation trigger
- GitHub for versioning/credibility, direct push (rsync/scp) for automation
- GitHub for versioning, shared cloud storage (S3/GCS) for automation trigger

Key constraints:
- Model outputs are **public** (transparency is the brand)
- Draft night latency target: **5–10 minutes** from model run to content draft
- Pre-draft automation (weeks 1–4) has looser latency requirements

**Do NOT build automation infrastructure without discussing the trigger/flow
pattern first.**

---

## Code Style
- tidyverse style: pipes, dplyr verbs, snake_case
- `cli::` for console output (`cli_h1`, `cli_alert_success`, `cli_alert_info`)
- Intermediate data: `.rds` in `data/`
- Final outputs: `.csv` in `output/`
- Comments explain *why*, not *what*

## Key Packages
tidyverse, tidymodels, nflreadr, xgboost, ranger, tabnet, tabpfn, finetune,
baguette, probably, glue, scales, cli, rvest, polite, fuzzyjoin, torch

## Do NOT
- Suggest switching to Python for the modeling pipeline
- Over-engineer the automation layer (that's a separate effort with open decisions)
- Add features without discussing data sparsity implications
- Merge position groups that have fundamentally different evaluation criteria
- Split position groups further without sample size analysis
- Lock in OpenClaw architecture decisions without explicit approval
- Silently change a locked-in decision — flag and pause instead
