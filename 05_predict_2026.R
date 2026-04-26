# ============================================================================
# 05 — Score 2026 Draft Class
#   - Load 2026 combine data + mock board
#   - Construct all buildable features; set unknowable ones to NA
#   - Apply trained sub-models (XGBoost workflows)
#   - Derive boom/bust probabilities
#   - Write content-ready output
# ============================================================================
source("00_config.R")
library(fuzzyjoin)

draft_fe        <- read_rds("data/02_draft_features.rds") |>
  mutate(college = canonicalize_college(college))   # expand "Ohio St." → "Ohio State" etc.
best_models     <- map(read_rds("data/04_best_models.rds"), bundle::unbundle)
results         <- read_rds("data/04_tuning_results.rds")
shared_features <- read_rds("data/02_feature_names.rds")

# Inline copy of compute_team_features() from 02_feature_engineering.R.
# Kept here so 05 can be run standalone without sourcing 02.
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

# ============================================================================
# A) LOAD & JOIN 2026 DATA
# ============================================================================
cli::cli_h1("Loading 2026 prospect data")

# --- A1: Combine measurables ------------------------------------------------
combine_raw <- nflreadr::load_combine(seasons = 2026) |>
  mutate(
    # Parse height from "6-3" string to numeric inches (same as 02_feature_engineering.R)
    ht = if_else(
      str_detect(coalesce(ht, ""), "-"),
      as.numeric(str_extract(ht, "^\\d+")) * 12 + as.numeric(str_extract(ht, "\\d+$")),
      suppressWarnings(as.numeric(ht))
    ),
    position = case_when(
      pos %in% c("DE", "EDGE", "OLB")    ~ "EDGE",
      pos %in% c("DT", "NT", "IDL")      ~ "IDL",
      pos %in% c("T", "OT")              ~ "OT",
      pos %in% c("G", "C", "OL")         ~ "IOL",
      pos %in% c("FS", "SS", "DB", "S")  ~ "S",
      pos == "CB"                         ~ "CB",
      pos %in% c("ILB", "LB", "MLB")     ~ "LB",
      pos %in% c("FB", "RB")             ~ "RB",
      pos == "WR"                         ~ "WR",
      pos == "TE"                         ~ "TE",
      pos == "QB"                         ~ "QB",
      TRUE ~ pos
    )
  ) |>
  mutate(school = canonicalize_college(school)) |>   # "Ohio St." → "Ohio State"
  left_join(position_model_map |> distinct(position, model_group), by = "position") |>
  filter(!is.na(model_group))

# --- A2: Mock board + pick estimates ----------------------------------------
# Nickname → legal name aliases: some prospects go by a nickname on mock boards
# but nflreadr stores their legal name. Apply before any joining so aliases
# resolve correctly in both the combine-mock join (A3) and backfill (A4).
name_aliases <- c(
  "Sonny Styles" = "Alex Styles"
)

# DRAFT NIGHT: duplicate combined_board_mock_20260405.csv → combined_board_actual_20260424.csv,
# update mock_pick (actual pick number) and mock_team (actual drafting team, full name e.g.
# "Las Vegas Raiders") for each pick as it happens, then point this read_csv call at the new
# file. All other columns (player, position, college, big_board_rank, status, confidence)
# carry over unchanged. Re-run after each round or at end of night.
mock_raw <- read_csv("data/combined_board_actual_20260424.csv", show_col_types = FALSE) |>
  mutate(
    player   = coalesce(name_aliases[player], player),
    # DL in mock board maps to IDL in our position taxonomy
    position = if_else(position == "DL", "IDL", position),
    # pick_est: explicit mock slot for R1, big_board_rank as proxy for rest
    pick_est = coalesce(mock_pick, big_board_rank)
  )

# --- A3: Name-match combine + mock ------------------------------------------
# Standardize to lowercase ASCII, strip punctuation
std_name <- function(x) {
  x |>
    str_to_lower() |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_remove_all("[^a-z ]") |>
    str_squish()
}

combine_keyed <- combine_raw |>
  mutate(.key = std_name(player_name))

mock_keyed <- mock_raw |>
  mutate(.key = std_name(player)) |>
  select(.key, pick_est, mock_pick, big_board_rank, status, confidence, mock_team)

# Exact match first
exact <- inner_join(combine_keyed, mock_keyed, by = ".key")

