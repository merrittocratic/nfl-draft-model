# ============================================================================
# 03 — Model Specification
#   - Per-group tidymodels recipes
#   - XGBoost, Random Forest, TabNet specs
#   - TabPFN helper (no spec needed — zero-shot)
#   - Workflow map for all 8 sub-models
# ============================================================================
source("00_config.R")
library(tabnet)
library(torch)

draft_fe       <- read_rds("data/02_draft_features.rds")
shared_features <- read_rds("data/02_feature_names.rds")

# ============================================================================
# A) TRAINING DATA PREP
# ============================================================================

train_data <- draft_fe |>
  filter(
    season %in% DRAFT_YEARS_TRAIN,
    !is.na(av_residual_z)
  ) |>
  mutate(position_in_group = factor(position))

# Split by model group
# Note: base R |> doesn't support . placeholder (magrittr only), so assign first
model_groups <- train_data |>
  group_by(model_group) |>
  group_split()
model_groups <- set_names(model_groups, map_chr(model_groups, ~ unique(.x$model_group)))

cli::cli_h1("Model group sizes")
iwalk(model_groups, ~ cli::cli_alert_info("{.y}: {nrow(.x)} players"))

# ============================================================================
# B) RECIPE FACTORY
# ============================================================================

# local() creates a private environment that serializes WITH the function into
# 03_model_specs.rds. All three free variables (.combine_features, .shared_features,
# .seed) are bound inside that environment, so they're available in parallel
# worker sessions without needing 00_config.R to be sourced.
make_recipe <- local({
  .combine_features        <- combine_features
  .shared_features         <- shared_features
  # College pctile features derived from shared_features — avoids a separate RDS.
  # Excludes college_av_pctile (program pipeline feature, not college production).
  .college_pctile_features <- str_subset(shared_features, "_pctile$") |>
    setdiff("college_av_pctile")
  .seed                    <- SEED

  function(data) {
    recipe(av_residual_z ~ ., data = data |> select(
      av_residual_z,
      position_in_group,
      all_of(.shared_features)
    )) |>
      # NA indicators for college features — created BEFORE imputation so they
      # capture true missingness. _NA = 1 means either coverage gap or no match.
      # XGBoost uses these alongside the era flags to distinguish "unknown" from
      # "no production." Must precede step_impute_* on college features.
      step_indicate_na(any_of(.college_pctile_features)) |>
      step_impute_bag(
        all_of(.combine_features),
        trees    = 25,
        seed_val = .seed
      ) |>
      step_impute_median(starts_with("prog_")) |>
      step_impute_median(college_av_pctile) |>
      # College pctile NAs are intentional: XGBoost handles them natively and the
      # step_indicate_na() indicators above already encode missingness as a signal.
      # Imputing to 0.5 creates spurious "real vs imputed" splits (artifact).
      # TabNet requires complete data — use make_tabnet_recipe() instead.
      step_mutate(
        missing_forty     = as.integer(is.na(forty)),
        missing_bench     = as.integer(is.na(bench)),
        missing_agility   = as.integer(is.na(cone) & is.na(shuttle)),
        is_underclassman  = as.integer(is_underclassman),
        pass_coverage_era = as.integer(pass_coverage_era),
        def_coverage_era  = as.integer(def_coverage_era)
      ) |>
      step_unknown(conf_tier, new_level = "unknown") |>  # NA → "unknown" level
      step_novel(conf_tier) |>                           # handle unseen levels in 2026
      step_dummy(position_in_group, conf_tier) |>        # dummy-encode before zv check
      step_zv(all_predictors()) |>                       # drops constant dummies too
      # No step_normalize for XGBoost — trees are scale-invariant; normalization
      # only distorts step_nzv evaluation (binary indicators look near-zero-variance)
      step_nzv(all_predictors(), freq_cut = 50, unique_cut = 5)
      # Relaxed thresholds vs defaults (95/5, 10): default drops informative binary
      # features in small groups (CB n=162, QB n~150) where rare categories are real signal
  }
})

