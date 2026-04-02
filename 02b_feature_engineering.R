# ============================================================================
# 02b — Feature Engineering (Cross-Position Pick Bin Baseline)
#
# Reproduces the ORIGINAL outcome variable using cross-position pick bin
# averages — intentionally NOT position-specific. Kept for comparison with
# the position-specific log-pick curve approach in 02_feature_engineering.R.
#
# Used by: content_1b_downs_positional_value.R → downs_positional_value_table_1.png
#
# Content angle: showing how the baseline choice changes the story —
# the cross-position benchmark suppresses S boom rates and inflates RB boom
# rates, which quietly argues against the Downs article's own thesis.
#
# Input:  data/01_draft_combined.rds
# Output: data/02b_draft_features.rds
# ============================================================================
source("00_config.R")

draft_combined <- read_rds("data/01_draft_combined.rds")

cli::cli_h1("02b — Cross-position pick bin baseline (comparison)")

# ============================================================================
# OUTCOME: Cross-position pick bin expected AV (original approach)
# ============================================================================

pick_av_baseline <- draft_combined |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(av_4yr)) |>
  mutate(
    pick_bin = case_when(
      pick <= 5   ~ "top5",
      pick <= 10  ~ "top10",
      pick <= 20  ~ "first_round_mid",
      pick <= 32  ~ "first_round_late",
      pick <= 50  ~ "second_early",
      pick <= 75  ~ "second_late_third",
      pick <= 100 ~ "third_fourth",
      pick <= 150 ~ "mid_rounds",
      pick <= 200 ~ "late_rounds",
      TRUE        ~ "end_of_draft"
    )
  ) |>
  group_by(pick_bin) |>
  summarise(
    expected_av    = mean(av_4yr, na.rm = TRUE),
    expected_av_sd = sd(av_4yr, na.rm = TRUE),
    n_players      = n(),
    .groups        = "drop"
  )

draft_fe_b <- draft_combined |>
  mutate(
    round_num = as.numeric(round),
    pick_bin = case_when(
      pick <= 5   ~ "top5",
      pick <= 10  ~ "top10",
      pick <= 20  ~ "first_round_mid",
      pick <= 32  ~ "first_round_late",
      pick <= 50  ~ "second_early",
      pick <= 75  ~ "second_late_third",
      pick <= 100 ~ "third_fourth",
      pick <= 150 ~ "mid_rounds",
      pick <= 200 ~ "late_rounds",
      TRUE        ~ "end_of_draft"
    )
  ) |>
  left_join(pick_av_baseline |> select(pick_bin, expected_av, expected_av_sd),
            by = "pick_bin") |>
  mutate(
    av_residual   = av_4yr - expected_av,
    av_residual_z = if_else(expected_av_sd > 0,
                            av_residual / expected_av_sd, 0),
    outcome_class = case_when(
      is.na(av_4yr)       ~ NA_character_,
      av_residual_z > 1   ~ "boom",
      av_residual_z < -1  ~ "bust",
      TRUE                ~ "expected"
    ) |> factor(levels = c("bust", "expected", "boom"))
  )

cli::cli_alert_success("Outcome distribution (training data):")
draft_fe_b |>
  filter(season %in% DRAFT_YEARS_TRAIN) |>
  count(outcome_class) |>
  print()

cli::cli_alert_info("Round 1 boom/bust by group (cross-position baseline):")
draft_fe_b |>
  filter(season %in% DRAFT_YEARS_TRAIN, round_num == 1, !is.na(outcome_class)) |>
  group_by(model_group) |>
  summarise(
    n         = n(),
    boom_pct  = mean(outcome_class == "boom"),
    bust_pct  = mean(outcome_class == "bust"),
    diff      = boom_pct - bust_pct,
    .groups   = "drop"
  ) |>
  arrange(desc(diff)) |>
  print()

write_rds(draft_fe_b, "data/02b_draft_features.rds")
cli::cli_alert_success("Saved data/02b_draft_features.rds")