# Fuzzy match (Levenshtein ≤ 2) for remaining combine players
unmatched <- combine_keyed |> filter(!.key %in% exact$.key)
if (nrow(unmatched) > 0) {
  fuzzy <- stringdist_left_join(
    unmatched, mock_keyed,
    by = ".key", max_dist = 2, method = "lv"
  ) |>
    # Pre-compute distance so slice_min doesn't need stringdist() in scope
    mutate(.dist = stringdist::stringdist(.key.x, coalesce(.key.y, ""), method = "lv")) |>
    group_by(player_name) |>
    slice_min(.dist, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(-.dist) |>
    rename(.key = .key.x) |>
    select(-`.key.y`)
} else {
  fuzzy <- unmatched |>
    mutate(pick_est = NA_real_, mock_pick = NA_real_,
           big_board_rank = NA_real_, status = NA_character_, confidence = NA_real_,
           mock_team = NA_character_)
}

prospects_2026 <- bind_rows(exact, fuzzy) |>
  select(-.key) |>
  # Unmatched prospects: treat as undrafted / deep depth chart (pick ~ 255)
  mutate(
    pick_est = coalesce(pick_est, 255),
    status   = coalesce(status, "outside_r1")
  )

n_mock <- sum(!is.na(prospects_2026$mock_pick) | prospects_2026$status == "best_available")
cli::cli_alert_info(
  "{n_mock} R1/best-available prospects matched | {nrow(prospects_2026)} total combine players"
)

# --- A4: Add mock-board prospects missing from combine data -----------------
# Players who skipped the combine (or whose data isn't yet in nflreadr) are
# silently dropped by the combine-first join above. A missing Caleb Downs is
# a worse error than a player card with NA athleticism. Add everyone on the
# mock board who didn't match into the combine pool.
#
# Position mapping: mock board uses our taxonomy already (DL fixed above),
# but may include positions not in position_model_map — those are filtered out.

matched_names <- std_name(prospects_2026$player_name)

mock_only <- mock_raw |>
  mutate(.key = std_name(player)) |>
  filter(!.key %in% matched_names) |>
  left_join(
    position_model_map |> distinct(position, model_group),
    by = "position"
  ) |>
  filter(!is.na(model_group)) |>
  transmute(
    player_name    = player,
    school         = college,
    position       = position,
    model_group    = model_group,
    pick_est       = pick_est,
    mock_pick      = mock_pick,
    big_board_rank = big_board_rank,
    status         = coalesce(status, "outside_r1"),
    confidence     = confidence,
    mock_team      = mock_team
    # All combine measurables (ht, wt, forty, etc.) are NA — bind_rows fills them
  )

if (nrow(mock_only) > 0) {
  cli::cli_alert_info(
    "Adding {nrow(mock_only)} non-combine prospects from mock board:"
  )
  walk(mock_only$player_name, ~ cli::cli_alert_info("  + {.x}"))
  prospects_2026 <- bind_rows(prospects_2026, mock_only)
}

# Audit: flag any top-64 mock players still not in the final prospects list
top64_missing <- mock_raw |>
  filter(pick_est <= 64) |>
  mutate(.key = std_name(player)) |>
  filter(!.key %in% std_name(prospects_2026$player_name)) |>
  pull(player)
if (length(top64_missing) > 0) {
  cli::cli_alert_warning(
    "Top-64 mock players still missing from prospects: {paste(top64_missing, collapse = ', ')}"
  )
} else {
  cli::cli_alert_success("All top-64 mock players accounted for")
}

# ============================================================================
# B) FEATURE CONSTRUCTION
# ============================================================================
cli::cli_h1("Building features")

# --- B1: Pick context -------------------------------------------------------
prospects_2026 <- prospects_2026 |>
  mutate(
    season    = 2026L,
    pick      = pick_est,
    log_pick  = log(pick_est),
    round_num = case_when(
      pick_est <= 32  ~ 1L,
      pick_est <= 64  ~ 2L,
      pick_est <= 100 ~ 3L,
      pick_est <= 135 ~ 4L,
      pick_est <= 176 ~ 5L,
      pick_est <= 220 ~ 6L,
      TRUE            ~ 7L
    )
  )

# --- B2: Source indicators --------------------------------------------------
# "combine" if measured at the combine, "missing" otherwise.
# Pro day scraping for 2026 is a future enhancement (01e only covers 2006–2024).
for (.col in combine_features) {
  prospects_2026[[paste0(.col, "_src")]] <-
    if_else(!is.na(prospects_2026[[.col]]), "combine", "missing")
}

# --- B3: Athleticism composite (training-relative z-scores) -----------------
# Z-score params derived from training data so 2026 composites are on the
# same scale the model saw during training. Recomputed from draft_fe at runtime
# rather than hardcoded to stay in sync with any future retraining.
train_params <- draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN) |>
  group_by(model_group) |>
  summarise(
    across(all_of(combine_features),
           list(mu = ~mean(.x, na.rm = TRUE), sigma = ~sd(.x, na.rm = TRUE)),
           .names = "{.col}__{.fn}"),
    .groups = "drop"
  )

prospects_2026 <- prospects_2026 |>
  left_join(train_params, by = "model_group") |>
  rowwise() |>
  mutate(
    forty_z      = (forty      - forty__mu)      / forty__sigma,
    bench_z      = (bench      - bench__mu)      / bench__sigma,
    vertical_z   = (vertical   - vertical__mu)   / vertical__sigma,
    broad_jump_z = (broad_jump - broad_jump__mu) / broad_jump__sigma,
    cone_z       = (cone       - cone__mu)       / cone__sigma,
    shuttle_z    = (shuttle    - shuttle__mu)    / shuttle__sigma,
    athleticism_composite = mean(
      c(-forty_z, bench_z, vertical_z, broad_jump_z, -cone_z, -shuttle_z),
      na.rm = TRUE
    ),
    n_combine_tests = sum(!is.na(c_across(all_of(combine_features))))
  ) |>
  ungroup() |>
  select(-ends_with("__mu"), -ends_with("__sigma"),
         -forty_z, -bench_z, -vertical_z, -broad_jump_z, -cone_z, -shuttle_z)