# TabNet requires all NAs to be imputed (no native NA handling in torch).
# This wraps make_recipe() and appends median imputation for college pctile features.
# XGBoost uses make_recipe() directly — NAs left in place for native handling.
make_tabnet_recipe <- local({
  .college_pctile_features <- str_subset(shared_features, "_pctile$") |>
    setdiff("college_av_pctile")

  function(data) {
    make_recipe(data) |>
      step_impute_median(any_of(.college_pctile_features)) |>
      step_normalize(all_numeric_predictors())  # TabNet requires scaling; XGBoost does not
  }
})

# ============================================================================
# C) MODEL SPECS
# ============================================================================

# -- XGBoost (primary baseline) -----------------------------------------------
xgb_spec <- boost_tree(
  trees      = tune(),
  tree_depth = tune(),
  learn_rate = tune(),
  min_n      = tune(),
  loss_reduction = tune(),
  sample_size    = tune(),
  mtry           = tune()
) |>
  set_engine("xgboost",
             nthread = 1,   # 1 per worker — parallelism is at fold level via doFuture
             counts = FALSE
  ) |>
  set_mode("regression")

# -- Random Forest (backup) ---------------------------------------------------
rf_spec <- rand_forest(
  trees = 1000,
  mtry  = tune(),
  min_n = tune()
) |>
  set_engine("ranger",
             importance  = "impurity",
             num.threads = 1   # 1 per worker — parallelism is at fold level via doFuture
  ) |>
  set_mode("regression")

# -- TabNet (attention-based deep learning) ------------------------------------
# Requires: library(tabnet); library(torch)
# TabNet plugs directly into tidymodels workflow
tabnet_spec <- tabnet(
  epochs          = tune(),
  batch_size      = 128L,
  decision_width  = tune(),
  attention_width = tune(),
  num_steps       = tune(),
  penalty         = 0.000001,
  learn_rate      = tune(),
  momentum        = 0.6
) |>
  set_engine("torch") |>
  set_mode("regression")

# ============================================================================
# D) TUNING GRIDS
# ============================================================================

xgb_grid <- grid_space_filling(
  trees(range = c(300, 1500)),
  tree_depth(range = c(3, 8)),
  learn_rate(range = c(-3, -1.2)),
  min_n(range = c(5, 40)),
  loss_reduction(range = c(-3, 1)),
  sample_size = sample_prop(range = c(0.5, 0.9)),
  mtry = mtry_prop(range = c(0.3, 0.8)),
  size = 75
)

rf_grid <- grid_space_filling(
  mtry = mtry_prop(range = c(0.3, 0.8)),
  min_n(range = c(5, 30)),
  size = 20
)

tabnet_grid <- grid_space_filling(
  epochs(range = c(50L, 200L)),
  decision_width(range = c(8L, 64L)),
  attention_width(range = c(8L, 64L)),
  num_steps(range = c(3L, 7L)),
  learn_rate(range = c(-3, -1.5)),
  size = 30
)

# ============================================================================
# E) RESAMPLING STRATEGY
# ============================================================================

# 10-fold CV, stratified by outcome class
# local() captures shared_features in the closure for consistency with make_recipe
make_folds <- local({
  .shared_features <- shared_features

  function(group_data) {
    vfold_cv(
      group_data |> select(av_residual_z, position_in_group,
                            all_of(.shared_features), outcome_class),
      v       = 10,
      strata  = outcome_class,
      repeats = 1
    )
  }
})

# ============================================================================
# F) EVALUATION METRICS
# ============================================================================

draft_metrics <- metric_set(rmse, rsq, mae)

# ============================================================================
# G) SAVE SPECS
# ============================================================================

write_rds(
  list(
    model_groups        = model_groups,
    make_recipe         = make_recipe,
    make_tabnet_recipe  = make_tabnet_recipe,
    make_folds          = make_folds,
    xgb_spec            = xgb_spec,
    rf_spec             = rf_spec,
    tabnet_spec         = tabnet_spec,
    xgb_grid            = xgb_grid,
    rf_grid             = rf_grid,
    tabnet_grid         = tabnet_grid,
    draft_metrics       = draft_metrics,
    shared_features     = shared_features
  ),
  "data/03_model_specs.rds"
)

cli::cli_alert_success("Model specs saved to data/03_model_specs.rds")
cli::cli_alert_info("8 model groups × 3 algorithms (XGB + TabPFN + TabNet) = 24 workflow candidates")
