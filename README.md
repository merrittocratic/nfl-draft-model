# NFL Draft Boom/Bust Model

A data-driven draft prospect evaluation model that predicts which NFL draft picks will outperform (boom) or underperform (bust) relative to their draft position.

Built with R + tidymodels + nflreadr.

## What Makes This Different

**Program pipeline features.** Most draft models treat college program as a flat variable. This model asks: *how good is this specific program at developing this specific position group?* Ohio State's WR factory has a very different track record than their QB pipeline — the model knows that.

- Rolling 10-year windows capture coaching and scheme changes
- Position-specific program success rates (not just overall program prestige)
- Conference-level strength adjustments

**Tiered sub-models.** Rather than forcing one model across all positions, we train 7 position-group-specific models that account for fundamentally different evaluation criteria:

| Model Group | Positions | Why Separate |
|---|---|---|
| QB | QB | Unique feature space (passing production, decision-making) |
| Pass Catchers | WR, TE | Shared receiving/route-running evaluation |
| Defensive Line | EDGE, IDL | Pass rush production + athletic testing |
| Offensive Line | OT, IOL | Blocking metrics, different from skill positions |
| Defensive Backs | CB, S | Coverage + ball production |
| Linebackers | LB | Hybrid coverage + run defense |
| Running Backs | RB | Rushing + receiving + athleticism |

**Three-way model comparison.** Each position group is evaluated with XGBoost (tuned tree baseline), TabPFN (zero-shot foundation model), and TabNet (attention-based deep learning). Same CV folds, same metrics.

## Methodology

**Outcome variable:** Draft-pick-adjusted Career Approximate Value (4-year window). We compute expected AV for each draft slot, then model the residual. This naturally accounts for draft position — a bust at pick 5 is different from a bust at pick 150.

**Boom/bust probabilities** are derived from the regression predictions by modeling prediction uncertainty around the predicted residual.

**Training data:** Draft classes 2006–2020 (~3,750 players) with combine measurables, college production, and career outcomes.

## Project Structure

```
R/
├── 00_config.R              # Constants, position mappings, packages
├── 01_load_data.R           # nflreadr data ingestion
├── 01b_scrape_av.R          # PFR scraper for 4-year windowed AV (TODO)
├── 02_feature_engineering.R # Program pipeline features, AV residuals
├── 03_model_spec.R          # tidymodels recipes + XGBoost/TabPFN/TabNet specs
├── 04_train_evaluate.R      # Three-way training loop, CV evaluation
└── 05_predict_2026.R        # Score 2026 draft class

data/                        # Intermediate .rds files (gitignored)
output/                      # Model results, player cards, figures
```

## Quick Start

```r
# Run in order:
source("R/01_load_data.R")
source("R/02_feature_engineering.R")
source("R/03_model_spec.R")
source("R/04_train_evaluate.R")
source("R/05_predict_2026.R")
```

Requires: `tidyverse`, `tidymodels`, `nflreadr`, `xgboost`, `tabpfn`, `tabnet`, `torch`, `finetune`, `baguette`, `probably`, `ranger`, `glue`, `scales`, `cli`

## Content

Analysis and deep dives at [Merrittocracy on Substack](https://themerrittocracy.substack.com).
Quick takes and data viz on [X @Merrittocratic](https://x.com/Merrittocratic).

## License

MIT
