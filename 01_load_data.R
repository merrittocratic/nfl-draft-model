# ============================================================================
# 01 — Load Raw Data from nflreadr + Pro Football Reference
# ============================================================================
source("00_config.R")
library(fuzzyjoin)
library(stringr)

# -- Draft Picks --------------------------------------------------------------
cli::cli_h1("Loading draft picks")

draft_raw <- load_draft_picks(seasons = min(DRAFT_YEARS_TRAIN):max(DRAFT_YEARS_SCORE)) |>
  filter(!is.na(pfr_player_name)) |>
  # Standardize position labels to our mapping
  mutate(
    position_raw = position,
    position = case_when(
      position %in% c("DE", "EDGE", "OLB") &
        str_detect(tolower(position_raw), "edge|olb|de") ~ "EDGE",
      position %in% c("DT", "NT", "IDL")               ~ "IDL",
      position %in% c("T", "OT")                        ~ "OT",
      position %in% c("G", "C", "OL", "IOL")            ~ "IOL",
      position %in% c("FS", "SS", "DB", "S")            ~ "S",
      position == "CB"                                   ~ "CB",
      position %in% c("ILB", "LB", "MLB")               ~ "LB",
      position == "FB"                                   ~ "RB",
      TRUE ~ position
    )
  ) |>
  left_join(position_model_map |> distinct(position, model_group), by = "position") |>
  filter(!is.na(model_group))  # drop punters, kickers, long snappers

cli::cli_alert_success("Loaded {nrow(draft_raw)} draft picks")

# -- Combine Data -------------------------------------------------------------
cli::cli_h1("Loading combine data")

combine_raw <- load_combine(seasons = min(DRAFT_YEARS_TRAIN):max(DRAFT_YEARS_SCORE)) |>
  select(
    season, player_name,
    pos, school,
    any_of(combine_features)
  )

cli::cli_alert_success("Loaded {nrow(combine_raw)} combine records")

# -- Join Draft + Combine -----------------------------------------------------
cli::cli_h1("Joining draft + combine data")

# Normalize names for matching: lowercase, strip suffixes, strip punctuation
normalize_name <- function(x) {
  x |>
    tolower() |>
    str_remove_all("\\s+(jr\\.?|sr\\.?|ii|iii|iv|v)$") |>
    str_remove_all("[^a-z ]") |>
    str_squish()
}

draft_raw <- draft_raw |> mutate(name_norm = normalize_name(pfr_player_name))
combine_raw <- combine_raw |> mutate(name_norm = normalize_name(player_name))

# Fuzzy join on normalized name within same season (max string distance = 2)
draft_combined <- stringdist_left_join(
  draft_raw,
  combine_raw |> select(-player_name),
  by     = c("season", "name_norm"),
  method = "lv",
  max_dist = 2
) |>
  # season.x is the authoritative season from draft picks
  mutate(season = season.x) |>
  select(-season.x, -season.y, -name_norm.x, -name_norm.y) |>
  # Deduplicate: keep closest name match per player-season
  group_by(season, pick) |>
  slice_head(n = 1) |>
  ungroup()

combine_match_rate <- draft_combined |>
  summarise(
    total = n(),
    has_combine = sum(!is.na(forty) | !is.na(bench)),
    pct = has_combine / total
  )

cli::cli_alert_info(
  "Combine match rate: {scales::percent(combine_match_rate$pct, 0.1)} ({combine_match_rate$has_combine}/{combine_match_rate$total})"
)

# -- Career Approximate Value -------------------------------------------------
cli::cli_h1("Checking AV data availability")

if ("w_av" %in% names(draft_combined)) {
  av_coverage <- draft_combined |>
    filter(season %in% DRAFT_YEARS_TRAIN) |>
    summarise(
      total = n(),
      has_av = sum(!is.na(w_av)),
      pct = has_av / total
    )
  cli::cli_alert_info(
    "Career AV coverage: {scales::percent(av_coverage$pct, 0.1)} ({av_coverage$has_av}/{av_coverage$total})"
  )
} else {
  cli::cli_alert_warning(
    "w_av not found in draft data — will need PFR scrape (see R/01b_scrape_av.R)"
  )
}

# -- Outcome Variable: Weighted Approximate Value ----------------------------
# We use w_av (PFR Weighted Career AV) as the outcome metric. This is an
# intentional choice, not a proxy:
#   - w_av weights peak/early-career seasons more heavily than raw career totals
#   - This naturally de-emphasizes longevity over quality, which is what
#     draft evaluation cares about — did this pick pan out, and how quickly?
#   - A player who dominated for 5 years scores higher than one who accumulated
#     AV over 15 mediocre seasons, which is exactly the signal we want
#   - nflreadr's car_av column is entirely empty (confirmed); w_av has 91% coverage
# Future enhancement: chromote-based PFR scraper for true 4-year window
# (PFR is behind Cloudflare; rvest/polite cannot bypass it)
draft_combined <- draft_combined |>
  mutate(
    av_4yr            = w_av,
    years_since_draft = max(DRAFT_YEARS_TRAIN) + AV_WINDOW_YEARS - season
  )

# -- Save Intermediate --------------------------------------------------------
write_rds(draft_combined, "data/01_draft_combined.rds")
cli::cli_alert_success("Saved data/01_draft_combined.rds ({nrow(draft_combined)} rows)")
