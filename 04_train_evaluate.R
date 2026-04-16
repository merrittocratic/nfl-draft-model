# ============================================================================
# 04 — Train & Evaluate All Sub-Models
#   - XGBoost: tune_race_anova() per model group
#   - TabPFN: zero-shot (no tuning, manual CV loop)
#   - TabNet: tune_grid() per model group
#   - Compare all three on same CV folds
#   - Extract variable importance + TabNet attention maps
# ============================================================================
source("00_config.R")
library(callr)     # TabPFN runs in isolated subprocess to avoid R torch / Python torch symbol conflict
library(tabnet)
library(torch)
library(doFuture)  # parallel CV folds for XGBoost

# MPS disabled — tabnet nn_module operations are not fully compatible with
# Apple MPS backend; all TabNet training runs on CPU
# Revisit after tabnet/torch MPS support matures

# TabNet result (2026-04-14, full overnight run with early stopping + grid=15):
# RMSE ranged 1.36–2.08 across all 8 groups — worse than null model (1.0) on every group.
# XGBoost wins all 8. TabNet is not competitive on this dataset at these sample sizes.
# Root causes: small n (162–600/group), high NA rate in college features, attention
# mechanism ill-suited to sparse tabular data with many structural zeros.
# Keeping FALSE permanently. Re-evaluate only if n or feature density increases substantially.
RUN_TABNET <- FALSE

# Parallel backend for XGBoost CV (CPU-based, safe to parallelize)
# Note: NOT applied to TabNet — torch + multiprocess forks crash on Mac
registerDoFuture()
plan(multisession, workers = max(1, parallel::detectCores() - 2))
cli::cli_alert_info("Parallel backend: {parallel::detectCores() - 2} workers for XGBoost CV")

specs <- read_rds("data/03_model_specs.rds")
list2env(specs, envir = environment())

# ============================================================================
# A) TRAINING LOOP
# ============================================================================

cli::cli_h1("Training {length(model_groups)} sub-models × 3 algorithms")

results <- list()
best_models <- list()