# --- B3b: Speed Score and BMI (position-group percentile) -------------------
# speed_score = (wt * 200) / forty^4 — same formula as 02_feature_engineering.R
# Percentile ranked within the 2026 cohort by model_group, matching training scheme.
prospects_2026 <- prospects_2026 |>
  mutate(
    speed_score = if_else(!is.na(wt) & !is.na(forty) & forty > 0,
                          (wt * 200) / (forty^4), NA_real_),
    bmi         = if_else(!is.na(wt) & !is.na(ht) & ht > 0,
                          (wt / (ht^2)) * 703, NA_real_)
  ) |>
  group_by(model_group) |>
  mutate(
    speed_score_pctile = percent_rank(speed_score),
    bmi_pctile         = percent_rank(bmi)
  ) |>
  ungroup()

# --- B4: Fixed / derivable features -----------------------------------------
prospects_2026 <- prospects_2026 |>
  mutate(
    is_te             = as.integer(position == "TE"),
    # Both era flags are TRUE for 2026 (coverage extends through 2025 season)
    pass_coverage_era = TRUE,
    def_coverage_era  = TRUE,
    draft_year_scaled = (2026 - 2013) / 7,
    position_in_group = factor(position)
  )

# --- B5: Unknown features → NA (XGBoost handles natively) ------------------
# draft_age / pctile / college_years / is_underclassman: no birth dates in combine data
# conf_tier: initialized NA here; overwritten in C2 when college stats match
# College pctile, YOY, domination: initialized NA here; overwritten in C2 with 2025 stats
# Team dev features: unknowable until draft night (which team picks each prospect)
na_features <- c(
  "draft_age", "draft_age_pctile_in_group", "college_years", "is_underclassman",
  "conf_tier",
  "college_av_pctile",
  "qb_cmp_pct_pctile", "qb_ypa_pctile", "qb_td_pct_pctile", "qb_int_pct_pctile",
  "rush_ypc_pctile", "rush_att_pctile",
  "rec_ypr_pctile", "rec_rec_pctile", "rec_td_pctile",
  "def_tot_pctile", "def_sacks_pctile", "def_tfl_pctile", "def_pbu_pctile",
  "int_int_pctile", "int_yds_pctile",
  "qb_ypa_yoy_pctile", "qb_int_pct_yoy_pctile",
  "rec_ypr_yoy_pctile", "rush_ypc_yoy_pctile", "def_tot_yoy_pctile",
  "rec_yds_share_pctile", "rush_yds_share_pctile", "qb_yds_per_play_pctile",
  "team_pos_n", "team_pos_resid_mean", "team_pos_boom_rate", "team_pos_bust_rate",
  "team_pos_retention_2yr", "team_all_n", "team_all_resid_mean",
  "team_all_boom_rate", "team_all_retention_2yr"
)
# conf_tier is character in the recipe; everything else is numeric.
# Force-set regardless of whether column already exists (type must match training).
char_na_features <- c("conf_tier")
num_na_features  <- setdiff(na_features, char_na_features)

for (.col in char_na_features) prospects_2026[[.col]] <- NA_character_
for (.col in num_na_features) {
  if (!.col %in% names(prospects_2026)) prospects_2026[[.col]] <- NA_real_
}

# --- B5b: DOB join — draft age features from data/DOB_26.csv ---------------
# Two name formats in the file:
#   "Firstname Lastname"  (dynastyleaguefootball.com)
#   "Lastname, Firstname" (establishtherun.com — quoted in CSV)
# Normalize both to "Firstname Lastname", then std_name() for join key.
# De-dup after normalization (keep first row per key — DOB values agree across
# sources when both cover the same player).
DRAFT_DATE_2026 <- as.Date("2026-04-24")

dob_raw <- tryCatch(
  read_csv("data/DOB_26.csv", show_col_types = FALSE),
  error = function(e) { cli::cli_alert_warning("data/DOB_26.csv not found — skipping DOB join"); NULL }
)

