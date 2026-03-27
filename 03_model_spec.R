# ============================================================================
# 03 — Model Specification
#   - Per-group tidymodels recipes
#   - XGBoost, Random Forest, TabNet specs
#   - TabPFN helper (no spec needed — zero-shot)
#   - Workflow map for all 7 sub-models
# ============================================================================
source("00_config.R")

draft_fe       <- read_rds("data/02_draft_features.rds")
shared_features <- read_rds("data/02_feature_names.rds")

# ============================================================================
# A) TRAINING DATA PREP
# ============================================================================

train_data <- draft_fe |>
  filter(
    season %in% DRAFT_YEARS_TRAIN,
    !is.na(av_residual)
  ) |>
  mutate(position_in_group = factor(position))

# Split by model group
model_groups <- train_data |>
  group_by(model_group) |>
  group_split() |>
  set_names(map_chr(., ~ unique(.x$model_group)))

cli::cli_h1("Model group sizes")
iwalk(model_groups, ~ cli::cli_alert_info("{.y}: {nrow(.x)} players"))

# ============================================================================
# B) RECIPE FACTORY
# ============================================================================

make_recipe <- function(data) {
  recipe(av_residual ~ ., data = data |> select(
    av_residual,
    position_in_group,
    all_of(shared_features)
  )) |>
    step_impute_bag(
      all_of(combine_features),
      trees = 25,
      seed_val = SEED
    ) |>
    step_impute_median(starts_with("prog_")) |>
    step_impute_median(college_av_pctile) |>
    step_mutate(
      missing_forty   = as.integer(is.na(forty)),
      missing_bench   = as.integer(is.na(bench)),
      missing_agility = as.integer(is.na(cone) & is.na(shuttle))
    ) |>
    step_normalize(all_numeric_predictors()) |>
    step_dummy(position_in_group) |>
    step_nzv(all_predictors()) |>
    step_mutate(is_underclassman = as.integer(is_underclassman))
}

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
             nthread = parallel::detectCores() - 1,
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
             importance = "impurity",
             num.threads = parallel::detectCores() - 1
  ) |>
  set_mode("regression")

# -- TabNet (attention-based deep learning) ------------------------------------
# Requires: library(tabnet); library(torch)
# TabNet plugs directly into tidymodels workflow
tabnet_spec <- tabnet(
  epochs          = tune(),
  batch_size      = tune(),
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
  size = 50
)

rf_grid <- grid_space_filling(
  mtry = mtry_prop(range = c(0.3, 0.8)),
  min_n(range = c(5, 30)),
  size = 20
)

tabnet_grid <- grid_space_filling(
  epochs(range = c(50, 200)),
  batch_size(values = c(64, 128, 256)),
  decision_width(range = c(8, 64)),
  attention_width(range = c(8, 64)),
  num_steps(range = c(3, 7)),
  learn_rate(range = c(-3, -1.5)),
  size = 30
)

# ============================================================================
# E) RESAMPLING STRATEGY
# ============================================================================

# 10-fold CV, stratified by outcome class
make_folds <- function(group_data) {
  vfold_cv(
    group_data |> select(av_residual, position_in_group,
                          all_of(shared_features), outcome_class),
    v = 10,
    strata = outcome_class,
    repeats = 1
  )
}

# ============================================================================
# F) EVALUATION METRICS
# ============================================================================

draft_metrics <- metric_set(rmse, rsq, mae)

# ============================================================================
# G) SAVE SPECS
# ============================================================================

write_rds(
  list(
    model_groups    = model_groups,
    make_recipe     = make_recipe,
    make_folds      = make_folds,
    xgb_spec        = xgb_spec,
    rf_spec         = rf_spec,
    tabnet_spec     = tabnet_spec,
    xgb_grid        = xgb_grid,
    rf_grid         = rf_grid,
    tabnet_grid     = tabnet_grid,
    draft_metrics   = draft_metrics,
    shared_features = shared_features
  ),
  "data/03_model_specs.rds"
)

cli::cli_alert_success("Model specs saved to data/03_model_specs.rds")
cli::cli_alert_info("7 model groups × 3 algorithms (XGB + TabPFN + TabNet) = 21 workflow candidates")
