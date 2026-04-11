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
# B2_team) NFL TEAM DEVELOPMENT FEATURES (Rolling 10-Year Window)
#
# Measures each drafting franchise's historical track record at developing
# picks — same rolling leave-one-out structure as program pipeline features.
#
# Key distinction from program pipeline:
#   - Uses av_residual_z (pick-adjusted) not raw av_4yr, so a team that
#     drafts in the top-5 every year doesn't get credit just for high picks
#   - Includes retention_rate: % of picks still on roster in year 2.
#     Teams that draft players and immediately give up signal evaluation
#     AND development failure — organizational disconnect.
#   - left_drafter_yr2 comes from 01b: precise year-2 team comparison
#     with franchise relocation handling (STL/LAR, SDG/LAC, OAK/LVR)
# ============================================================================
cli::cli_h1("Engineering NFL team development features")

compute_team_features <- function(data, target_season, target_team,
                                   target_model_group) {
  window_start <- target_season - TEAM_WINDOW

  team_history <- data |>
    filter(
      season >= window_start,
      season < target_season,
      team == target_team,
      model_group == target_model_group,
      !is.na(av_residual_z)
    )

  team_all <- data |>
    filter(
      season >= window_start,
      season < target_season,
      team == target_team,
      !is.na(av_residual_z)
    )

  tibble(
    team_pos_n             = nrow(team_history),
    team_pos_resid_mean    = if (nrow(team_history) > 0)
      mean(team_history$av_residual_z, na.rm = TRUE) else NA_real_,
    team_pos_boom_rate     = if (nrow(team_history) > 0)
      mean(team_history$outcome_class == "boom", na.rm = TRUE) else NA_real_,
    team_pos_bust_rate     = if (nrow(team_history) > 0)
      mean(team_history$outcome_class == "bust", na.rm = TRUE) else NA_real_,
    # Retention: % still with drafting team in year 2
    # NA left_drafter_yr2 (no year-2 data) treated as departed — team couldn't
    # develop them regardless of reason
    team_pos_retention_2yr = if (nrow(team_history) > 0)
      mean(!coalesce(team_history$left_drafter_yr2, TRUE), na.rm = TRUE) else NA_real_,
    team_all_n             = nrow(team_all),
    team_all_resid_mean    = if (nrow(team_all) > 0)
      mean(team_all$av_residual_z, na.rm = TRUE) else NA_real_,
    team_all_boom_rate     = if (nrow(team_all) > 0)
      mean(team_all$outcome_class == "boom", na.rm = TRUE) else NA_real_,
    team_all_retention_2yr = if (nrow(team_all) > 0)
      mean(!coalesce(team_all$left_drafter_yr2, TRUE), na.rm = TRUE) else NA_real_
  )
}

cli::cli_alert_info("Computing team development features (leave-one-out, {TEAM_WINDOW}-year window)...")

team_features <- draft_fe |>
  filter(!is.na(team)) |>
  select(season, pick, team, model_group) |>
  pmap_dfr(function(season, pick, team, model_group) {
    compute_team_features(draft_fe, season, team, model_group) |>
      mutate(season = season, pick = pick)
  })

draft_fe <- draft_fe |>
  left_join(team_features, by = c("season", "pick"))

cli::cli_alert_success("Team development features computed")

