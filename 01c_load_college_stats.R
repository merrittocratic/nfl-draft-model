# ============================================================================
# 01c — College Production Stats (cfbfastR)
#   - Pulls passing, rushing, receiving, defensive, interception stats
#   - Covers 2002–2025 college seasons (supporting 2006–2026 draft classes)
#   - Takes last 2 college seasons per prospect, normalizes per game
#   - Joins to draft_combined on fuzzy name + college + draft year
#   - Output: data/01c_college_stats.rds
# ============================================================================
source("00_config.R")
library(cfbfastR)
library(fuzzyjoin)

cfbfastR::register_cfbd(api_key = Sys.getenv("CFBD_API_KEY"))

COLLEGE_SEASONS <- 2002:2025
RAW_CACHE       <- "data/01c_college_stats_raw.rds"

# ============================================================================
# A) PULL RAW STATS (file-cached — skip if already pulled)
# ============================================================================

if (file.exists(RAW_CACHE)) {
  cli::cli_alert_info("Loading cached raw college stats from {RAW_CACHE}")
  raw <- read_rds(RAW_CACHE)
} else {
  cli::cli_h1("Pulling college stats from cfbfastR API")

  # Safe pull with retry — returns NULL on failure, logs warning
  safe_pull <- function(year, category) {
    Sys.sleep(0.3)   # polite rate limiting
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
  cli::cli_alert_success("Raw stats cached to {RAW_CACHE}")
}

# ============================================================================
# B) CONFERENCE TIER MAPPING
# ============================================================================
# Tier based on conference at time of play — handles realignment automatically

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
# C) NORMALIZE NAME + COLLEGE FOR JOINING
# ============================================================================

normalize_name <- function(x) {
  x |>
    str_to_lower() |>
    str_remove_all("\\s+(jr\\.?|sr\\.?|ii|iii|iv)$") |>
    str_remove_all("[^a-z ]") |>
    str_squish()
}

# cfbfastR college names differ from nflreadr — normalize both sides
normalize_college <- function(x) {
  x |>
    str_to_lower() |>
    str_remove_all("\\.")     |>   # "Ohio St." → "ohio st"
    str_squish()
}

# ============================================================================
# D) BUILD PROSPECT LOOKUP FROM DRAFT DATA
# ============================================================================
# For each draft prospect: look at college seasons draft_year-1 and draft_year-2

draft_combined <- read_rds("data/01_draft_combined.rds")

prospects <- draft_combined |>
  filter(!is.na(college), !is.na(pfr_player_name)) |>
  mutate(
    name_norm    = normalize_name(pfr_player_name),
    college_norm = normalize_college(college),
    season_1     = season - 1,   # last college season
    season_2     = season - 2    # penultimate college season
  ) |>
  select(season, pick, pfr_player_name, name_norm, college, college_norm,
         model_group, season_1, season_2)

# ============================================================================
# E) DERIVE PER-POSITION FEATURES
# ============================================================================

# Helper: sum stats across 2 seasons for a player, then compute rates
# Returns one row per prospect

# -- Passing (QB) -------------------------------------------------------------
passing_features <- raw$passing |>
  mutate(
    name_norm    = normalize_name(player),
    college_norm = normalize_college(team),
    conf_tier    = conf_tier(conference)
  ) |>
  filter(season %in% (COLLEGE_SEASONS)) |>
  group_by(name_norm, college_norm) |>
  # For each player keep only their last 2 seasons
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    qb_games      = sum(games,         na.rm = TRUE),
    qb_att        = sum(att,           na.rm = TRUE),
    qb_comp       = sum(completions,   na.rm = TRUE),
    qb_pass_yds   = sum(yards,         na.rm = TRUE),
    qb_pass_td    = sum(td,            na.rm = TRUE),
    qb_int        = sum(interceptions, na.rm = TRUE),
    conf_tier     = first(conf_tier),
    .groups = "drop"
  ) |>
  filter(qb_att > 0) |>
  mutate(
    qb_cmp_pct  = qb_comp   / qb_att,
    qb_ypa      = qb_pass_yds / qb_att,
    qb_td_pct   = qb_pass_td  / qb_att,
    qb_int_pct  = qb_int      / qb_att
  )