for (group_name in names(model_groups)) {
  cli::cli_h2("Training: {group_name} (n = {nrow(model_groups[[group_name]])})")

  group_data <- model_groups[[group_name]]
  folds      <- make_folds(group_data)

  pred_data <- group_data |>
    select(av_residual_z, position_in_group, all_of(shared_features))

  # -----------------------------------------------------------------------
  # XGBoost — tune with racing
  # -----------------------------------------------------------------------
  cli::cli_alert_info("Tuning XGBoost...")

  xgb_wf <- workflow() |>
    add_recipe(make_recipe(group_data)) |>
    add_model(xgb_spec)

  xgb_tuned <- tune_race_anova(
    xgb_wf,
    resamples = folds,
    grid      = xgb_grid,
    metrics   = draft_metrics,
    control   = control_race(
      save_pred      = TRUE,
      verbose        = FALSE,
      pkgs           = c("xgboost"),
      parallel_over  = "resamples"
    )
  )

  xgb_best_rmse <- show_best(xgb_tuned, metric = "rmse", n = 1)
  cli::cli_alert_info("XGB best RMSE: {round(xgb_best_rmse$mean, 3)}")

  # Quality gate — abort if XGBoost can't beat the null model threshold.
  # Thresholds defined in 00_config.R (XGB_RMSE_THRESHOLDS).
  # Likely causes of failure: recipe bug, feature blowup, data join issue.
  xgb_threshold <- XGB_RMSE_THRESHOLDS[[group_name]]
  if (xgb_best_rmse$mean > xgb_threshold) {
    cli::cli_abort(c(
      "XGBoost quality gate FAILED for group {group_name}",
      "x" = "RMSE = {round(xgb_best_rmse$mean, 3)} exceeds threshold {xgb_threshold}",
      "i" = "Null model RMSE ~ 1.0. Check recipe, feature engineering, or data join.",
      "i" = "Adjust XGB_RMSE_THRESHOLDS in 00_config.R if threshold needs updating."
    ))
  }

  # -----------------------------------------------------------------------
  # TabPFN — zero-shot, manual CV via callr subprocess
  # Runs in isolated process to avoid R torch / Python torch symbol clash.
  # Comparison only — TabPFN is never used as the deployment model.
  # -----------------------------------------------------------------------
  cli::cli_alert_info("Running TabPFN (zero-shot, subprocess)...")

  tabpfn_preds <- tryCatch({
    map_dfr(folds$splits, function(split) {
      # Pre-bake recipe here so we pass plain matrices into the subprocess
      rec         <- prep(make_recipe(group_data), training = analysis(split))
      train_baked <- bake(rec, new_data = NULL)
      val_baked   <- bake(rec, new_data = assessment(split))

      train_x <- as.matrix(select(train_baked, -av_residual_z))
      train_y <- train_baked$av_residual_z
      val_x   <- as.matrix(select(val_baked,   -av_residual_z))
      val_y   <- val_baked$av_residual_z

      preds <- callr::r(
        function(train_x, train_y, val_x) {
          reticulate::use_virtualenv("nfl-tabpfn", required = TRUE)
          tabpfn <- reticulate::import("tabpfn")
          model  <- tabpfn$TabPFNRegressor()
          model$fit(train_x, train_y)
          as.numeric(model$predict(val_x))
        },
        args = list(train_x = train_x, train_y = train_y, val_x = val_x)
      )

      tibble(av_residual_z = val_y, .pred = preds)
    })
  }, error = function(e) {
    cli::cli_alert_warning("TabPFN subprocess failed: {conditionMessage(e)}")
    NULL
  })

  tabpfn_rmse <- if (!is.null(tabpfn_preds)) {
    rmse_vec(tabpfn_preds$av_residual_z, tabpfn_preds$.pred)
  } else {
    NA_real_
  }
  cli::cli_alert_info("TabPFN RMSE: {if (is.na(tabpfn_rmse)) 'failed' else round(tabpfn_rmse, 2)}")

  # -----------------------------------------------------------------------
  # TabNet — tune with grid search (skipped when RUN_TABNET = FALSE)
  # -----------------------------------------------------------------------
  if (RUN_TABNET) {
    cli::cli_alert_info("Tuning TabNet...")

    tabnet_wf <- workflow() |>
      add_recipe(make_tabnet_recipe(group_data)) |>
      add_model(tabnet_spec)

    tabnet_tuned <- tune_grid(
      tabnet_wf,
      resamples = folds,
      grid      = tabnet_grid,
      metrics   = draft_metrics,
      control   = control_grid(save_pred = TRUE, allow_par = FALSE)
    )

    tabnet_best_rmse <- tryCatch({
      show_best(tabnet_tuned, metric = "rmse", n = 1)
    }, error = function(e) {
      cli::cli_alert_warning("TabNet tuning failed: {conditionMessage(e)}")
      cli::cli_alert_info("Run show_notes(.Last.tune.result) for details")
      tibble(mean = NA_real_)
    })
    cli::cli_alert_info("TabNet best RMSE: {if (is.na(tabnet_best_rmse$mean)) 'failed' else round(tabnet_best_rmse$mean, 2)}")
  } else {
    cli::cli_alert_info("TabNet skipped (RUN_TABNET = FALSE)")
    tabnet_best_rmse <- tibble(mean = NA_real_)
  }

  # -----------------------------------------------------------------------
  # Select winner across all three (comparison) and best deployable (XGB/TabNet)
  # TabPFN is benchmark-only — final model always comes from XGBoost or TabNet
  # so it can be stored as a tidymodels workflow and used in 05_predict_2026.R
  # -----------------------------------------------------------------------
  comparison <- tibble(
    algorithm = c("xgboost", "tabpfn", "tabnet"),
    rmse      = c(xgb_best_rmse$mean, tabpfn_rmse, tabnet_best_rmse$mean)
  ) |>
    arrange(rmse)

  comparison_winner <- comparison$algorithm[1]
  deploy_winner <- comparison |>
    filter(algorithm != "tabpfn") |>
    slice(1) |>
    pull(algorithm)

  cli::cli_alert_success(
    "Comparison winner: {comparison_winner} | Deploy winner: {deploy_winner}"
  )

  # Finalize and fit the deployment model on full group data
  if (deploy_winner == "xgboost") {
    best_params <- select_best(xgb_tuned, metric = "rmse")
    final_wf    <- finalize_workflow(xgb_wf, best_params)
    final_fit   <- fit(final_wf, data = pred_data)
    cv_preds    <- collect_predictions(xgb_tuned, parameters = best_params)
  } else {
    best_params <- select_best(tabnet_tuned, metric = "rmse")
    final_wf    <- finalize_workflow(tabnet_wf, best_params)
    final_fit   <- fit(final_wf, data = pred_data)
    cv_preds    <- collect_predictions(tabnet_tuned, parameters = best_params)
  }

  # Store results
  results[[group_name]] <- list(
    xgb_tuned          = xgb_tuned,
    tabpfn_preds       = tabpfn_preds,
    tabnet_tuned       = tabnet_tuned,
    comparison         = comparison,
    comparison_winner  = comparison_winner,
    deploy_winner      = deploy_winner,
    best_params        = best_params,
    final_fit          = final_fit,
    cv_preds           = cv_preds
  )

  best_models[[group_name]] <- final_fit

  # Checkpoint — write after each group so a mid-run crash doesn't lose everything.
  # bundle() re-serializes XGBoost's C++ pointer so models survive across R sessions.
  write_rds(results,                          "data/04_checkpoint_results.rds")
  write_rds(map(best_models, bundle::bundle), "data/04_checkpoint_best_models.rds")
  cli::cli_alert_success("{group_name} complete — checkpoint saved")
}

