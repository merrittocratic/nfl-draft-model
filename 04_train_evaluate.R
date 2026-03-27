# ============================================================================
# 04 — Train & Evaluate All Sub-Models
#   - XGBoost: tune_race_anova() per model group
#   - TabPFN: zero-shot (no tuning, manual CV loop)
#   - TabNet: tune_grid() per model group
#   - Compare all three on same CV folds
#   - Extract variable importance + TabNet attention maps
# ============================================================================
source("00_config.R")
library(tabpfn)
library(tabnet)
library(torch)

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
    select(av_residual, position_in_group, all_of(shared_features))

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
      save_pred    = TRUE,
      verbose      = FALSE,
      pkgs         = c("xgboost")
    )
  )

  xgb_best_rmse <- show_best(xgb_tuned, metric = "rmse", n = 1)
  cli::cli_alert_info("XGB best RMSE: {round(xgb_best_rmse$mean, 2)}")

  # -----------------------------------------------------------------------
  # TabPFN — zero-shot, manual CV on same folds
  # -----------------------------------------------------------------------
  cli::cli_alert_info("Running TabPFN (zero-shot)...")

  tabpfn_preds <- map_dfr(folds$splits, function(split) {
    train_fold <- analysis(split)
    val_fold   <- assessment(split)

    # TabPFN: pass raw data, no recipe needed
    # It handles missing values and categoricals natively
    train_x <- train_fold |> select(all_of(shared_features))
    train_y <- train_fold$av_residual
    val_x   <- val_fold |> select(all_of(shared_features))

    mod <- tab_pfn(x = train_x, y = train_y)
    preds <- predict(mod, val_x)

    val_fold |>
      select(av_residual, outcome_class) |>
      bind_cols(preds)
  })

  tabpfn_rmse <- rmse_vec(tabpfn_preds$av_residual, tabpfn_preds$.pred)
  cli::cli_alert_info("TabPFN RMSE: {round(tabpfn_rmse, 2)}")

  # -----------------------------------------------------------------------
  # TabNet — tune with grid search
  # -----------------------------------------------------------------------
  cli::cli_alert_info("Tuning TabNet...")

  tabnet_wf <- workflow() |>
    add_recipe(make_recipe(group_data)) |>
    add_model(tabnet_spec)

  tabnet_tuned <- tune_grid(
    tabnet_wf,
    resamples = folds,
    grid      = tabnet_grid,
    metrics   = draft_metrics,
    control   = control_grid(save_pred = TRUE)
  )

  tabnet_best_rmse <- show_best(tabnet_tuned, metric = "rmse", n = 1)
  cli::cli_alert_info("TabNet best RMSE: {round(tabnet_best_rmse$mean, 2)}")

  # -----------------------------------------------------------------------
  # Select winner across all three
  # -----------------------------------------------------------------------
  comparison <- tibble(
    algorithm = c("xgboost", "tabpfn", "tabnet"),
    rmse      = c(xgb_best_rmse$mean, tabpfn_rmse, tabnet_best_rmse$mean)
  ) |>
    arrange(rmse)

  winner_name <- comparison$algorithm[1]
  cli::cli_alert_success("Winner: {winner_name} (RMSE: {round(comparison$rmse[1], 2)})")

  # Finalize and fit the winning model on full group data
  if (winner_name == "xgboost") {
    best_params <- select_best(xgb_tuned, metric = "rmse")
    final_wf    <- finalize_workflow(xgb_wf, best_params)
    final_fit   <- fit(final_wf, data = pred_data)
    cv_preds    <- collect_predictions(xgb_tuned, parameters = best_params)
  } else if (winner_name == "tabnet") {
    best_params <- select_best(tabnet_tuned, metric = "rmse")
    final_wf    <- finalize_workflow(tabnet_wf, best_params)
    final_fit   <- fit(final_wf, data = pred_data)
    cv_preds    <- collect_predictions(tabnet_tuned, parameters = best_params)
  } else {
    # TabPFN: fit on full group data (no workflow, just the model)
    best_params <- NULL
    final_fit   <- tab_pfn(
      x = group_data |> select(all_of(shared_features)),
      y = group_data$av_residual
    )
    cv_preds    <- tabpfn_preds
  }

  # Store results
  results[[group_name]] <- list(
    xgb_tuned      = xgb_tuned,
    tabpfn_preds   = tabpfn_preds,
    tabnet_tuned   = tabnet_tuned,
    comparison     = comparison,
    winner         = winner_name,
    best_params    = best_params,
    final_fit      = final_fit,
    cv_preds       = cv_preds
  )

  best_models[[group_name]] <- final_fit

  cli::cli_alert_success("{group_name} complete")
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
    model_group = group_name,
    winner      = res$winner,
    n_train     = nrow(model_groups[[group_name]]),
    best_rmse   = res$comparison$rmse[1]
  )
})

print(winner_summary)

# ============================================================================
# C) VARIABLE IMPORTANCE (XGBoost models)
# ============================================================================
cli::cli_h1("Variable Importance")

importance_all <- imap_dfr(results, function(res, group_name) {
  if (res$winner != "xgboost") return(tibble())

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
  if (res$winner != "tabnet") return(NULL)

  cli::cli_alert_info("Extracting attention for {group_name}")
  explain <- tabnet_explain(res$final_fit, model_groups[[group_name]])
  explain
})

# ============================================================================
# E) BOOM/BUST CLASSIFICATION FROM REGRESSION
# ============================================================================
cli::cli_h1("Deriving boom/bust probabilities")

classification_from_regression <- function(cv_preds, group_data) {
  resid_sd <- sd(group_data$av_residual, na.rm = TRUE)
  boom_threshold <-  1 * resid_sd
  bust_threshold <- -1 * resid_sd

  cv_preds |>
    mutate(
      pred_sd = sqrt(mean((av_residual - .pred)^2)),
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
  mutate(actual_boom = av_residual > sd(av_residual, na.rm = TRUE)) |>
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
write_rds(results, "data/04_tuning_results.rds")
write_rds(best_models, "data/04_best_models.rds")

cli::cli_alert_success("All models trained and saved")
cli::cli_alert_info("Next: Run R/05_predict_2026.R to score this year's class")
