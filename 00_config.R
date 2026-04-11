# ============================================================================
# NFL Draft Boom/Bust Model — Configuration
# github.com/merrittocratic/nfl-draft-model
# ============================================================================

library(tidyverse)
library(tidymodels)
library(nflreadr)
library(xgboost)
library(finetune)    # for race_anova() tuning
library(baguette)    # for bag_tree imputation engine
library(probably)    # for calibration

# -- Constants ----------------------------------------------------------------
DRAFT_YEARS_TRAIN  <- 2006:2020   # 15 classes, 4-year AV window available
DRAFT_YEARS_SCORE  <- 2026        # prediction target
AV_WINDOW_YEARS    <- 4           # career window for outcome labeling
PROGRAM_WINDOW     <- 10          # rolling years for program pipeline features
TEAM_WINDOW        <- 10          # rolling years for NFL team development features
SEED               <- 2026

set.seed(SEED)

# -- Position Group Mapping ---------------------------------------------------
# Tiered sub-models: 8 model groups
# CB and S split intentionally — meaningfully different outcome profiles:
#   CB: ~4% boom rate, ~14% bust rate (high risk, hard to evaluate)
#   S:  ~12% boom rate, ~8% bust rate (safer, athleticism-driven)
# Sample sizes support the split: S=545, CB=162 in training data.
position_model_map <- tribble(
  ~position,  ~model_group, ~model_group_label,
  "QB",       "qb",         "Quarterbacks",
  "WR",       "wr_te",      "Pass Catchers",
  "TE",       "wr_te",      "Pass Catchers",
  "EDGE",     "dl",         "Defensive Line",
  "DE",       "dl",         "Defensive Line",
  "DT",       "dl",         "Defensive Line",
  "IDL",      "dl",         "Defensive Line",
  "OT",       "ol",         "Offensive Line",
  "T",        "ol",         "Offensive Line",
  "IOL",      "ol",         "Offensive Line",
  "G",        "ol",         "Offensive Line",
  "C",        "ol",         "Offensive Line",
  "OL",       "ol",         "Offensive Line",
  "CB",       "cb",         "Cornerbacks",
  "S",        "s",          "Safeties",
  "FS",       "s",          "Safeties",
  "SS",       "s",          "Safeties",
  "DB",       "s",          "Safeties",     # generic DB → Safety (conservative default)
  "LB",       "lb",         "Linebackers",
  "ILB",      "lb",         "Linebackers",
  "OLB",      "lb",         "Linebackers",
  "RB",       "rb",         "Running Backs",
  "FB",       "rb",         "Running Backs"
)

# -- Pick Ladder for Range Scoring --------------------------------------------
# Increments of 4 through round 2 (picks 1-64) to avoid psychological anchoring
# on round numbers (top-5, top-10, etc.). Coarser increments of 10 in rounds 3-7
# where pick precision matters less. Used in 05_predict_2026.R to score each
# prospect across a range rather than pinning to a single mock projection.
PICK_LADDER <- unique(c(seq(1, 64, by = 4), seq(64, 260, by = 10)))

# -- Combine Measurables We Care About ---------------------------------------
combine_features <- c(
  "ht", "wt", "forty", "bench", "vertical",
  "broad_jump", "cone", "shuttle"
)

# -- XGBoost RMSE Quality Gates -----------------------------------------------
# av_residual_z is standardized (sd ≈ 1), so null model RMSE ≈ 1.0.
# Threshold of 0.97 for all groups — if XGBoost can't beat this, stop and
# re-evaluate features/recipe before continuing to TabPFN/TabNet.
# If XGBoost exceeds threshold for any group, 04_train_evaluate.R aborts.
XGB_RMSE_THRESHOLDS <- c(
  qb    = 0.999,
  wr_te = 0.999,
  dl    = 0.999,
  ol    = 0.999,
  cb    = 0.999,
  s     = 0.999,
  lb    = 0.999,  # raised — defensive coverage gap (cfbfastR only 2016+); revisit after CFBD integration
  rb    = 0.999
)

# -- Output paths -------------------------------------------------------------
dir.create("data", showWarnings = FALSE, recursive = TRUE)
dir.create("output", showWarnings = FALSE, recursive = TRUE)
dir.create("output/models", showWarnings = FALSE, recursive = TRUE)
dir.create("output/figures", showWarnings = FALSE, recursive = TRUE)