if (!is.null(dob_raw)) {
  dob_clean <- dob_raw |>
    mutate(
      # Detect "Lastname, Firstname" pattern and reverse; otherwise keep as-is
      name_norm = if_else(
        str_detect(Player, ","),
        str_trim(paste(
          str_trim(str_extract(Player, "(?<=,).*")),   # everything after comma
          str_trim(str_extract(Player, "^[^,]+"))      # everything before comma
        )),
        str_trim(Player)
      ),
      .key    = std_name(name_norm),
      dob     = mdy(Birthdate)
    ) |>
    filter(!is.na(dob)) |>
    distinct(.key, .keep_all = TRUE) |>
    select(.key, dob)

  prospects_2026 <- prospects_2026 |>
    mutate(.key = std_name(player_name)) |>
    left_join(dob_clean, by = ".key") |>
    mutate(
      draft_age        = if_else(!is.na(dob),
                                 as.integer(floor(as.numeric(difftime(DRAFT_DATE_2026, dob, units = "days")) / 365.25)),
                                 NA_integer_),
      college_years    = if_else(!is.na(draft_age),
                                 pmin(pmax(as.integer(round(draft_age - 18L)), 1L), 6L),
                                 NA_integer_),
      is_underclassman = if_else(!is.na(college_years),
                                 as.integer(college_years <= 3L),
                                 NA_integer_)
    ) |>
    select(-.key, -dob)

  n_matched <- sum(!is.na(prospects_2026$draft_age))
  cli::cli_alert_success("DOB matched: {n_matched} / {nrow(prospects_2026)} prospects")

  # Percentile rank within (model_group × round_num) — same scheme as training.
  # Computed within the 2026 cohort; NAs stay NA.
  prospects_2026 <- prospects_2026 |>
    group_by(model_group, round_num) |>
    mutate(draft_age_pctile_in_group = percent_rank(draft_age)) |>
    ungroup()
}

# --- B6: Team development features (pre-draft: mock team; draft night: actual team) ---------
# mock_team in the CSV is a full team name; draft_fe uses PFR-style 3-letter abbrevs.
# Mapping covers all 32 current franchises plus legacy names that appear in training data.
# On draft night: update the CSV with actual drafting teams (same full-name format)
# and re-run — this section resolves automatically.
mock_team_to_pfr <- c(
  "Arizona Cardinals"       = "ARI",
  "Atlanta Falcons"         = "ATL",
  "Baltimore Ravens"        = "BAL",
  "Buffalo Bills"           = "BUF",
  "Carolina Panthers"       = "CAR",
  "Chicago Bears"           = "CHI",
  "Cincinnati Bengals"      = "CIN",
  "Cleveland Browns"        = "CLE",
  "Dallas Cowboys"          = "DAL",
  "Denver Broncos"          = "DEN",
  "Detroit Lions"           = "DET",
  "Green Bay Packers"       = "GNB",
  "Houston Texans"          = "HOU",
  "Indianapolis Colts"      = "IND",
  "Jacksonville Jaguars"    = "JAX",
  "Kansas City Chiefs"      = "KAN",
  "Los Angeles Rams"        = "LAR",
  "Los Angeles Chargers"    = "LAC",
  "Las Vegas Raiders"       = "LVR",
  "Miami Dolphins"          = "MIA",
  "Minnesota Vikings"       = "MIN",
  "New England Patriots"    = "NWE",
  "New Orleans Saints"      = "NOR",
  "New York Giants"         = "NYG",
  "New York Jets"           = "NYJ",
  "Philadelphia Eagles"     = "PHI",
  "Pittsburgh Steelers"     = "PIT",
  "Seattle Seahawks"        = "SEA",
  "San Francisco 49ers"     = "SFO",
  "Tampa Bay Buccaneers"    = "TAM",
  "Tennessee Titans"        = "TEN",
  "Washington Commanders"   = "WAS"
)

prospects_with_team <- prospects_2026 |>
  filter(!is.na(mock_team)) |>
  mutate(team_abbr = mock_team_to_pfr[mock_team]) |>
  filter(!is.na(team_abbr))

if (nrow(prospects_with_team) > 0) {
  cli::cli_alert_info(
    "Computing team dev features for {nrow(prospects_with_team)} prospects with known teams..."
  )

  team_feats_2026 <- prospects_with_team |>
    select(player_name, team_abbr, model_group) |>
    pmap_dfr(function(player_name, team_abbr, model_group) {
      compute_team_features(draft_fe, 2026L, team_abbr, model_group) |>
        mutate(player_name = player_name)
    })

  prospects_2026 <- prospects_2026 |>
    left_join(
      team_feats_2026 |>
        select(player_name,
               team_pos_n_new          = team_pos_n,
               team_pos_resid_mean_new  = team_pos_resid_mean,
               team_pos_boom_rate_new   = team_pos_boom_rate,
               team_pos_bust_rate_new   = team_pos_bust_rate,
               team_pos_retention_2yr_new = team_pos_retention_2yr,
               team_all_n_new           = team_all_n,
               team_all_resid_mean_new  = team_all_resid_mean,
               team_all_boom_rate_new   = team_all_boom_rate,
               team_all_retention_2yr_new = team_all_retention_2yr),
      by = "player_name"
    ) |>
    mutate(
      team_pos_n             = coalesce(team_pos_n_new,           team_pos_n),
      team_pos_resid_mean    = coalesce(team_pos_resid_mean_new,  team_pos_resid_mean),
      team_pos_boom_rate     = coalesce(team_pos_boom_rate_new,   team_pos_boom_rate),
      team_pos_bust_rate     = coalesce(team_pos_bust_rate_new,   team_pos_bust_rate),
      team_pos_retention_2yr = coalesce(team_pos_retention_2yr_new, team_pos_retention_2yr),
      team_all_n             = coalesce(team_all_n_new,           team_all_n),
      team_all_resid_mean    = coalesce(team_all_resid_mean_new,  team_all_resid_mean),
      team_all_boom_rate     = coalesce(team_all_boom_rate_new,   team_all_boom_rate),
      team_all_retention_2yr = coalesce(team_all_retention_2yr_new, team_all_retention_2yr)
    ) |>
    select(-ends_with("_new"))

  cli::cli_alert_success("Team dev features populated for {nrow(prospects_with_team)} prospects")
} else {
  cli::cli_alert_info("No mock_team data found — team dev features remain NA (populate mock CSV to resolve)")
}

