# ============================================================================
# 02 — Feature Engineering
#   - Draft-pick-adjusted AV residuals (outcome variable)
#   - Program pipeline features (rolling 10-year window)
#   - Composite athleticism scores
#   - Age and experience features
# ============================================================================
source("00_config.R")

draft_combined <- read_rds("data/01_draft_combined.rds")

# ============================================================================
# A) OUTCOME: Draft-Pick-Adjusted AV Residuals
#
# Approach: fit av_4yr ~ log(pick) + factor(round) separately per model group
# on training data. Expected AV is the fitted value from that curve; the
# residual measures how far above/below the position-specific curve a player
# landed. Standardize residuals within group to define boom/bust thresholds.
#
# Why per-group curves instead of cross-position pick bins:
#   QBs accumulate AV faster than OL; safeties drafted top-15 were being
#   benchmarked against QBs at the same slot, inflating the "expected" bar
#   and suppressing apparent S boom rates. Position-specific curves fix this.
#
# factor(round) captures the real step-function in draft structure (contract
# slots, roster guarantees) without needing arbitrary pick bin boundaries.
# ============================================================================
cli::cli_h1("Fitting position-group AV curves")

# model_group already joined in 01_load_data.R
draft_fe <- draft_combined |>
  mutate(
    round_num = as.numeric(round),
    log_pick  = log(pick)
  )

# Fit one curve per model group on training data
training_data <- draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(av_4yr), !is.na(model_group))

av_curve_models <- training_data |>
  group_by(model_group) |>
  group_split() |>
  set_names(map_chr(training_data |> group_by(model_group) |> group_split(),
                    ~ unique(.x$model_group))) |>
  map(~ lm(av_4yr ~ log_pick + factor(round_num), data = .x))

cli::cli_alert_info("AV curve model summaries:")
walk2(av_curve_models, names(av_curve_models), function(mod, grp) {
  cli::cli_alert_info(
    "{grp}: R²={round(summary(mod)$r.squared, 3)}, n={nrow(mod$model)}"
  )
})

# Generate fitted values (expected_av) for every player in the full dataset
# Players outside training years get predictions from the training-fit curves
draft_fe <- draft_fe |>
  group_by(model_group) |>
  group_modify(function(group_df, key) {
    grp <- key$model_group
    mod <- av_curve_models[[grp]]

    if (is.null(mod)) {
      return(group_df |> mutate(expected_av = NA_real_))
    }

    group_df |>
      mutate(expected_av = predict(mod, newdata = group_df))
  }) |>
  ungroup()

# Residuals and standardization within model group (training data drives the SD)
group_resid_sds <- draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(av_4yr)) |>
  group_by(model_group) |>
  summarise(
    resid_sd = sd(av_4yr - expected_av, na.rm = TRUE),
    .groups = "drop"
  )

draft_fe <- draft_fe |>
  left_join(group_resid_sds, by = "model_group") |>
  mutate(
    av_residual   = av_4yr - expected_av,
    av_residual_z = if_else(resid_sd > 0, av_residual / resid_sd, 0),
    outcome_class = case_when(
      is.na(av_4yr)       ~ NA_character_,
      av_residual_z > 1   ~ "boom",
      av_residual_z < -1  ~ "bust",
      TRUE                ~ "expected"
    ) |> factor(levels = c("bust", "expected", "boom"))
  )

cli::cli_alert_success("Outcome distribution (training data):")
draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN) |>
  count(outcome_class) |>
  print()

# ============================================================================
# B) PROGRAM PIPELINE FEATURES (Rolling 10-Year Window)
# ============================================================================
cli::cli_h1("Engineering program pipeline features")

# For each player, compute features about their college program's historical
# track record at developing their position group.
# CRITICAL: leave-one-out — exclude the player's own row.

compute_program_features <- function(data, target_season, target_college,
                                     target_model_group, exclude_pick = NULL) {
  window_start <- target_season - PROGRAM_WINDOW

  program_history <- data |>
    filter(
      season >= window_start,
      season < target_season,
      college == target_college,
      model_group == target_model_group,
      !is.na(av_4yr)
    )

  program_all <- data |>
    filter(
      season >= window_start,
      season < target_season,
      college == target_college,
      !is.na(av_4yr)
    )

  tibble(
    prog_pos_n           = nrow(program_history),
    prog_pos_av_mean     = if (nrow(program_history) > 0)
      mean(program_history$av_4yr, na.rm = TRUE) else NA_real_,
    prog_pos_av_median   = if (nrow(program_history) > 0)
      median(program_history$av_4yr, na.rm = TRUE) else NA_real_,
    prog_pos_boom_rate   = if (nrow(program_history) > 0)
      mean(program_history$outcome_class == "boom", na.rm = TRUE) else NA_real_,
    prog_pos_bust_rate   = if (nrow(program_history) > 0)
      mean(program_history$outcome_class == "bust", na.rm = TRUE) else NA_real_,
    prog_pos_avg_pick    = if (nrow(program_history) > 0)
      mean(program_history$pick, na.rm = TRUE) else NA_real_,
    prog_all_n           = nrow(program_all),
    prog_all_av_mean     = if (nrow(program_all) > 0)
      mean(program_all$av_4yr, na.rm = TRUE) else NA_real_,
    prog_all_boom_rate   = if (nrow(program_all) > 0)
      mean(program_all$outcome_class == "boom", na.rm = TRUE) else NA_real_
  )
}

