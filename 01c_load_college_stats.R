# ============================================================================
# 01c — College Production Stats (cfbfastR)
#   - Pulls passing, rushing, receiving, defensive, interception stats
#   - Pulls team stats (separate cache) for domination/share features
#   - Covers 2002–2025 college seasons (supporting 2006–2026 draft classes)
#   - YOY trajectory: keeps yr1 (latest) and yr2 (penultimate) separate
#     for key stats: qb_ypa, rec_ypr, rush_ypc, def_tot
#   - Joins to draft_combined on fuzzy name + college + draft year
#   - Output: data/01c_college_stats.rds
# ============================================================================
source("00_config.R")
library(cfbfastR)
library(fuzzyjoin)

cfbfastR::cfbd_key()

COLLEGE_SEASONS <- 2002:2025
RAW_CACHE       <- "data/01c_college_stats_raw.rds"
TEAM_CACHE      <- "data/01c_team_stats_raw.rds"

# ============================================================================
# A) PULL RAW PLAYER STATS (file-cached — skip if already pulled)
# ============================================================================

if (file.exists(RAW_CACHE)) {
  cli::cli_alert_info("Loading cached raw player stats from {RAW_CACHE}")
  raw <- read_rds(RAW_CACHE)
} else {
  cli::cli_h1("Pulling college player stats from cfbfastR API")

  safe_pull <- function(year, category) {
    Sys.sleep(0.3)
    tryCatch(
      cfbd_stats_season_player(
        year        = year,
        season_type = "regular",
        category    = category
      ) |> mutate(season = year),
      error = function(e) {
        cli::cli_alert_warning("Failed: {category} {year} — {conditionMessage(e)}")
        NULL
      }
    )
  }

  categories <- c("passing", "rushing", "receiving", "defensive", "interceptions")
  raw <- map(categories, function(cat) {
    cli::cli_alert_info("Pulling {cat}...")
    map_dfr(COLLEGE_SEASONS, ~ safe_pull(.x, cat))
  }) |>
    set_names(categories)

  write_rds(raw, RAW_CACHE)
  cli::cli_alert_success("Raw player stats cached to {RAW_CACHE}")
}

# ============================================================================
# B) PULL TEAM STATS (for domination features — separate cache)
# Team-level passing/rushing totals let us compute player share-of-team
# production, capturing "alpha option" status independent of scheme/era.
# ============================================================================

if (file.exists(TEAM_CACHE)) {
  cli::cli_alert_info("Loading cached team stats from {TEAM_CACHE}")
  team_raw <- read_rds(TEAM_CACHE)
} else {
  cli::cli_h1("Pulling team stats from cfbfastR API")

  safe_pull_team <- function(year) {
    Sys.sleep(0.3)
    tryCatch(
      cfbd_stats_season_team(
        year        = year,
        season_type = "regular"
      ) |> mutate(season = year),
      error = function(e) {
        cli::cli_alert_warning("Team stats failed: {year} — {conditionMessage(e)}")
        NULL
      }
    )
  }

  team_raw <- map_dfr(COLLEGE_SEASONS, ~ safe_pull_team(.x))
  write_rds(team_raw, TEAM_CACHE)
  cli::cli_alert_success("Team stats cached to {TEAM_CACHE} — {nrow(team_raw)} team-seasons")
}

# ============================================================================
# C) CONFERENCE TIER MAPPING
# ============================================================================

power4 <- c(
  "SEC", "Big Ten", "Big 12", "ACC", "Pac-12",
  "Big Ten Conference", "Southeastern Conference",
  "Atlantic Coast Conference", "Big 12 Conference",
  "Pacific-12 Conference"
)

group5 <- c(
  "American Athletic", "Conference USA", "MAC",
  "Mountain West", "Sun Belt",
  "Mid-American", "American Athletic Conference"
)

conf_tier <- function(conf) {
  case_when(
    conf %in% power4 ~ "power4",
    conf %in% group5 ~ "group5",
    TRUE             ~ "fcs"
  )
}

# ============================================================================
# D) NORMALIZE NAME + COLLEGE FOR JOINING
# ============================================================================