# ============================================================================
# C) PROGRAM PIPELINE FEATURES
# ============================================================================
cli::cli_h1("Computing program pipeline features")

prog_feats_2026 <- pmap_dfr(
  prospects_2026 |> select(player_name, school, model_group),
  function(player_name, school, model_group) {
    window_start <- 2026 - PROGRAM_WINDOW

    # Use .env$ to explicitly reference function params, not draft_fe columns.
    # draft_fe has both `college` and `school` columns — without .env$, dplyr
    # resolves `school` as the data column rather than the function argument.
    pos_hist <- draft_fe |>
      filter(season >= window_start, season < 2026,
             college == .env$school, model_group == .env$model_group, !is.na(av_4yr))
    all_hist <- draft_fe |>
      filter(season >= window_start, season < 2026,
             college == .env$school, !is.na(av_4yr))

    tibble(
      player_name        = player_name,
      prog_pos_n         = nrow(pos_hist),
      prog_pos_av_mean   = if (nrow(pos_hist) > 0) mean(pos_hist$av_4yr,  na.rm = TRUE) else NA_real_,
      prog_pos_av_median = if (nrow(pos_hist) > 0) median(pos_hist$av_4yr, na.rm = TRUE) else NA_real_,
      prog_pos_boom_rate = if (nrow(pos_hist) > 0) mean(pos_hist$outcome_class == "boom", na.rm = TRUE) else NA_real_,
      prog_pos_bust_rate = if (nrow(pos_hist) > 0) mean(pos_hist$outcome_class == "bust", na.rm = TRUE) else NA_real_,
      prog_pos_avg_pick  = if (nrow(pos_hist) > 0) mean(pos_hist$pick,   na.rm = TRUE) else NA_real_,
      prog_all_n         = nrow(all_hist),
      prog_all_av_mean   = if (nrow(all_hist) > 0) mean(all_hist$av_4yr, na.rm = TRUE) else NA_real_,
      prog_all_boom_rate = if (nrow(all_hist) > 0) mean(all_hist$outcome_class == "boom", na.rm = TRUE) else NA_real_
    )
  }
)

# Drop any stale prog_ cols before joining fresh ones
prospects_2026 <- prospects_2026 |>
  select(-any_of(setdiff(names(prog_feats_2026), "player_name"))) |>
  left_join(prog_feats_2026, by = "player_name")

# ============================================================================
# C2) COLLEGE PRODUCTION FEATURES (2025 cfbfastR stats)
# ============================================================================
# 01c_load_college_stats.R exports per-player rate stats keyed by
# (name_norm, college_norm) — no draft record needed. Fuzzy-match 2026
# prospects by name + college, then compute percentile ranks within the 2026
# cohort by model_group — same within-(season × model_group) ranking used
# during training.
# ============================================================================
cli::cli_h1("Joining 2025 college production stats")

# Normalization helpers — must match 01c_load_college_stats.R exactly
normalize_name_local <- function(x) {
  x |>
    str_to_lower() |>
    str_remove_all("\\s+(jr\\.?|sr\\.?|ii|iii|iv)$") |>
    str_remove_all("[^a-z ]") |>
    str_squish()
}

normalize_college_local <- function(x) {
  x |>
    canonicalize_college() |>   # must match normalize_college() in 01c exactly
    str_to_lower() |>
    str_remove_all("\\.") |>
    str_squish()
}

stats_base <- tryCatch(
  read_rds("data/01c_player_stats_base.rds"),
  error = function(e) {
    cli::cli_alert_warning(
      "data/01c_player_stats_base.rds not found — run 01c_load_college_stats.R first"
    )
    NULL
  }
)

# Reverse alias: legal name (from nflreadr) → cfbfastR name for stats lookup.
# Inverse of name_aliases defined in A2. Also used to restore display names at output.
college_stats_name_overrides <- setNames(names(name_aliases), name_aliases)

