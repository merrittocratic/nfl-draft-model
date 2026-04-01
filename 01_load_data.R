# ============================================================================
# 01 — Load Raw Data from nflreadr + Pro Football Reference
#
# Pipeline order:
#   Run 01b_scrape_av.R FIRST to generate data/01b_av_4yr.rds
#   Then run this script.
#
# Output: data/01_draft_combined.rds
#   One row per drafted player (2006–2026 classes)
#   Outcome variable: av_4yr (4-year windowed AV from PFR, via 01b)
#
# NOTE on DB position resolution:
#   nflreadr labels many CBs and Safeties as generic "DB" in older draft
#   classes. We resolve these AFTER the combine join using the combine's
#   `pos` column, which has correct CB/S labels for ~75% of DB players.
#   Unresolvable DBs (no combine match) are excluded from modeling.
# ============================================================================
source("00_config.R")
library(fuzzyjoin)
library(stringr)

# ============================================================================
# A) DRAFT PICKS — initial standardization (leave DB unresolved for now)
# ============================================================================
cli::cli_h1("Loading draft picks")

draft_raw <- load_draft_picks(seasons = min(DRAFT_YEARS_TRAIN):max(DRAFT_YEARS_SCORE)) |>
  filter(!is.na(pfr_player_name)) |>
  mutate(
    position_raw = position,
    position = case_when(
      position %in% c("DE", "EDGE", "OLB") &
        str_detect(tolower(position_raw), "edge|olb|de") ~ "EDGE",
      position %in% c("DT", "NT", "IDL")               ~ "IDL",
      position %in% c("T", "OT")                        ~ "OT",
      position %in% c("G", "C", "OL", "IOL")            ~ "IOL",
      position %in% c("FS", "SS", "S")                  ~ "S",
      position == "CB"                                   ~ "CB",
      position == "DB"                                   ~ "DB",   # resolved after combine join
      position %in% c("ILB", "LB", "MLB")               ~ "LB",
      position == "FB"                                   ~ "RB",
      TRUE ~ position
    )
  )

cli::cli_alert_success("Loaded {nrow(draft_raw)} draft picks")

# ============================================================================
# B) COMBINE DATA
# ============================================================================
cli::cli_h1("Loading combine data")

combine_raw <- load_combine(seasons = min(DRAFT_YEARS_TRAIN):max(DRAFT_YEARS_SCORE)) |>
  select(
    season, player_name,
    pos, school,
    any_of(combine_features)
  )

cli::cli_alert_success("Loaded {nrow(combine_raw)} combine records")

# ============================================================================
# C) JOIN DRAFT + COMBINE (fuzzy name match within season)
# ============================================================================
cli::cli_h1("Joining draft + combine data")

normalize_name <- function(x) {
  x |>
    tolower() |>
    str_remove_all("\\s+(jr\\.?|sr\\.?|ii|iii|iv|v)$") |>
    str_remove_all("[^a-z ]") |>
    str_squish()
}

draft_raw   <- draft_raw   |> mutate(name_norm = normalize_name(pfr_player_name))
combine_raw <- combine_raw |> mutate(name_norm = normalize_name(player_name))

draft_combined <- stringdist_left_join(
  draft_raw,
  combine_raw |> select(-player_name),
  by       = c("season", "name_norm"),
  method   = "lv",
  max_dist = 2
) |>
  mutate(season = season.x) |>
  select(-season.x, -season.y, -name_norm.x, -name_norm.y) |>
  group_by(season, pick) |>
  slice_head(n = 1) |>
  ungroup()

combine_match_rate <- draft_combined |>
  summarise(
    total       = n(),
    has_combine = sum(!is.na(forty) | !is.na(bench)),
    pct         = has_combine / total
  )

cli::cli_alert_info(
  "Combine match rate: {scales::percent(combine_match_rate$pct, 0.1)} ",
  "({combine_match_rate$has_combine}/{combine_match_rate$total})"
)

# ============================================================================
# D) RESOLVE GENERIC "DB" LABELS USING COMBINE pos
# ============================================================================
cli::cli_h1("Resolving generic DB position labels")

draft_combined <- draft_combined |>
  mutate(
    position = case_when(
      position == "DB" & pos == "CB"              ~ "CB",
      position == "DB" & pos %in% c("S","FS","SS") ~ "S",
      TRUE ~ position   # all non-DB positions unchanged
    )
  )

db_resolved <- draft_combined |>
  filter(position_raw == "DB") |>
  count(position) |>
  mutate(position = if_else(position == "DB", "unresolved (excluded)", position))

cli::cli_alert_info("DB label resolution:")
print(db_resolved)

# ============================================================================
# E) ASSIGN MODEL GROUP (after DB resolution)
# ============================================================================

draft_combined <- draft_combined |>
  left_join(position_model_map |> distinct(position, model_group), by = "position") |>
  filter(!is.na(model_group))  # drops punters, kickers, unresolved DBs

cli::cli_alert_success(
  "{nrow(draft_combined)} players after model group assignment"
)

# Spot check: DB position group counts (should now be realistic)
cli::cli_alert_info("model_group counts (cb/s split check):")
draft_combined |>
  filter(model_group %in% c("cb", "s"), season %in% DRAFT_YEARS_TRAIN) |>
  count(model_group, round_num) |>
  filter(round_num == 1) |>
  print()

# ============================================================================
# F) JOIN 4-YEAR WINDOWED AV FROM 01b
# ============================================================================
cli::cli_h1("Joining 4-year windowed AV (from 01b_scrape_av.R)")

if (!file.exists("data/01b_av_4yr.rds")) {
  cli::cli_abort("data/01b_av_4yr.rds not found. Run 01b_scrape_av.R first.")
}

av_4yr_data <- read_rds("data/01b_av_4yr.rds") |>
  select(pfr_id, av_4yr_total, av_yr1, av_yr2, av_yr3, av_yr4,
         seasons_active_4yr, n_teams_4yr)

draft_combined <- draft_combined |>
  left_join(av_4yr_data, by = c("pfr_player_id" = "pfr_id")) |>
  mutate(av_4yr = av_4yr_total) |>
  select(-av_4yr_total)

av_coverage <- draft_combined |>
  filter(season %in% DRAFT_YEARS_TRAIN) |>
  summarise(
    total  = n(),
    has_av = sum(!is.na(av_4yr)),
    pct    = has_av / total
  )

cli::cli_alert_success(
  "4yr AV coverage (training): {scales::percent(av_coverage$pct, 0.1)} ",
  "({av_coverage$has_av}/{av_coverage$total})"
)

cli::cli_alert_info("av_4yr distribution (training classes):")
draft_combined |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(av_4yr)) |>
  pull(av_4yr) |>
  summary() |>
  print()

# ============================================================================
# G) SAVE
# ============================================================================
write_rds(draft_combined, "data/01_draft_combined.rds")
cli::cli_alert_success(
  "Saved data/01_draft_combined.rds ({nrow(draft_combined)} rows)"
)