normalize_name <- function(x) {
  x |>
    str_to_lower() |>
    str_remove_all("\\s+(jr\\.?|sr\\.?|ii|iii|iv)$") |>
    str_remove_all("[^a-z ]") |>
    str_squish()
}

normalize_college <- function(x) {
  x |>
    str_to_lower() |>
    str_remove_all("\\.") |>
    str_squish()
}

# ============================================================================
# E) BUILD PROSPECT LOOKUP FROM DRAFT DATA
# ============================================================================

draft_combined <- read_rds("data/01_draft_combined.rds")

prospects <- draft_combined |>
  filter(!is.na(college), !is.na(pfr_player_name)) |>
  mutate(
    name_norm    = normalize_name(pfr_player_name),
    college_norm = normalize_college(college),
    season_1     = season - 1,
    season_2     = season - 2
  ) |>
  select(season, pick, pfr_player_name, name_norm, college, college_norm,
         model_group, season_1, season_2)

# ============================================================================
# F) DERIVE PER-POSITION FEATURES
# ============================================================================

raw_all <- bind_rows(raw) |>
  distinct(season, athlete_id, .keep_all = TRUE) |>
  mutate(
    name_norm    = normalize_name(player),
    college_norm = normalize_college(team),
    conf_tier    = conf_tier(conference)
  )

cli::cli_alert_info("Consolidated raw stats: {nrow(raw_all)} player-seasons")

# Helper: extract yr1 (latest) and yr2 (penultimate) per-season values
# for a computed rate stat. Returns one row per player with {prefix}_yr1/_yr2.
# min_n: minimum volume threshold to filter noise (e.g., min 10 carries).
extract_yoy_stat <- function(data, val_expr, prefix, min_n_col = NULL, min_n = 0) {
  df <- data
  if (!is.null(min_n_col)) {
    df <- df |> filter(.data[[min_n_col]] >= min_n)
  }
  df |>
    mutate(.val = {{ val_expr }}) |>
    filter(!is.na(.val)) |>
    group_by(name_norm, college_norm) |>
    slice_max(order_by = season, n = 2, with_ties = FALSE) |>
    arrange(desc(season), .by_group = TRUE) |>
    mutate(.yr = row_number()) |>
    select(name_norm, college_norm, .yr, .val) |>
    pivot_wider(names_from = .yr, values_from = .val, names_prefix = ".yr") |>
    rename_with(~ str_replace(., "^\\.yr(\\d+)$", paste0(prefix, "_yr\\1"))) |>
    ungroup()
}

# -- F1) Passing (QB) ---------------------------------------------------------
passing_base <- raw_all |>
  filter(!is.na(passing_att), passing_att > 0) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    qb_att      = sum(passing_att,         na.rm = TRUE),
    qb_comp     = sum(passing_completions, na.rm = TRUE),
    qb_pass_yds = sum(passing_yds,         na.rm = TRUE),
    qb_pass_td  = sum(passing_td,          na.rm = TRUE),
    qb_int      = sum(passing_int,         na.rm = TRUE),
    conf_tier   = first(conf_tier),
    .groups = "drop"
  ) |>
  filter(qb_att > 0) |>
  mutate(
    qb_cmp_pct = qb_comp     / qb_att,
    qb_ypa     = qb_pass_yds / qb_att,
    qb_td_pct  = qb_pass_td  / qb_att,
    qb_int_pct = qb_int      / qb_att
  )

# YOY trajectory: per-season YPA; min 20 attempts to filter garbage time
qb_yoy <- raw_all |>
  filter(!is.na(passing_att), passing_att >= 20) |>
  extract_yoy_stat(passing_yds / pmax(passing_att, 1), "qb_ypa")

passing_features <- passing_base |>
  left_join(qb_yoy, by = c("name_norm", "college_norm"))