# Quick leaderboard — most interesting content output
cli::cli_alert_info("Team development quality leaderboard (training data, min 10 picks):")
team_dev_leaderboard <- draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN) |>
  group_by(team) |>
  summarise(
    n_picks          = n(),
    resid_mean       = mean(av_residual_z, na.rm = TRUE),
    boom_rate        = mean(outcome_class == "boom", na.rm = TRUE),
    bust_rate        = mean(outcome_class == "bust", na.rm = TRUE),
    retention_2yr    = mean(!coalesce(left_drafter_yr2, TRUE), na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(n_picks >= 10) |>
  arrange(desc(resid_mean))

print(team_dev_leaderboard, n = 34)
write_csv(team_dev_leaderboard, "output/team_dev_leaderboard.csv")
cli::cli_alert_success("Saved output/team_dev_leaderboard.csv")

# ============================================================================
# B2) COLLEGE PRODUCTION FEATURES
#
# Coverage cutoffs — hard-coded based on cfbfastR API depth:
#   pass/rush/rec: 2006+ (cfbfastR covers ~2004; all training classes reached)
#   def/int:       2012+ (API missing ~14 of 24 seasons; coverage confirmed ~2010+,
#                         giving full coverage for draft classes 2012+)
#
# Within covered seasons: raw stats → within-(season × model_group) percentile.
#   Neutralizes era-level stat inflation (air-raid QBs throw more ≠ better).
#   Players with no match stay NA within covered seasons.
# Outside covered seasons: all stats NA — era flags explain the missingness.
#   step_indicate_na() in 03_model_spec.R creates explicit _NA indicator columns
#   so XGBoost distinguishes "unknown" from "no production."
# ============================================================================
cli::cli_h1("Joining college production features")

PASS_REC_ERA_CUTOFF <- 2006
# SR supplemental (01d) covers 2002–2015; cfbfastR covers 2016+.
# Combined source is complete for all training classes (2006–2020).
# Cutoff set to 2005 to exclude 2004/2005 draft classes where coverage
# is partial (only 1–2 college seasons available in the SR data).
DEF_INT_ERA_CUTOFF  <- 2005

pass_rec_college_features <- c(
  "qb_cmp_pct", "qb_ypa", "qb_td_pct", "qb_int_pct",
  "rush_ypc", "rush_att",
  "rec_ypr", "rec_rec", "rec_td"
)

def_int_college_features <- c(
  "def_tot", "def_sacks", "def_tfl", "def_pbu",
  "int_int", "int_yds"
)

# YOY trajectory columns (yr1=latest, yr2=penultimate season)
yoy_cols <- c(
  "qb_ypa_yr1",     "qb_ypa_yr2",
  "qb_int_pct_yr1", "qb_int_pct_yr2",
  "rec_ypr_yr1",    "rec_ypr_yr2",
  "rush_ypc_yr1",   "rush_ypc_yr2",
  "def_tot_yr1",    "def_tot_yr2"
)
# Domination (share-of-team-production) columns
domination_raw_cols <- c("rec_yds_share", "rush_yds_share", "qb_yds_per_play")

college_stats_raw <- read_rds("data/01c_college_stats.rds") |>
  select(season, pick,
         all_of(pass_rec_college_features),
         all_of(def_int_college_features),
         any_of(yoy_cols),
         any_of(domination_raw_cols),
         conf_tier)

draft_fe <- draft_fe |>
  left_join(college_stats_raw, by = c("season", "pick")) |>
  # def_sacks exists in both nflreadr draft data (.x) and college stats (.y)
  # Keep the college production version; drop the nflreadr career stat
  rename(def_sacks = def_sacks.y) |>
  select(-def_sacks.x) |>
  mutate(
    pass_coverage_era = season >= PASS_REC_ERA_CUTOFF,
    def_coverage_era  = season >= DEF_INT_ERA_CUTOFF
  )

# Mask position-inappropriate stats before percentile computation.
# Prevents false name matches from leaking signal across position groups
# (e.g., a safety matched to a QB's passing stats, a LB matched to RB rushing).
# Any stat set to NA here will produce NA percentile — no imputation needed.
draft_fe <- draft_fe |>
  mutate(
    across(c(qb_cmp_pct, qb_ypa, qb_td_pct, qb_int_pct),
           ~ if_else(model_group == "qb", ., NA_real_)),
    across(c(rush_ypc, rush_att),
           ~ if_else(model_group %in% c("qb", "rb", "wr_te"), ., NA_real_)),
    across(c(rec_ypr, rec_rec, rec_td),
           ~ if_else(model_group %in% c("rb", "wr_te"), ., NA_real_)),
    across(c(def_tot, def_sacks, def_tfl, def_pbu),
           ~ if_else(model_group %in% c("dl", "lb", "cb", "s"), ., NA_real_)),
    across(c(int_int, int_yds),
           ~ if_else(model_group %in% c("lb", "cb", "s"), ., NA_real_))
  )

# Step 1: all groups — rank within (season, model_group)
draft_fe <- draft_fe |>
  group_by(season, model_group) |>
  mutate(
    across(
      all_of(pass_rec_college_features),
      ~ if_else(pass_coverage_era, percent_rank(.), NA_real_),
      .names = "{.col}_pctile"
    ),
    across(
      all_of(def_int_college_features),
      ~ if_else(def_coverage_era, percent_rank(.), NA_real_),
      .names = "{.col}_pctile"
    )
  ) |>
  ungroup()

# Step 2: re-rank rec_* and rush_* for wr_te group at (season, position) level.
# WR and TE stats are on different scales — a TE with 60 receptions is elite;
# a WR with 60 is average. rush_att_pctile is the top WR/TE feature — but TEs
# have near-zero rushing, inflating WR rush percentiles in mixed ranking.
# Position-level ranking fixes both signals.
rec_base_features  <- pass_rec_college_features[str_starts(pass_rec_college_features, "rec_")]
rush_base_features <- pass_rec_college_features[str_starts(pass_rec_college_features, "rush_")]
rec_pctile_cols    <- paste0(rec_base_features,  "_pctile")
rush_pctile_cols   <- paste0(rush_base_features, "_pctile")

for (col in c(rec_pctile_cols, rush_pctile_cols)) {
  base_col <- str_remove(col, "_pctile")
  draft_fe <- draft_fe |>
    group_by(season, position) |>
    mutate(
      !!col := if_else(
        model_group == "wr_te" & pass_coverage_era,
        percent_rank(.data[[base_col]]),
        .data[[col]]
      )
    ) |>
    ungroup()
}

college_pctile_features <- c(
  paste0(pass_rec_college_features, "_pctile"),
  paste0(def_int_college_features,  "_pctile")
)

# ============================================================================
# B3) YEAR-OVER-YEAR TRAJECTORY FEATURES
# Breakout trajectory in the final college season is a known draft predictor.
# yr1 = latest season, yr2 = penultimate (from 01c_load_college_stats.R).
# YOY pctile = within-(season × model_group) rank of season-over-season change.
# ============================================================================
cli::cli_h1("Computing YOY trajectory features")

draft_fe <- draft_fe |>
  mutate(
    qb_ypa_yoy     = if_else(!is.na(qb_ypa_yr1)     & !is.na(qb_ypa_yr2)     & qb_ypa_yr2     > 0,
                              (qb_ypa_yr1     - qb_ypa_yr2)     / qb_ypa_yr2,     NA_real_),
    # INT rate YOY: negative = improvement (fewer INTs), positive = regression
    # Flip sign so higher percentile = better (fewer INTs in final season)
    qb_int_pct_yoy = if_else(!is.na(qb_int_pct_yr1) & !is.na(qb_int_pct_yr2) & qb_int_pct_yr2 > 0,
                              -((qb_int_pct_yr1 - qb_int_pct_yr2) / qb_int_pct_yr2), NA_real_),
    rec_ypr_yoy    = if_else(!is.na(rec_ypr_yr1)    & !is.na(rec_ypr_yr2)    & rec_ypr_yr2    > 0,
                              (rec_ypr_yr1    - rec_ypr_yr2)    / rec_ypr_yr2,    NA_real_),
    rush_ypc_yoy   = if_else(!is.na(rush_ypc_yr1)   & !is.na(rush_ypc_yr2)   & rush_ypc_yr2   > 0,
                              (rush_ypc_yr1   - rush_ypc_yr2)   / rush_ypc_yr2,   NA_real_),
    def_tot_yoy    = if_else(!is.na(def_tot_yr1)    & !is.na(def_tot_yr2)    & def_tot_yr2    > 0,
                              (def_tot_yr1    - def_tot_yr2)    / def_tot_yr2,    NA_real_)
  )

yoy_raw_cols <- c("qb_ypa_yoy", "qb_int_pct_yoy", "rec_ypr_yoy", "rush_ypc_yoy", "def_tot_yoy")

draft_fe <- draft_fe |>
  group_by(season, model_group) |>
  mutate(across(all_of(yoy_raw_cols), percent_rank, .names = "{.col}_pctile")) |>
  ungroup()

cli::cli_alert_success("YOY trajectory features computed")

# ============================================================================
# B4) DOMINATION FEATURES (percentile within season × model_group)
# Share of team production — captures "alpha option" status independent of scheme.
# ============================================================================
cli::cli_h1("Computing domination feature percentiles")

# Mask to appropriate position groups before ranking
draft_fe <- draft_fe |>
  mutate(
    rec_yds_share   = if_else(model_group %in% c("wr_te", "rb"), rec_yds_share,   NA_real_),
    rush_yds_share  = if_else(model_group == "rb",               rush_yds_share,  NA_real_),
    qb_yds_per_play = if_else(model_group == "qb",               qb_yds_per_play, NA_real_)
  )

domination_cols <- c("rec_yds_share", "rush_yds_share", "qb_yds_per_play")

draft_fe <- draft_fe |>
  group_by(season, model_group) |>
  mutate(
    across(
      all_of(domination_cols),
      ~ if_else(pass_coverage_era, percent_rank(.), NA_real_),
      .names = "{.col}_pctile"
    )
  ) |>
  ungroup()

cli::cli_alert_success("Domination feature percentiles computed")

cli::cli_alert_success("College production features joined")

draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN) |>
  group_by(model_group) |>
  summarise(
    n              = n(),
    pct_qb_pctile  = mean(!is.na(qb_cmp_pct_pctile)),
    pct_rush_pctile = mean(!is.na(rush_ypc_pctile)),
    pct_rec_pctile  = mean(!is.na(rec_ypr_pctile)),
    pct_def_pctile  = mean(!is.na(def_tot_pctile)),
    pct_int_pctile  = mean(!is.na(int_int_pctile)),
    .groups = "drop"
  ) |>
  print()

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

# Speed Score (Bill Barnwell / Chase Stuart) — weight-adjusted speed.
# Corrects for body mass: a 240-lb pass rusher running 4.55 >> a 185-lb WR.
# wt and forty already in draft_fe; ht converted to inches above.
draft_fe <- draft_fe |>
  mutate(
    speed_score = if_else(!is.na(wt) & !is.na(forty) & forty > 0,
                          (wt * 200) / (forty^4), NA_real_),
    bmi         = if_else(!is.na(wt) & !is.na(ht) & ht > 0,
                          (wt / (ht^2)) * 703, NA_real_)
  )

# Percentile rank within position group — size/speed sweet spot is position-specific
draft_fe <- draft_fe |>
  group_by(model_group) |>
  mutate(
    speed_score_pctile = percent_rank(speed_score),
    bmi_pctile         = percent_rank(bmi)
  ) |>
  ungroup()

# Era-scaled draft year — centers on training midpoint, lets model detect
# secular trends (EDGE rush premium post-2010, AV inflation for QBs, etc.)
draft_fe <- draft_fe |>
  mutate(draft_year_scaled = (season - 2013) / 7)

cli::cli_alert_success("Speed Score, BMI, and draft_year_scaled computed")

# ============================================================================
# D) AGE & EXPERIENCE FEATURES
# ============================================================================

draft_fe <- draft_fe |>
  mutate(
    draft_age        = age,
    college_years    = pmin(pmax(round(draft_age - 18), 1), 6),
    is_underclassman = college_years <= 3,
    is_te            = as.integer(position == "TE")
    # log_pick and round_num already computed in section A
  )

# Draft age within (model_group × round_num) — captures "unusually young for a CB"
# signal that absolute draft_age alone misses (a 20-yr-old 1st-round CB is different
# from a 22-yr-old 1st-round CB, even if raw age differences look small).
draft_fe <- draft_fe |>
  group_by(model_group, round_num) |>
  mutate(draft_age_pctile_in_group = percent_rank(draft_age)) |>
  ungroup()

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
  # Draft context
  "log_pick", "round_num", "draft_age", "draft_age_pctile_in_group",
  "college_years", "is_underclassman", "is_te",
  # Combine measurables
  combine_features,
  "athleticism_composite", "n_combine_tests",
  # Program pipeline
  "prog_pos_n", "prog_pos_av_mean", "prog_pos_av_median",
  "prog_pos_boom_rate", "prog_pos_bust_rate", "prog_pos_avg_pick",
  "prog_all_n", "prog_all_av_mean", "prog_all_boom_rate",
  "college_av_pctile",
  # College production (within-year percentiles; NA outside coverage window)
  college_pctile_features,
  # YOY trajectory (breakout signal; NA when only one college season available)
  "qb_ypa_yoy_pctile", "qb_int_pct_yoy_pctile", "rec_ypr_yoy_pctile", "rush_ypc_yoy_pctile", "def_tot_yoy_pctile",
  # Domination — share of team production (NA outside coverage window)
  "rec_yds_share_pctile", "rush_yds_share_pctile", "qb_yds_per_play_pctile",
  # Coverage era flags — let model distinguish "no data" from "no production"
  "pass_coverage_era", "def_coverage_era",
  # Conference tier (categorical; step_dummy() in recipe)
  "conf_tier",
  # NFL team development features (rolling 10-year, pick-adjusted, leave-one-out)
  "team_pos_n", "team_pos_resid_mean", "team_pos_boom_rate", "team_pos_bust_rate",
  "team_pos_retention_2yr", "team_all_n", "team_all_resid_mean",
  "team_all_boom_rate", "team_all_retention_2yr",
  # Era signal — pairs with season covariate in AV curve to let model recapture
  # era effects removed from the outcome (QB AV inflation, EDGE rush premium, etc.)
  "draft_year_scaled"
)

write_rds(draft_fe, "data/02_draft_features.rds")
write_rds(shared_features, "data/02_feature_names.rds")

cli::cli_alert_success("Saved data/02_draft_features.rds ({nrow(draft_fe)} rows, {length(shared_features)} shared features)")

draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(av_residual)) |>
  group_by(model_group) |>
  summarise(
    n           = n(),
    av_mean     = mean(av_4yr, na.rm = TRUE),
    resid_mean  = mean(av_residual, na.rm = TRUE),
    boom_pct    = mean(outcome_class == "boom", na.rm = TRUE),
    bust_pct    = mean(outcome_class == "bust", na.rm = TRUE),
    combine_pct = mean(n_combine_tests > 0, na.rm = TRUE),
    # % with primary college production stat populated (position-appropriate)
    college_pct = mean(
      !is.na(qb_cmp_pct_pctile) | !is.na(rush_ypc_pctile) |
      !is.na(rec_ypr_pctile)    | !is.na(def_tot_pctile),
      na.rm = TRUE
    ),
    .groups = "drop"
  ) |>
  arrange(desc(n)) |>
  print()