# ============================================================================
# B) THREE-WAY PERFORMANCE SUMMARY
# ============================================================================
cli::cli_h1("Three-Way Model Comparison")

perf_summary <- imap_dfr(results, function(res, group_name) {
  res$comparison |>
    mutate(model_group = group_name, .before = 1)
}) |>
  pivot_wider(names_from = algorithm, values_from = rmse,
              names_prefix = "rmse_")

print(perf_summary)
write_csv(perf_summary, "output/model_comparison.csv")

# Winner summary
winner_summary <- imap_dfr(results, function(res, group_name) {
  tibble(
    model_group       = group_name,
    comparison_winner = res$comparison_winner,
    deploy_winner     = res$deploy_winner,
    n_train           = nrow(model_groups[[group_name]]),
    best_rmse         = res$comparison$rmse[1]
  )
})

print(winner_summary)

# ============================================================================
# C) VARIABLE IMPORTANCE (XGBoost models)
# ============================================================================
cli::cli_h1("Variable Importance")

importance_all <- imap_dfr(results, function(res, group_name) {
  if (res$deploy_winner != "xgboost") return(tibble())

  fit_obj <- extract_fit_engine(res$final_fit)
  imp <- xgboost::xgb.importance(model = fit_obj)

  imp |>
    as_tibble() |>
    mutate(model_group = group_name) |>
    slice_head(n = 15)
})

write_csv(importance_all, "output/variable_importance.csv")

# ============================================================================
# D) TABNET ATTENTION MAPS (if TabNet won any groups)
# ============================================================================
cli::cli_h1("TabNet Attention Maps")

tabnet_attention <- imap(results, function(res, group_name) {
  if (res$deploy_winner != "tabnet") return(NULL)

  cli::cli_alert_info("Extracting attention for {group_name}")
  explain <- tabnet_explain(res$final_fit, model_groups[[group_name]])
  explain
})

# ============================================================================
# E) BOOM/BUST CLASSIFICATION FROM REGRESSION
# ============================================================================
cli::cli_h1("Deriving boom/bust probabilities")

classification_from_regression <- function(cv_preds, group_data) {
  resid_sd <- sd(group_data$av_residual_z, na.rm = TRUE)
  boom_threshold <-  1 * resid_sd
  bust_threshold <- -1 * resid_sd

  cv_preds |>
    mutate(
      pred_sd = sqrt(mean((av_residual_z - .pred)^2)),
      p_boom = pnorm(boom_threshold, mean = .pred, sd = pred_sd,
                     lower.tail = FALSE),
      p_bust = pnorm(bust_threshold, mean = .pred, sd = pred_sd,
                     lower.tail = TRUE),
      p_expected = 1 - p_boom - p_bust
    )
}

boom_bust_preds <- imap_dfr(results, function(res, group_name) {
  classification_from_regression(
    res$cv_preds,
    model_groups[[group_name]]
  ) |>
    mutate(model_group = group_name)
})

# Calibration check
boom_bust_preds |>
  mutate(actual_boom = av_residual_z > sd(av_residual_z, na.rm = TRUE)) |>
  mutate(p_boom_bin = cut(p_boom, breaks = seq(0, 1, 0.1))) |>
  group_by(p_boom_bin) |>
  summarise(
    predicted = mean(p_boom),
    actual    = mean(actual_boom),
    n         = n(),
    .groups   = "drop"
  ) |>
  print()

# ============================================================================
# F) SAVE EVERYTHING
# ============================================================================
write_rds(results,                         "data/04_tuning_results.rds")
write_rds(map(best_models, bundle::bundle), "data/04_best_models.rds")

cli::cli_alert_success("All models trained and saved")
cli::cli_alert_info("Next: Run R/05_predict_2026.R to score this year's class")
