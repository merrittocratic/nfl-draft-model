# ============================================================================
# 01d — Supplemental CFB Defensive Stats (Sports Reference)
#
# Problem: cfbfastR defensive data only goes back to 2016 college seasons,
# leaving draft classes 2006–2016 with zero college production coverage for
# LB, DL, CB, and S. This script fills that gap.
#
# Source: Sports Reference CFB season defense pages
#   https://www.sports-reference.com/cfb/seasons/{year}-defense.html
#   One page per season — no pagination needed, all players in one table.
#
# Coverage: 2002–2015 college seasons (supporting 2004–2016 draft classes)
# Output:   data/01d_cfb_defense_supplemental.rds
#           One row per player-season, same column structure as cfbfastR
#           defensive data — drop-in merge in 01c_load_college_stats.R
#
# Run once; results are HTML-cached to data/cfb_defense_cache/
# ============================================================================
source("00_config.R")
library(rvest)
library(polite)

CACHE_DIR <- "data/cfb_defense_cache"
# 2002 supports earliest training draft class (2006 — 4 years of eligibility)
# Stop at 2015 — cfbfastR picks up from 2016
SEASONS   <- 2002:2015
OUTPUT    <- "data/01d_cfb_defense_supplemental.rds"

dir.create(CACHE_DIR, showWarnings = FALSE, recursive = TRUE)

# ============================================================================
# A) NORMALIZE HELPERS (same logic as 01c — must stay in sync)
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

safe_num <- function(x) suppressWarnings(as.numeric(str_remove_all(as.character(x), "[^0-9.]")))

# ============================================================================
# B) SCRAPE PER-SEASON DEFENSE PAGES
#
# SR CFB defense pages use a two-row <thead>:
#   Row 1: group labels (Tackles, Loss, Fumbles, Interceptions, ...)
#   Row 2: actual column names (Rk, Player, School, Conf, G, Solo, Ast, ...)
# html_table(header=FALSE) returns both rows as data — we find and extract
# the real header by detecting the row containing "Player" in col 2.
#
# Repeated header rows appear every ~25 rows in the table body — filtered
# out by keeping only rows where Rk parses as a number.
# ============================================================================

scrape_season_defense <- function(year) {
  cache_file <- file.path(CACHE_DIR, glue::glue("defense_{year}.html"))
  url        <- glue::glue("https://www.sports-reference.com/cfb/seasons/{year}-defense.html")

  if (file.exists(cache_file)) {
    cli::cli_alert_info("Cache hit: {year}")
    page <- read_html(cache_file)
  } else {
    cli::cli_alert_info("Scraping: {year} ...")
    session <- bow(url, user_agent = "nfl-draft-model research / educational use")
    page    <- scrape(session)

    if (is.null(page)) {
      cli::cli_alert_warning("Failed to retrieve page for {year} — skipping")
      return(NULL)
    }

    xml2::write_html(page, cache_file)
    Sys.sleep(4)  # stay well under SR's ~20 req/min limit
  }

  tbl_raw <- tryCatch(
    page |> html_element("#defense") |> html_table(header = FALSE),
    error = function(e) {
      cli::cli_alert_warning("Table parse failed for {year}: {conditionMessage(e)}")
      NULL
    }
  )

  if (is.null(tbl_raw) || nrow(tbl_raw) < 3) {
    cli::cli_alert_warning("Empty or missing table for {year}")
    return(NULL)
  }

  # Locate the true column header row — it contains "Player" in column 2
  header_idx <- which(tbl_raw[[2]] == "Player")
  if (length(header_idx) == 0) {
    cli::cli_alert_warning("Could not find header row for {year} — skipping")
    return(NULL)
  }
  header_idx <- header_idx[1]

  names(tbl_raw) <- as.character(tbl_raw[header_idx, ])

  # Keep only real data rows: Rk must be numeric (filters header repetitions + blanks)
  tbl <- tbl_raw |>
    slice(-seq_len(header_idx)) |>
    filter(!is.na(suppressWarnings(as.integer(Rk))))

  if (nrow(tbl) == 0) {
    cli::cli_alert_warning("No data rows after cleaning for {year}")
    return(NULL)
  }

  cli::cli_alert_success("{year}: {nrow(tbl)} player-seasons")
  tbl |> mutate(season = year)
}

cli::cli_h1("Scraping SR CFB defensive stats ({min(SEASONS)}–{max(SEASONS)})")
raw_pages <- map(SEASONS, scrape_season_defense)
raw_sr    <- bind_rows(compact(raw_pages))

cli::cli_alert_success(
  "Scraped {nrow(raw_sr)} player-seasons across {n_distinct(raw_sr$season)} seasons"
)

# ============================================================================
# C) STANDARDIZE COLUMNS
#
# SR CFB defense table columns (2002–2015):
#   Rk, Player, School, Conf, G, Solo, Ast, Tot, TFL, Sacks,
#   FR, FF, Int, Yds, Avg, TD, PD
#
# "PD" (passes defended) may be absent in very early seasons — defaulted NA.
# Column names match the cfbfastR naming convention used in 01c so bind_rows
# works without renaming on the receiving side.
# ============================================================================

defense_clean <- raw_sr |>
  transmute(
    season,
    name_norm       = normalize_name(Player),
    college_norm    = normalize_college(School),
    conference      = Conf,
    defensive_solo  = safe_num(Solo),
    defensive_ast   = safe_num(Ast),
    defensive_tot   = safe_num(Tot),
    defensive_tfl   = safe_num(TFL),
    defensive_sacks = safe_num(Sacks),
    defensive_pd    = if ("PD" %in% names(raw_sr)) safe_num(PD) else NA_real_
  ) |>
  filter(
    !is.na(name_norm), name_norm != "",
    !is.na(defensive_tot), defensive_tot > 0
  )

cli::cli_alert_info("Clean player-seasons: {nrow(defense_clean)}")
cli::cli_alert_info("Season range: {min(defense_clean$season)}–{max(defense_clean$season)}")

# Quick sanity check — should see recognizable Power 4 names
cli::cli_alert_info("Sample (2006 season):")
defense_clean |>
  filter(season == 2006) |>
  arrange(desc(defensive_tot)) |>
  select(name_norm, college_norm, defensive_tot, defensive_sacks, defensive_tfl) |>
  head(10) |>
  print()

# ============================================================================
# D) SAVE
# ============================================================================
write_rds(defense_clean, OUTPUT)
cli::cli_alert_success("Saved {OUTPUT} ({nrow(defense_clean)} rows)")
cli::cli_alert_info("Next: re-run 01c_load_college_stats.R — it will merge this automatically")