if (!is.null(stats_base)) {
  prospects_2026 <- prospects_2026 |>
    mutate(
      .name_norm    = normalize_name_local(
                        coalesce(college_stats_name_overrides[player_name], player_name)
                      ),
      .college_norm = normalize_college_local(school)
    )

  # Exact match on normalized name + college
  exact_stats <- inner_join(
    prospects_2026 |> select(player_name, .name_norm, .college_norm),
    stats_base,
    by = c(".name_norm" = "name_norm", ".college_norm" = "college_norm")
  )

  # Fuzzy match remaining (Levenshtein ≤ 2, college as tiebreaker)
  unmatched_stats <- prospects_2026 |>
    filter(!player_name %in% exact_stats$player_name) |>
    select(player_name, .name_norm, .college_norm)

  if (nrow(unmatched_stats) > 0) {
    fuzzy_stats <- stringdist_left_join(
      unmatched_stats, stats_base,
      by           = c(".name_norm" = "name_norm"),
      max_dist     = 2, method = "lv",
      distance_col = ".name_dist"
    ) |>
      mutate(
        .col_dist = stringdist::stringdist(.college_norm, coalesce(college_norm, ""), method = "lv")
      ) |>
      group_by(player_name) |>
      slice_min(.name_dist + 0.01 * .col_dist, n = 1, with_ties = FALSE) |>
      ungroup() |>
      select(-name_norm, -.name_dist, -.col_dist)
  } else {
    fuzzy_stats <- tibble(player_name = character(0))
  }

  stats_matched <- bind_rows(exact_stats, fuzzy_stats) |>
    select(-any_of(c(".name_norm", ".college_norm", "name_norm", "college_norm")))

  n_stat_matched <- sum(
    !is.na(stats_matched$qb_ypa) | !is.na(stats_matched$rush_ypc) |
    !is.na(stats_matched$rec_ypr) | !is.na(stats_matched$def_tot),
    na.rm = TRUE
  )
  cli::cli_alert_info(
    "{n_stat_matched} / {nrow(prospects_2026)} prospects matched to college production stats"
  )

  # Rename conf_tier before joining to avoid column collision with B5's NA_character_
  if ("conf_tier" %in% names(stats_matched)) {
    stats_matched <- stats_matched |> rename(conf_tier_stats = conf_tier)
  }

  # Drop stale college stat columns, then join fresh stats
  stat_cols <- setdiff(names(stats_matched), "player_name")
  prospects_2026 <- prospects_2026 |>
    select(-.name_norm, -.college_norm, -any_of(stat_cols)) |>
    left_join(stats_matched, by = "player_name")

  # Overwrite conf_tier (set to NA in B5) with matched value where available
  if ("conf_tier_stats" %in% names(prospects_2026)) {
    prospects_2026 <- prospects_2026 |>
      mutate(conf_tier = coalesce(conf_tier_stats, conf_tier)) |>
      select(-conf_tier_stats)
  }

  # Position masking — same logic as 02_feature_engineering.R B2
  prospects_2026 <- prospects_2026 |>
    mutate(
      across(any_of(c("qb_cmp_pct", "qb_ypa", "qb_td_pct", "qb_int_pct",
                       "qb_ypa_yr1", "qb_ypa_yr2", "qb_int_pct_yr1", "qb_int_pct_yr2")),
             ~ if_else(model_group == "qb", .x, NA_real_)),
      across(any_of(c("rush_ypc", "rush_att", "rush_ypc_yr1", "rush_ypc_yr2")),
             ~ if_else(model_group %in% c("qb", "rb", "wr_te"), .x, NA_real_)),
      across(any_of(c("rec_ypr", "rec_rec", "rec_td", "rec_ypr_yr1", "rec_ypr_yr2")),
             ~ if_else(model_group %in% c("rb", "wr_te"), .x, NA_real_)),
      across(any_of(c("def_tot", "def_sacks", "def_tfl", "def_pbu",
                       "def_tot_yr1", "def_tot_yr2")),
             ~ if_else(model_group %in% c("dl", "lb", "cb", "s"), .x, NA_real_)),
      across(any_of(c("int_int", "int_yds")),
             ~ if_else(model_group %in% c("lb", "cb", "s"), .x, NA_real_)),
      across(any_of("rec_yds_share"),
             ~ if_else(model_group %in% c("wr_te", "rb"), .x, NA_real_)),
      across(any_of("rush_yds_share"),
             ~ if_else(model_group == "rb", .x, NA_real_)),
      across(any_of("qb_yds_per_play"),
             ~ if_else(model_group == "qb", .x, NA_real_))
    )

  # YOY change values — same formula as 02_feature_engineering.R B3
  prospects_2026 <- prospects_2026 |>
    mutate(
      qb_ypa_yoy = if_else(
        !is.na(qb_ypa_yr1) & !is.na(qb_ypa_yr2) & qb_ypa_yr2 > 0,
        (qb_ypa_yr1 - qb_ypa_yr2) / qb_ypa_yr2, NA_real_),
      qb_int_pct_yoy = if_else(
        !is.na(qb_int_pct_yr1) & !is.na(qb_int_pct_yr2) & qb_int_pct_yr2 > 0,
        -((qb_int_pct_yr1 - qb_int_pct_yr2) / qb_int_pct_yr2), NA_real_),
      rec_ypr_yoy = if_else(
        !is.na(rec_ypr_yr1) & !is.na(rec_ypr_yr2) & rec_ypr_yr2 > 0,
        (rec_ypr_yr1 - rec_ypr_yr2) / rec_ypr_yr2, NA_real_),
      rush_ypc_yoy = if_else(
        !is.na(rush_ypc_yr1) & !is.na(rush_ypc_yr2) & rush_ypc_yr2 > 0,
        (rush_ypc_yr1 - rush_ypc_yr2) / rush_ypc_yr2, NA_real_),
      def_tot_yoy = if_else(
        !is.na(def_tot_yr1) & !is.na(def_tot_yr2) & def_tot_yr2 > 0,
        (def_tot_yr1 - def_tot_yr2) / def_tot_yr2, NA_real_)
    )

  # Percentile ranks within 2026 cohort by model_group
  # Mirrors within-(season × model_group) ranking from training
  .pass_rec_base <- c("qb_cmp_pct", "qb_ypa", "qb_td_pct", "qb_int_pct",
                       "rush_ypc", "rush_att", "rec_ypr", "rec_rec", "rec_td")
  .def_int_base  <- c("def_tot", "def_sacks", "def_tfl", "def_pbu",
                       "int_int", "int_yds")
  .yoy_base      <- c("qb_ypa_yoy", "qb_int_pct_yoy", "rec_ypr_yoy",
                       "rush_ypc_yoy", "def_tot_yoy")
  .dom_base      <- c("rec_yds_share", "rush_yds_share", "qb_yds_per_play")

  prospects_2026 <- prospects_2026 |>
    group_by(model_group) |>
    mutate(
      across(
        any_of(c(.pass_rec_base, .def_int_base, .yoy_base, .dom_base)),
        percent_rank,
        .names = "{.col}_pctile"
      )
    ) |>
    ungroup()

  # Re-rank rec_* and rush_* within (model_group, position) for wr_te split
  # WR and TE are on different scales — position-level ranking fixes both signals
  for (.pcol in c("rec_ypr_pctile", "rec_rec_pctile", "rec_td_pctile",
                   "rush_ypc_pctile", "rush_att_pctile")) {
    .base <- str_remove(.pcol, "_pctile")
    if (.base %in% names(prospects_2026) && .pcol %in% names(prospects_2026)) {
      prospects_2026 <- prospects_2026 |>
        group_by(model_group, position) |>
        mutate(
          !!.pcol := if_else(
            model_group == "wr_te",
            percent_rank(.data[[.base]]),
            .data[[.pcol]]
          )
        ) |>
        ungroup()
    }
  }

  cli::cli_alert_success("College production features computed for 2026 cohort")
} else {
  cli::cli_alert_warning(
    "Skipping college stats — run 01c_load_college_stats.R to generate data/01c_player_stats_base.rds"
  )
}

