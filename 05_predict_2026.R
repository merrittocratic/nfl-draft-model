# ============================================================================
# 05 — Score 2026 Draft Class
#   - Load 2026 combine data + prospect info
#   - Apply trained sub-models
#   - Generate boom/bust probability scores
#   - Create content-ready outputs
# ============================================================================
source("00_config.R")

draft_fe    <- read_rds("data/02_draft_features.rds")
best_models <- read_rds("data/04_best_models.rds")
results     <- read_rds("data/04_tuning_results.rds")
shared_features <- read_rds("data/02_feature_names.rds")

# ============================================================================
# A) LOAD 2026 PROSPECTS
# ============================================================================
cli::cli_h1("Loading 2026 prospect data")

prospects_2026 <- load_combine(seasons = 2026) |>
  mutate(
    season = 2026L,
    position = case_when(
      pos %in% c("DE", "EDGE", "OLB") ~ "EDGE",
      pos %in% c("DT", "NT", "IDL")   ~ "IDL",
      pos %in% c("T", "OT")           ~ "OT",
      pos %in% c("G", "C", "OL")      ~ "IOL",
      pos %in% c("FS", "SS", "DB", "S") ~ "S",
      pos == "CB"                      ~ "CB",
      pos %in% c("ILB", "LB", "MLB")  ~ "LB",
      pos == "FB"                      ~ "RB",
      TRUE ~ pos
    )
  ) |>
  left_join(position_model_map |> distinct(position, model_group), by = "position") |>
  filter(!is.na(model_group))

# Compute program pipeline features for 2026 prospects
cli::cli_alert_info("Computing program features for 2026 class...")

prog_feats_2026 <- prospects_2026 |>
  select(season, player_name, school, model_group) |>
  pmap_dfr(function(season, player_name, school, model_group) {
    window_start <- season - PROGRAM_WINDOW

    program_history <- draft_fe |>
      filter(
        season >= window_start, season < 2026,
        college == school,
        model_group == !!model_group,
        !is.na(av_4yr)
      )

    program_all <- draft_fe |>
      filter(
        season >= window_start, season < 2026,
        college == school,
        !is.na(av_4yr)
      )

    tibble(
      player_name = player_name,
      prog_pos_n         = nrow(program_history),
      prog_pos_av_mean   = if (nrow(program_history) > 0)
        mean(program_history$av_4yr, na.rm = TRUE) else NA_real_,
      prog_pos_av_median = if (nrow(program_history) > 0)
        median(program_history$av_4yr, na.rm = TRUE) else NA_real_,
      prog_pos_boom_rate = if (nrow(program_history) > 0)
        mean(program_history$outcome_class == "boom", na.rm = TRUE) else NA_real_,
      prog_pos_bust_rate = if (nrow(program_history) > 0)
        mean(program_history$outcome_class == "bust", na.rm = TRUE) else NA_real_,
      prog_pos_avg_pick  = if (nrow(program_history) > 0)
        mean(program_history$pick, na.rm = TRUE) else NA_real_,
      prog_all_n         = nrow(program_all),
      prog_all_av_mean   = if (nrow(program_all) > 0)
        mean(program_all$av_4yr, na.rm = TRUE) else NA_real_,
      prog_all_boom_rate = if (nrow(program_all) > 0)
        mean(program_all$outcome_class == "boom", na.rm = TRUE) else NA_real_
    )
  })

prospects_2026 <- prospects_2026 |>
  left_join(prog_feats_2026, by = "player_name")

# ============================================================================
# B) SCORE FUNCTION
# ============================================================================

