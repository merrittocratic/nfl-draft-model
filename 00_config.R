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
SEED               <- 2026

set.seed(SEED)

# -- Position Group Mapping ---------------------------------------------------
# Tiered sub-models: 7 model groups from 11 positions
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
  "CB",       "db",         "Defensive Backs",
  "S",        "db",         "Defensive Backs",
  "DB",       "db",         "Defensive Backs",
  "FS",       "db",         "Defensive Backs",
  "SS",       "db",         "Defensive Backs",
  "LB",       "lb",         "Linebackers",
  "ILB",      "lb",         "Linebackers",
  "OLB",      "lb",         "Linebackers",
  "RB",       "rb",         "Running Backs",
  "FB",       "rb",         "Running Backs"
)

# -- Combine Measurables We Care About ---------------------------------------
combine_features <- c(
  "ht", "wt", "forty", "bench", "vertical",
  "broad_jump", "cone", "shuttle"
)

# -- Output paths -------------------------------------------------------------
dir.create("data", showWarnings = FALSE, recursive = TRUE)
dir.create("output", showWarnings = FALSE, recursive = TRUE)
dir.create("output/models", showWarnings = FALSE, recursive = TRUE)
dir.create("output/figures", showWarnings = FALSE, recursive = TRUE)
