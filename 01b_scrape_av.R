# ============================================================================
# 01b — PFR Season-Level AV Ingestion
#
# Ingests manually-downloaded CSVs from Pro Football Reference.
# PFR export: Drafted Players table, filtered by Draft Year, seasons 2006–2024.
# Place all downloaded CSV files in data/pfr_av_raw/ before running.
#
# Input:  data/pfr_av_raw/*.csv  (one or more PFR export files)
# Output: data/01b_av_4yr.rds    (one row per drafted player)
#
# After running this script, update 01_load_data.R to join av_4yr from
# this output instead of using w_av as the outcome variable.
# ============================================================================
source("00_config.R")

RAW_DIR <- "data/pfr_av_raw"

# ============================================================================
# A) READ + BIND ALL CSVs
# ============================================================================
cli::cli_h1("Reading PFR AV files")

csv_files <- list.files(RAW_DIR, pattern = "\\.csv$", full.names = TRUE)

if (length(csv_files) == 0) {
  cli::cli_abort("No CSV files found in {RAW_DIR}. Download from PFR first.")
}

cli::cli_alert_info("Found {length(csv_files)} file(s)")

# PFR CSVs have 16 columns: Rk, Player, AV(career), Draft Team, Round, Pick,
# Draft Year, College, Season, Age, Team, G, GS, AV(season), Pos, Player-additional
# Some files (later seasons of 2020-2021 classes) are missing the header row.
# Fix: detect per-file and assign explicit column names for both cases.
# This avoids the rename_with() AV disambiguation entirely.

pfr_col_names <- c(
  "Rk", "Player", "av_career", "Draft Team", "Round", "Pick",
  "Draft Year", "College", "Season", "Age", "Team", "G", "GS",
  "av_season", "Pos", "Player-additional"
)

read_pfr_file <- function(f) {
  first_line <- readLines(f, n = 1, warn = FALSE)
  has_header <- grepl("Rk", first_line, fixed = TRUE)
  read_csv(
    f,
    col_names = pfr_col_names,
    skip      = if (has_header) 1L else 0L,
    col_types = cols(.default = col_character()),
    show_col_types = FALSE
  )
}

pfr_raw <- map(csv_files, read_pfr_file) |>
  list_rbind() |>
  select(-Rk, -av_career)

cli::cli_alert_success("Bound {nrow(pfr_raw)} raw rows")

# ============================================================================
# B) CLEAN COLUMNS
# ============================================================================
cli::cli_h1("Cleaning columns")

pfr_clean <- pfr_raw |>
  rename(
    pfr_id     = `Player-additional`,
    player     = Player,
    draft_year = `Draft Year`,
    draft_team = `Draft Team`,
    round      = Round,
    pick       = Pick,
    college    = College,
    season     = Season,
    age        = Age,
    team       = Team,
    games      = G,
    games_started = GS,
    pos        = Pos
  ) |>
  # Drop PFR row-number column
  select(-any_of("Rk")) |>
  mutate(
    across(c(draft_year, round, pick, season, age, games, games_started, av_season), as.numeric),
    av_season = replace_na(av_season, 0)
  ) |>
  # Keep only training draft classes
  filter(draft_year %in% DRAFT_YEARS_TRAIN)

cli::cli_alert_success("{nrow(pfr_clean)} rows after filtering to training years")

# ============================================================================
# C) COMPUTE 4-YEAR WINDOWED AV
# ============================================================================
cli::cli_h1("Computing 4-year windowed AV")

# Multi-team seasons: sum AV across teams within the same player-season
pfr_season <- pfr_clean |>
  group_by(pfr_id, player, draft_year, round, pick, season) |>
  summarise(
    av_season     = sum(av_season, na.rm = TRUE),
    n_teams       = n_distinct(team),
    games         = sum(games, na.rm = TRUE),
    .groups       = "drop"
  ) |>
  # Only seasons within the 4-year window (years 1–4, rookie year = year 1)
  filter(
    season >= draft_year,
    season <= draft_year + AV_WINDOW_YEARS - 1
  ) |>
  mutate(draft_yr_offset = season - draft_year + 1)   # 1, 2, 3, 4

# Pivot to wide: one row per player, av_yr1 through av_yr4
pfr_wide <- pfr_season |>
  select(pfr_id, player, draft_year, draft_yr_offset, av_season) |>
  pivot_wider(
    names_from  = draft_yr_offset,
    values_from = av_season,
    names_prefix = "av_yr",
    values_fill = 0
  ) |>
  # Ensure all year columns exist even if no data for that year
  mutate(
    across(any_of(paste0("av_yr", 1:AV_WINDOW_YEARS)), ~ replace_na(., 0))
  )

# Aggregate team-change features across all 4 seasons
pfr_team_features <- pfr_season |>
  group_by(pfr_id, draft_year) |>
  summarise(
    seasons_active_4yr = n_distinct(season),
    n_teams_4yr        = sum(n_teams),   # total team-seasons (proxy for churn)
    .groups = "drop"
  )

# Join and compute totals
av_4yr <- pfr_wide |>
  left_join(pfr_team_features, by = c("pfr_id", "draft_year")) |>
  mutate(
    av_4yr_total = rowSums(across(matches("^av_yr[0-9]+")), na.rm = TRUE),
    seasons_active_4yr = replace_na(seasons_active_4yr, 0),
    n_teams_4yr        = replace_na(n_teams_4yr, 0)
  )

cli::cli_alert_success(
  "{nrow(av_4yr)} players with 4-year AV computed (of {n_distinct(pfr_clean$pfr_id)} in raw data)"
)

# Sanity check: distribution of 4-year AV totals
cli::cli_alert_info(
  "av_4yr_total: median = {median(av_4yr$av_4yr_total)}, max = {max(av_4yr$av_4yr_total)}"
)

# ============================================================================
# D) SAVE
# ============================================================================
write_rds(av_4yr, "data/01b_av_4yr.rds")
cli::cli_alert_success("Saved data/01b_av_4yr.rds")

# ============================================================================
# NOTE: After confirming output looks correct, update 01_load_data.R to:
#   1. Load data/01b_av_4yr.rds
#   2. Join to draft_combined on pfr_id (from nflreadr draft picks)
#   3. Replace av_4yr = w_av with av_4yr = av_4yr_total from this file
# ============================================================================