# ============================================================================
# D) SCORE
# ============================================================================
cli::cli_h1("Scoring 2026 prospects")

scored_2026 <- prospects_2026 |>
  filter(!is.na(model_group)) |>
  group_by(model_group) |>
  group_split() |>
  map_dfr(function(group_df) {
    gname <- unique(group_df$model_group)
    model <- best_models[[gname]]

    if (is.null(model)) {
      cli::cli_alert_warning("No model for group: {gname}")
      return(mutate(group_df, .pred = NA_real_))
    }

    cli::cli_alert_info("Scoring {gname} (n = {nrow(group_df)})")
    preds <- predict(model, new_data = group_df |>
                       select(position_in_group, all_of(shared_features)))
    bind_cols(group_df, preds)
  })

# Boom/bust probabilities:
#   - threshold = 1 training SD of av_residual_z (the boom/bust classification boundary)
#   - uncertainty = model CV RMSE (how wide the predictive distribution is)
scored_2026 <- scored_2026 |>
  group_by(model_group) |>
  mutate(
    group_resid_sd   = sd(
      draft_fe$av_residual_z[
        draft_fe$model_group == unique(model_group) &
        draft_fe$season %in% DRAFT_YEARS_TRAIN
      ],
      na.rm = TRUE
    ),
    pred_uncertainty = results[[unique(model_group)]]$comparison |>
      filter(algorithm == "xgboost") |>
      pull(rmse),
    p_boom     = pnorm( group_resid_sd, mean = .pred, sd = pred_uncertainty, lower.tail = FALSE),
    p_bust     = pnorm(-group_resid_sd, mean = .pred, sd = pred_uncertainty, lower.tail = TRUE),
    p_expected = 1 - p_boom - p_bust,
    model_verdict = case_when(
      p_boom > 0.40  ~ "BOOM",
      p_bust > 0.40  ~ "BUST RISK",
      p_boom > 0.25  ~ "Upside",
      p_bust > 0.25  ~ "Caution",
      TRUE           ~ "Baseline"
    )
  ) |>
  ungroup() |>
  arrange(pick_est)

# ============================================================================
# E) OUTPUT
# ============================================================================
cli::cli_h1("Writing outputs")

# Restore display names: swap legal names back to commonly known nicknames
# so player cards show the name fans recognize (e.g., "Sonny Styles" not "Alex Styles").
# college_stats_name_overrides is the inverse of name_aliases (legal → nickname).
scored_2026 <- scored_2026 |>
  mutate(player_name = coalesce(college_stats_name_overrides[player_name], player_name))