score_prospects <- function(prospect_data, mock_picks = NULL) {
  if (!is.null(mock_picks)) {
    prospect_data <- prospect_data |>
      left_join(mock_picks, by = "player_name") |>
      mutate(
        pick     = coalesce(mock_pick, pick),
        log_pick = log(pick),
        round_num = case_when(
          pick <= 32  ~ 1,
          pick <= 64  ~ 2,
          pick <= 100 ~ 3,
          pick <= 135 ~ 4,
          pick <= 176 ~ 5,
          pick <= 220 ~ 6,
          TRUE        ~ 7
        )
      )
  }

  scored <- prospect_data |>
    filter(!is.na(model_group)) |>
    group_by(model_group) |>
    group_split() |>
    map_dfr(function(group_df) {
      gname <- unique(group_df$model_group)
      model <- best_models[[gname]]

      if (is.null(model)) {
        cli::cli_alert_warning("No model for group: {gname}")
        return(group_df |> mutate(.pred = NA_real_))
      }

      # Handle TabPFN vs tidymodels workflow prediction
      if (inherits(model, "tabpfn")) {
        preds <- predict(model, group_df |> select(all_of(shared_features)))
      } else {
        preds <- predict(model, new_data = group_df |>
                            select(position_in_group, all_of(shared_features)))
      }

      group_df |> bind_cols(preds)
    })

  # Derive boom/bust probabilities
  scored |>
    group_by(model_group) |>
    mutate(
      group_resid_sd = sd(draft_fe$av_residual[
        draft_fe$model_group == unique(model_group) &
        draft_fe$season %in% DRAFT_YEARS_TRAIN
      ], na.rm = TRUE),
      pred_uncertainty = results[[unique(model_group)]]$comparison$rmse[1],
      p_boom = pnorm(group_resid_sd, mean = .pred, sd = pred_uncertainty,
                     lower.tail = FALSE),
      p_bust = pnorm(-group_resid_sd, mean = .pred, sd = pred_uncertainty,
                     lower.tail = TRUE),
      p_expected = 1 - p_boom - p_bust,
      model_verdict = case_when(
        p_boom > 0.4  ~ "BOOM",
        p_bust > 0.4  ~ "BUST RISK",
        p_boom > 0.25 ~ "Upside",
        p_bust > 0.25 ~ "Caution",
        TRUE          ~ "Baseline"
      )
    ) |>
    ungroup() |>
    arrange(desc(p_boom))
}

# ============================================================================
# C) OUTPUT: CONTENT-READY PLAYER CARDS
# ============================================================================

format_player_card <- function(scored_data) {
  scored_data |>
    transmute(
      player       = player_name,
      position     = position,
      school       = school,
      model_group  = model_group,
      predicted_av_residual = round(.pred, 1),
      p_boom       = scales::percent(p_boom, accuracy = 0.1),
      p_bust       = scales::percent(p_bust, accuracy = 0.1),
      p_expected   = scales::percent(p_expected, accuracy = 0.1),
      verdict      = model_verdict,
      program_note = case_when(
        prog_pos_n >= 5 & prog_pos_boom_rate > 0.3 ~
          glue::glue("{school} {position} pipeline: {prog_pos_n} drafted, {scales::percent(prog_pos_boom_rate)} boom rate"),
        prog_pos_n >= 5 & prog_pos_bust_rate > 0.4 ~
          glue::glue("{school} {position} pipeline: caution — {scales::percent(prog_pos_bust_rate)} bust rate"),
        prog_pos_n < 3 ~
          glue::glue("{school} has limited {position} draft history ({prog_pos_n} players)"),
        TRUE ~
          glue::glue("{school} {position} pipeline: {prog_pos_n} drafted, avg AV {round(prog_pos_av_mean, 1)}")
      ),
      athleticism  = case_when(
        athleticism_composite > 1   ~ "Elite athlete",
        athleticism_composite > 0.5 ~ "Above-average athlete",
        athleticism_composite > -0.5 ~ "Average athlete",
        athleticism_composite > -1  ~ "Below-average athlete",
        TRUE                        ~ "Limited athletic profile"
      )
    )
}

# ============================================================================
# D) EXAMPLE: SCORE WITH MOCK DRAFT
# ============================================================================
# Uncomment and populate with actual mock draft picks:
#
# mock_draft <- tribble(
#   ~player_name,          ~mock_pick,
#   # ... populate with 2026 mock draft picks
# )
#
# scored_2026 <- score_prospects(prospects_2026, mock_picks = mock_draft)
# player_cards <- format_player_card(scored_2026)
# write_csv(player_cards, "output/2026_player_cards.csv")

cli::cli_alert_success("Scoring pipeline ready")
cli::cli_alert_info("Add mock draft picks to score 2026 prospects")
cli::cli_alert_info("After draft night: replace mock picks with actual picks")