cli::cli_alert_info("Computing program features (this may take a minute)...")

program_features <- draft_fe |>
  filter(!is.na(college), college != "") |>
  select(season, pick, college, model_group) |>
  pmap_dfr(function(season, pick, college, model_group) {
    feats <- compute_program_features(
      draft_fe, season, college, model_group
    )
    feats |> mutate(season = season, pick = pick)
  })

draft_fe <- draft_fe |>
  left_join(program_features, by = c("season", "pick"))

cli::cli_alert_success("Program features computed")

# ============================================================================
# C) COMPOSITE ATHLETICISM SCORES
# ============================================================================
cli::cli_h1("Computing composite athleticism scores")

# nflreadr returns ht as "6-2" strings — convert to numeric inches
draft_fe <- draft_fe |>
  mutate(ht = if_else(
    str_detect(ht, "-"),
    as.numeric(str_extract(ht, "^\\d+")) * 12 + as.numeric(str_extract(ht, "\\d+$")),
    suppressWarnings(as.numeric(ht))
  ))

# Position-relative z-scores (simplified RAS)
draft_fe <- draft_fe |>
  group_by(model_group) |>
  mutate(
    across(
      all_of(combine_features),
      list(z = ~ (. - mean(., na.rm = TRUE)) / sd(., na.rm = TRUE)),
      .names = "{.col}_z"
    )
  ) |>
  ungroup() |>
  rowwise() |>
  mutate(
    # For speed metrics, lower is better — flip sign
    athleticism_composite = mean(c(
      -forty_z,
      bench_z,
      vertical_z,
      broad_jump_z,
      -cone_z,
      -shuttle_z
    ), na.rm = TRUE),
    n_combine_tests = sum(!is.na(c_across(all_of(combine_features))))
  ) |>
  ungroup()

# ============================================================================
# D) AGE & EXPERIENCE FEATURES
# ============================================================================

draft_fe <- draft_fe |>
  mutate(
    draft_age = age,
    college_years = pmin(pmax(round(draft_age - 18), 1), 6),
    is_underclassman = college_years <= 3
    # log_pick and round_num already computed in section A
  )

# ============================================================================
# E) CONFERENCE STRENGTH FEATURES
# ============================================================================

# TODO: Build proper college-to-conference mapping with realignment dates
# For now, compute at college level
conference_strength <- draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(av_4yr), !is.na(college)) |>
  group_by(season) |>
  mutate(
    college_av_pctile = percent_rank(prog_all_av_mean)
  ) |>
  ungroup()

draft_fe <- draft_fe |>
  left_join(
    conference_strength |> select(season, pick, college_av_pctile),
    by = c("season", "pick")
  )

# ============================================================================
# F) FINAL FEATURE SELECTION
# ============================================================================

shared_features <- c(
  "log_pick", "round_num", "draft_age", "college_years", "is_underclassman",
  combine_features,
  "athleticism_composite", "n_combine_tests",
  "prog_pos_n", "prog_pos_av_mean", "prog_pos_av_median",
  "prog_pos_boom_rate", "prog_pos_bust_rate", "prog_pos_avg_pick",
  "prog_all_n", "prog_all_av_mean", "prog_all_boom_rate",
  "college_av_pctile"
)

write_rds(draft_fe, "data/02_draft_features.rds")
write_rds(shared_features, "data/02_feature_names.rds")

cli::cli_alert_success("Saved data/02_draft_features.rds ({nrow(draft_fe)} rows, {length(shared_features)} shared features)")

draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(av_residual)) |>
  group_by(model_group) |>
  summarise(
    n = n(),
    av_mean = mean(av_4yr, na.rm = TRUE),
    resid_mean = mean(av_residual, na.rm = TRUE),
    boom_pct = mean(outcome_class == "boom", na.rm = TRUE),
    bust_pct = mean(outcome_class == "bust", na.rm = TRUE),
    combine_pct = mean(n_combine_tests > 0, na.rm = TRUE),
    .groups = "drop"
  ) |>
  arrange(desc(n)) |>
  print()