# -- Rushing (QB rush contribution + RB) -------------------------------------
rushing_features <- raw$rushing |>
  mutate(
    name_norm    = normalize_name(player),
    college_norm = normalize_college(team)
  ) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    rush_games = sum(games,  na.rm = TRUE),
    rush_att   = sum(att,    na.rm = TRUE),
    rush_yds   = sum(yards,  na.rm = TRUE),
    rush_td    = sum(td,     na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(rush_att > 0) |>
  mutate(
    rush_ypc = rush_yds / rush_att,
    rush_ypg = rush_yds / pmax(rush_games, 1),
    rush_tdg = rush_td  / pmax(rush_games, 1)
  )

# -- Receiving (WR, TE, RB pass catching) -------------------------------------
receiving_features <- raw$receiving |>
  mutate(
    name_norm    = normalize_name(player),
    college_norm = normalize_college(team)
  ) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    rec_games = sum(games,       na.rm = TRUE),
    rec_rec   = sum(receptions,  na.rm = TRUE),
    rec_yds   = sum(yards,       na.rm = TRUE),
    rec_td    = sum(td,          na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(rec_rec > 0) |>
  mutate(
    rec_ypr = rec_yds / pmax(rec_rec, 1),
    rec_ypg = rec_yds / pmax(rec_games, 1),
    rec_pg  = rec_rec / pmax(rec_games, 1)
  )

# -- Defensive (DL, LB, CB, S) ------------------------------------------------
defensive_features <- raw$defensive |>
  mutate(
    name_norm    = normalize_name(player),
    college_norm = normalize_college(team)
  ) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    def_games  = sum(games,            na.rm = TRUE),
    def_solo   = sum(solo_tackles,     na.rm = TRUE),
    def_ast    = sum(assisted_tackles, na.rm = TRUE),
    def_tfl    = sum(tackles_for_loss, na.rm = TRUE),
    def_sacks  = sum(sacks,            na.rm = TRUE),
    def_pbu    = sum(pass_defended,    na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(def_games > 0) |>
  mutate(
    def_tackles_pg = (def_solo + def_ast) / def_games,
    def_tfl_pg     = def_tfl   / def_games,
    def_sacks_pg   = def_sacks / def_games,
    def_pbu_pg     = def_pbu   / def_games
  )

# -- Interceptions (CB, S) ----------------------------------------------------
int_features <- raw$interceptions |>
  mutate(
    name_norm    = normalize_name(player),
    college_norm = normalize_college(team)
  ) |>
  group_by(name_norm, college_norm) |>
  slice_max(order_by = season, n = 2, with_ties = FALSE) |>
  summarise(
    int_games = sum(games,         na.rm = TRUE),
    int_int   = sum(interceptions, na.rm = TRUE),
    int_yds   = sum(yards,         na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(int_games > 0) |>
  mutate(int_pg = int_int / int_games)

# ============================================================================
# F) JOIN TO DRAFT PROSPECTS
# ============================================================================
cli::cli_h1("Joining college stats to draft prospects")

# Fuzzy join on normalized name — max distance 2 (same as combine join)
join_stats <- function(prospects_df, stats_df, suffix) {
  stringdist_left_join(
    prospects_df,
    stats_df,
    by        = c("name_norm", "college_norm"),
    max_dist  = 2,
    method    = "lv",
    distance_col = "name_dist"
  ) |>
    # When multiple matches, take closest name
    group_by(season, pick) |>
    slice_min(order_by = name_dist, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(-name_norm.y, -college_norm.y, -name_dist)
}

college_stats <- prospects |>
  join_stats(passing_features,   "pass") |>
  join_stats(rushing_features,   "rush") |>
  join_stats(receiving_features, "rec")  |>
  join_stats(defensive_features, "def")  |>
  join_stats(int_features,       "int")

# ============================================================================
# G) MATCH RATE DIAGNOSTICS
# ============================================================================
cli::cli_h1("College stats match rates")

college_stats |>
  group_by(model_group) |>
  summarise(
    n              = n(),
    pct_pass_match = mean(!is.na(qb_cmp_pct)),
    pct_rush_match = mean(!is.na(rush_ypc)),
    pct_rec_match  = mean(!is.na(rec_ypr)),
    pct_def_match  = mean(!is.na(def_tackles_pg)),
    .groups = "drop"
  ) |>
  print()

# ============================================================================
# H) SAVE
# ============================================================================
write_rds(college_stats, "data/01c_college_stats.rds")
cli::cli_alert_success(
  "College stats saved — {nrow(college_stats)} prospects, data/01c_college_stats.rds"
)
cli::cli_alert_info("Next: update 02_feature_engineering.R to join these features")