player_cards <- scored_2026 |>
  transmute(
    player        = player_name,
    position      = position,
    school        = school,
    model_group   = model_group,
    pick_est      = pick_est,
    status        = status,
    predicted_z   = round(.pred, 2),
    p_boom        = scales::percent(p_boom,      accuracy = 0.1),
    p_bust        = scales::percent(p_bust,       accuracy = 0.1),
    p_expected    = scales::percent(p_expected,   accuracy = 0.1),
    verdict       = model_verdict,
    n_combine_tests = n_combine_tests,
    athleticism   = case_when(
      is.na(athleticism_composite)       ~ "No combine data",
      athleticism_composite >  1.0       ~ "Elite athlete",
      athleticism_composite >  0.5       ~ "Above-average athlete",
      athleticism_composite > -0.5       ~ "Average athlete",
      athleticism_composite > -1.0       ~ "Below-average athlete",
      TRUE                               ~ "Limited athletic profile"
    ),
    program_note  = case_when(
      prog_pos_n >= 5 & prog_pos_boom_rate > 0.30 ~
        glue::glue("{school} {position} pipeline: {prog_pos_n} drafted, {scales::percent(prog_pos_boom_rate)} boom rate"),
      prog_pos_n >= 5 & prog_pos_bust_rate > 0.40 ~
        glue::glue("{school} {position} pipeline: caution — {scales::percent(prog_pos_bust_rate)} bust rate"),
      prog_pos_n < 3 ~
        glue::glue("{school} has limited {position} draft history ({prog_pos_n} players)"),
      TRUE ~
        glue::glue("{school} {position} pipeline: {prog_pos_n} drafted, avg AV {round(prog_pos_av_mean, 1)}")
    )
  )

write_csv(player_cards, "output/2026_player_cards.csv")
cli::cli_alert_success("Saved output/2026_player_cards.csv ({nrow(player_cards)} prospects)")

# Save full scored data for downstream content scripts (SHAP, etc.)
saveRDS(scored_2026, "data/05_scored_2026.rds")
cli::cli_alert_success("Saved data/05_scored_2026.rds")

# Preview: R1/R2 prospects by boom probability
cli::cli_h2("R1/R2 boom leaderboard")
player_cards |>
  filter(pick_est <= 64) |>
  arrange(desc(readr::parse_number(p_boom))) |>
  select(player, position, school, pick_est, verdict, p_boom, p_bust) |>
  head(20) |>
  print()

cli::cli_h2("R1/R2 bust risk leaderboard")
player_cards |>
  filter(pick_est <= 64) |>
  arrange(desc(readr::parse_number(p_bust))) |>
  select(player, position, school, pick_est, verdict, p_boom, p_bust) |>
  head(20) |>
  print()

# ============================================================================
# F) SHAP VALUES — per-player feature attribution
# ============================================================================
# Requires: install.packages("shapviz")
# Produces:
#   - output/figures/shap/{group}_importance.png  — beeswarm across all prospects
#   - output/figures/shap/{group}_waterfall_{player}.png — per-player waterfall
#
# bake() on new_data drops the outcome column (av_residual_z is not in baked),
# so X_pred = data.matrix(baked) directly. any_of() guards against the outcome
# appearing in baked for any reason (e.g. if called with training data).

if (requireNamespace("shapviz", quietly = TRUE)) {
  library(shapviz)
  dir.create("output/figures/shap", showWarnings = FALSE, recursive = TRUE)

  cli::cli_h1("Computing SHAP values")

  walk(names(best_models), function(gname) {
    model     <- best_models[[gname]]
    group_raw <- scored_2026 |> filter(model_group == gname)

    if (nrow(group_raw) == 0) return(invisible(NULL))

    pred_input <- group_raw |> select(position_in_group, all_of(shared_features))
    rec        <- extract_recipe(model)
    baked      <- bake(rec, new_data = pred_input)

    # Outcome is dropped by bake(); any_of() is belt-and-suspenders
    X_mat <- baked |> select(-any_of("av_residual_z")) |> data.matrix()

    shp <- shapviz(extract_fit_engine(model), X_pred = X_mat, X = baked)

    # Group-level beeswarm (feature importance with directionality)
    p_bee <- sv_importance(shp, kind = "beeswarm", max_display = 15L) +
      ggplot2::labs(title = glue::glue("{gname} — SHAP feature importance (2026 prospects)"))
    ggplot2::ggsave(
      glue::glue("output/figures/shap/{gname}_importance.png"),
      p_bee, width = 10, height = 7
    )

    # Per-player waterfall for R1/R2 prospects (pick_est <= 64)
    r1r2_idx <- which(group_raw$pick_est <= 64)
    walk(r1r2_idx, function(i) {
      pname <- str_replace_all(group_raw$player_name[[i]], "[^A-Za-z]", "_")
      p_wf  <- sv_waterfall(shp, row_id = i) +
        ggplot2::labs(
          title    = glue::glue("{group_raw$player_name[[i]]} ({gname}, pick ~{group_raw$pick_est[[i]]})"),
          subtitle = glue::glue("Predicted z: {round(group_raw$.pred[[i]], 2)}")
        )
      ggplot2::ggsave(
        glue::glue("output/figures/shap/{gname}_waterfall_{pname}.png"),
        p_wf, width = 9, height = 6
      )
    })

    cli::cli_alert_success("SHAP saved for {gname} ({length(r1r2_idx)} waterfalls)")
  })
} else {
  cli::cli_alert_info("shapviz not installed — skipping SHAP. Run: install.packages('shapviz')")
}