# -- F2) Rushing (QB rush contribution + RB) ----------------------------------
rushing_base <- raw_all |>
  filter(!is.na(rushing_car), rushing_car > 0) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    rush_att = sum(rushing_car, na.rm = TRUE),
    rush_yds = sum(rushing_yds, na.rm = TRUE),
    rush_td  = sum(rushing_td,  na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(rush_att > 0) |>
  mutate(rush_ypc = rush_yds / rush_att)

# YOY trajectory: per-season YPC; min 10 carries
rush_yoy <- raw_all |>
  filter(!is.na(rushing_car), rushing_car >= 10) |>
  extract_yoy_stat(rushing_yds / pmax(rushing_car, 1), "rush_ypc")

rushing_features <- rushing_base |>
  left_join(rush_yoy, by = c("name_norm", "college_norm"))

# -- F3) Receiving (WR, TE, RB pass catching) ---------------------------------
receiving_base <- raw_all |>
  filter(!is.na(receiving_rec), receiving_rec > 0) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    rec_rec = sum(receiving_rec, na.rm = TRUE),
    rec_yds = sum(receiving_yds, na.rm = TRUE),
    rec_td  = sum(receiving_td,  na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(rec_rec > 0) |>
  mutate(rec_ypr = rec_yds / pmax(rec_rec, 1))

# YOY trajectory: per-season YPR; min 5 receptions
rec_yoy <- raw_all |>
  filter(!is.na(receiving_rec), receiving_rec >= 5) |>
  extract_yoy_stat(receiving_yds / pmax(receiving_rec, 1), "rec_ypr")

receiving_features <- receiving_base |>
  left_join(rec_yoy, by = c("name_norm", "college_norm"))

# -- F4) Defensive (DL, LB, CB, S) -------------------------------------------
defensive_base <- raw_all |>
  filter(!is.na(defensive_tot), defensive_tot > 0) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    def_solo  = sum(defensive_solo,  na.rm = TRUE),
    def_tot   = sum(defensive_tot,   na.rm = TRUE),
    def_tfl   = sum(defensive_tfl,   na.rm = TRUE),
    def_sacks = sum(defensive_sacks, na.rm = TRUE),
    def_pbu   = sum(defensive_pd,    na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(def_tot > 0)

# YOY trajectory: per-season total tackles
def_yoy <- raw_all |>
  filter(!is.na(defensive_tot), defensive_tot > 0) |>
  extract_yoy_stat(defensive_tot, "def_tot")

defensive_features <- defensive_base |>
  left_join(def_yoy, by = c("name_norm", "college_norm"))

# -- F5) Interceptions (CB, S) ------------------------------------------------
int_features <- raw_all |>
  filter(!is.na(interceptions_int), interceptions_int > 0) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    int_int = sum(interceptions_int, na.rm = TRUE),
    int_yds = sum(interceptions_yds, na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(int_int > 0)

# -- F6) Domination Features (share of team production) -----------------------
# Each player's latest season stats relative to their team's season totals.
# Captures "alpha option" status: a WR with 35% team pass yards is different
# than one with 12%, regardless of air-raid vs pro-style scheme.

domination_features <- tryCatch({
  cli::cli_alert_info("Computing domination features from team stats...")
  cli::cli_alert_info(
    "Team stats columns (first 20): {paste(names(team_raw)[seq_len(min(20,ncol(team_raw)))], collapse=', ')}"
  )

  team_norm <- team_raw |>
    mutate(college_norm = normalize_college(school)) |>
    # Handle potential API version differences in column naming
    rename_with(~ str_replace(., "^pass_", "passing_"), starts_with("pass_")) |>
    rename_with(~ str_replace(., "^rush_", "rushing_"), starts_with("rush_")) |>
    select(season, college_norm, any_of(c(
      "passing_yds", "rushing_yds", "passing_att", "rushing_car"
    )))

  missing_cols <- setdiff(c("passing_yds", "rushing_yds"), names(team_norm))
  if (length(missing_cols) > 0) {
    cli::cli_alert_warning("Team stats missing expected columns: {paste(missing_cols, collapse=', ')}")
    stop("Cannot compute domination features — required team stat columns absent")
  }

  team_totals <- team_norm |>
    group_by(season, college_norm) |>
    summarise(
      team_pass_yds    = sum(passing_yds, na.rm = TRUE),
      team_rush_yds    = sum(rushing_yds, na.rm = TRUE),
      team_total_plays = sum(coalesce(passing_att, 0L) + coalesce(rushing_car, 0L),
                             na.rm = TRUE),
      .groups = "drop"
    )

  # Use latest college season per player for share computation
  player_latest <- raw_all |>
    group_by(name_norm, college_norm) |>
    slice_max(order_by = season, n = 1, with_ties = FALSE) |>
    ungroup()

  player_latest |>
    left_join(team_totals, by = c("season", "college_norm")) |>
    transmute(
      name_norm, college_norm,
      rec_yds_share   = if_else(!is.na(receiving_yds) & team_pass_yds > 0,
                                receiving_yds / team_pass_yds, NA_real_),
      rush_yds_share  = if_else(!is.na(rushing_yds) & team_rush_yds > 0,
                                rushing_yds / team_rush_yds, NA_real_),
      qb_yds_per_play = if_else(!is.na(passing_yds) & team_total_plays > 0,
                                passing_yds / team_total_plays, NA_real_)
    )
}, error = function(e) {
  cli::cli_alert_warning("Domination features skipped: {conditionMessage(e)}")
  NULL
})

# ============================================================================
# G) JOIN TO DRAFT PROSPECTS
# ============================================================================
cli::cli_h1("Joining college stats to draft prospects")

# Fuzzy join on normalized name with college-name tiebreaker.
# max_dist=2 (Levenshtein) handles common spelling variants.
# college_dist tiebreaker (0.01 weight) resolves ties where two players
# have the same name at different schools.
join_stats <- function(prospects_df, stats_df, suffix) {
  stringdist_left_join(
    prospects_df,
    stats_df,
    by           = "name_norm",
    max_dist     = 2,
    method       = "lv",
    distance_col = "name_dist"
  ) |>
    mutate(
      college_dist = if_else(
        is.na(college_norm.y),
        NA_real_,
        stringdist::stringdist(college_norm.x, college_norm.y, method = "lv")
      )
    ) |>
    group_by(season, pick) |>
    slice_min(order_by = name_dist + 0.01 * college_dist, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(-name_norm.y, -college_norm.y, -name_dist, -college_dist) |>
    rename(name_norm = name_norm.x, college_norm = college_norm.x)
}

college_stats <- prospects |>
  join_stats(passing_features,   "pass") |>
  join_stats(rushing_features,   "rush") |>
  join_stats(receiving_features, "rec")  |>
  join_stats(defensive_features, "def")  |>
  join_stats(int_features,       "int")

# Join domination features if available; otherwise fill with NA
if (!is.null(domination_features)) {
  college_stats <- college_stats |>
    join_stats(domination_features, "dom")
} else {
  college_stats <- college_stats |>
    mutate(
      rec_yds_share   = NA_real_,
      rush_yds_share  = NA_real_,
      qb_yds_per_play = NA_real_
    )
}

# ============================================================================
# H) MATCH RATE DIAGNOSTICS
# ============================================================================
cli::cli_h1("College stats match rates")

college_stats |>
  group_by(model_group) |>
  summarise(
    n              = n(),
    pct_pass_match = mean(!is.na(qb_cmp_pct)),
    pct_rush_match = mean(!is.na(rush_ypc)),
    pct_rec_match  = mean(!is.na(rec_ypr)),
    pct_def_match  = mean(!is.na(def_tot)),
    pct_int_match  = mean(!is.na(int_int)),
    pct_dom_match  = mean(!is.na(rec_yds_share)),
    pct_yoy_match  = mean(!is.na(rec_ypr_yr1)),
    .groups = "drop"
  ) |>
  print()

# ============================================================================
# I) SAVE
# ============================================================================
write_rds(college_stats, "data/01c_college_stats.rds")
cli::cli_alert_success(
  "College stats saved — {nrow(college_stats)} prospects, data/01c_college_stats.rds"
)
cli::cli_alert_info("Next: run 02_feature_engineering.R to join and engineer features")
