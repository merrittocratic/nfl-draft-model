# ============================================================================
# 01e — Pro Day / Combine Measurements (MockDraftable API)
#
# Fetches combine + pro day measurements from MockDraftable.com's open JSON API.
# API is open-source: github.com/marcusdarmstrong/mockdraftable-web
#
# measurableKey mapping:
#   1=height  2=weight  8=forty  9=bench  10=vertical
#   11=broad_jump  12=cone  13=shuttle
# source: 1 = Combine, 2 = Pro Day
#
# Two-phase approach:
#   Phase 1 — Name resolution: player name → MockDraftable slug via /api/typeahead
#   Phase 2 — Data fetch: slug → measurements via /api/multiple-players (batched)
#
# Both phases are file-cached — safe to re-run, only fetches what's missing.
#
# Output: data/01e_pro_day.rds  (one row per player, wide format with _src columns)
#         data/01e_pro_day.csv  (for inspection)
# ============================================================================
source("00_config.R")
library(httr)
library(jsonlite)
library(glue)

CACHE_DIR     <- "data/mockdraftable_cache"
SLUG_CACHE    <- file.path(CACHE_DIR, "slug_map.rds")
PLAYER_CACHE  <- file.path(CACHE_DIR, "players.rds")
OUTPUT_RDS    <- "data/01e_pro_day.rds"
OUTPUT_CSV    <- "data/01e_pro_day.csv"
BASE_URL      <- "https://www.mockdraftable.com/api"
BATCH_SIZE    <- 50L

dir.create(CACHE_DIR, showWarnings = FALSE, recursive = TRUE)

# measurableKey → our column names
MEASURABLE_MAP <- c(
  "1"  = "ht_md",      # height in inches (md = mockdraftable, to avoid collision)
  "2"  = "wt_md",
  "8"  = "forty",
  "9"  = "bench",
  "10" = "vertical",
  "11" = "broad_jump",
  "12" = "cone",
  "13" = "shuttle"
)

# ============================================================================
# A) HELPERS
# ============================================================================

md_get <- function(url, ...) {
  resp <- GET(
    url,
    add_headers(
      `Accept`          = "application/json",
      `User-Agent`      = "Merrittocracy draft research (themerrittocracy.substack.com)"
    ),
    ...
  )
  if (http_error(resp)) {
    cli::cli_alert_warning("HTTP {status_code(resp)}: {url}")
    return(NULL)
  }
  content(resp, as = "text", encoding = "UTF-8") |> fromJSON(simplifyVector = TRUE)
}

normalize_name <- function(x) {
  x |>
    str_to_lower() |>
    str_remove_all("\\s+(jr\\.?|sr\\.?|ii|iii|iv|v)$") |>
    str_remove_all("[^a-z ]") |>
    str_squish()
}

# ============================================================================
# B) LOAD PLAYERS
# ============================================================================
cli::cli_h1("Loading players from draft_combined")

draft_combined <- read_rds("data/01_draft_combined.rds")

players <- draft_combined |>
  filter(season %in% c(DRAFT_YEARS_TRAIN, DRAFT_YEARS_SCORE)) |>
  select(pfr_player_id, pfr_player_name, season, pos) |>
  distinct() |>
  mutate(name_norm = normalize_name(pfr_player_name))

cli::cli_alert_info("{nrow(players)} players to look up")

# ============================================================================
# C) PHASE 1 — NAME RESOLUTION (typeahead → slug)
# Cached in slug_map.rds: name_norm + season → slug
# ============================================================================
cli::cli_h1("Phase 1: Name resolution via typeahead")

slug_map <- if (file.exists(SLUG_CACHE)) {
  read_rds(SLUG_CACHE)
} else {
  tibble(
    pfr_player_id = character(),
    name_norm     = character(),
    season        = integer(),
    pos           = character(),
    slug          = character(),
    slug_verified = logical()
  )
}

# Only look up players not yet in cache
to_resolve <- players |>
  anti_join(slug_map |> filter(!is.na(slug)), by = c("pfr_player_id"))

cli::cli_alert_info("{nrow(to_resolve)} players need slug resolution ({nrow(players) - nrow(to_resolve)} already cached)")

if (nrow(to_resolve) > 0) {
  for (i in seq_len(nrow(to_resolve))) {
    p         <- to_resolve[i, ]
    query     <- URLencode(p$name_norm, reserved = TRUE)
    results   <- tryCatch(
      md_get(glue("{BASE_URL}/typeahead?search={query}")),
      error = function(e) NULL
    )

    slug <- NA_character_
    verified <- FALSE

    if (!is.null(results) && length(results) > 0) {
      # If multiple results, find the one matching draft year
      if (length(results) == 1) {
        slug <- results[[1]]
        verified <- FALSE  # single match — assume correct, verify below
      } else {
        # Multiple matches — fetch each and check draft year
        for (candidate in results) {
          Sys.sleep(0.3)
          pdata <- tryCatch(
            md_get(glue("{BASE_URL}/player?id={candidate}")),
            error = function(e) NULL
          )
          if (!is.null(pdata) && !is.null(pdata$draft) && pdata$draft == p$season) {
            slug <- candidate
            verified <- TRUE
            break
          }
        }
        # Fall back to first result if none matched by year
        if (is.na(slug)) slug <- results[[1]]
      }
    }

    slug_map <- bind_rows(
      slug_map,
      tibble(
        pfr_player_id = p$pfr_player_id,
        name_norm     = p$name_norm,
        season        = p$season,
        pos           = p$pos,
        slug          = slug,
        slug_verified = verified
      )
    )

    # Save cache every 100 players
    if (i %% 100 == 0) {
      write_rds(slug_map, SLUG_CACHE)
      cli::cli_alert_info("Progress: {i}/{nrow(to_resolve)} resolved, cache saved")
    }

    Sys.sleep(0.3)  # courteous delay
  }

  write_rds(slug_map, SLUG_CACHE)
  cli::cli_alert_success("Slug resolution complete — saved {SLUG_CACHE}")
}

# Summary
n_resolved <- sum(!is.na(slug_map$slug))
n_missing  <- sum(is.na(slug_map$slug))
cli::cli_alert_info("Resolved: {n_resolved} | Not found: {n_missing}")

# ============================================================================
# D) PHASE 2 — BATCH FETCH PLAYER MEASUREMENTS
# ============================================================================
cli::cli_h1("Phase 2: Fetching measurements (batched)")

player_cache <- if (file.exists(PLAYER_CACHE)) {
  read_rds(PLAYER_CACHE)
} else {
  list()
}

slugs_needed <- slug_map |>
  filter(!is.na(slug)) |>
  pull(slug) |>
  unique() |>
  setdiff(names(player_cache))

cli::cli_alert_info("{length(slugs_needed)} slugs to fetch ({length(player_cache)} already cached)")

if (length(slugs_needed) > 0) {
  batches <- split(slugs_needed, ceiling(seq_along(slugs_needed) / BATCH_SIZE))

  for (b in seq_along(batches)) {
    batch   <- batches[[b]]
    ids_json <- toJSON(batch, auto_unbox = FALSE)
    url      <- glue("{BASE_URL}/multiple-players?ids={URLencode(ids_json, reserved = TRUE)}")

    results <- tryCatch({
      resp <- GET(
        url,
        add_headers(
          `Accept`     = "application/json",
          `User-Agent` = "Merrittocracy draft research (themerrittocracy.substack.com)"
        )
      )
      if (http_error(resp)) stop(glue("HTTP {status_code(resp)}"))
      content(resp, as = "text", encoding = "UTF-8") |>
        fromJSON(simplifyVector = FALSE)   # keep each player as a list, not a df row
    }, error = function(e) {
      cli::cli_alert_warning("Batch {b} failed: {conditionMessage(e)}")
      NULL
    })

    if (!is.null(results)) {
      for (pdata in results) {
        if (!is.null(pdata$id)) player_cache[[pdata$id]] <- pdata
      }
      cli::cli_alert_info("Batch {b}/{length(batches)}: {length(batch)} players fetched")
    }

    Sys.sleep(0.5)
  }

  write_rds(player_cache, PLAYER_CACHE)
  cli::cli_alert_success("Player data cached — {length(player_cache)} total")
}

# ============================================================================
# E) PARSE MEASUREMENTS → WIDE FORMAT
# ============================================================================
cli::cli_h1("Parsing measurements")

parse_player <- function(pdata) {
  if (is.null(pdata$measurements) || length(pdata$measurements) == 0) return(NULL)

  # measurements is a list-of-lists when fromJSON(simplifyVector=FALSE) is used
  meas <- map(pdata$measurements, as_tibble) |>
    list_rbind() |>
    filter(as.character(measurableKey) %in% names(MEASURABLE_MAP)) |>
    mutate(col = MEASURABLE_MAP[as.character(measurableKey)])

  if (nrow(meas) == 0) return(NULL)

  values  <- meas |> mutate(measurement = as.numeric(measurement)) |> select(col, measurement) |> deframe()
  sources <- meas |>
    mutate(
      src_col = paste0("src_", col),
      src_val = if_else(source == 2L, "pro_day", "combine")
    ) |>
    select(src_col, src_val) |>
    deframe()

  as_tibble(as.list(c(values, sources))) |>
    mutate(
      slug        = pdata$id,
      md_name     = pdata$name,
      md_draft    = as.integer(pdata$draft),
      md_position = pdata$positions$primary
    )
}

player_rows <- map(player_cache, parse_player) |>
  list_rbind()

cli::cli_alert_success("{nrow(player_rows)} player rows parsed")

# Join back to our player IDs
pro_day <- slug_map |>
  filter(!is.na(slug)) |>
  inner_join(player_rows, by = "slug") |>
  select(
    pfr_player_id, name_norm, season, slug,
    md_name, md_draft, md_position,
    # Measurements (combine or pro day)
    any_of(c("ht_md", "wt_md", "forty", "bench", "vertical", "broad_jump", "cone", "shuttle")),
    # Source indicators
    any_of(paste0("src_", c("ht_md", "wt_md", "forty", "bench", "vertical", "broad_jump", "cone", "shuttle")))
  )

# ============================================================================
# F) SANITY CHECKS
# ============================================================================
cli::cli_h1("Sanity checks")

cli::cli_alert_info("Source breakdown — forty:")
pro_day |>
  count(src_forty = coalesce(src_forty, "missing")) |>
  mutate(pct = round(n / sum(n) * 100, 1)) |>
  print()

cli::cli_alert_info("Pro day players sample (combine non-participants):")
pro_day |>
  filter(src_forty == "pro_day") |>
  select(md_name, md_draft, md_position, forty, src_forty) |>
  head(10) |>
  print()

cli::cli_alert_info("Coverage by draft year (% with any measurement):")
pro_day |>
  group_by(season) |>
  summarise(
    n          = n(),
    pct_forty  = round(mean(!is.na(forty)) * 100, 1),
    pct_proday = round(mean(coalesce(src_forty, "missing") == "pro_day") * 100, 1)
  ) |>
  print(n = 25)

# ============================================================================
# G) SAVE
# ============================================================================
write_rds(pro_day, OUTPUT_RDS)
write_csv(pro_day, OUTPUT_CSV)

cli::cli_alert_success("Saved {OUTPUT_RDS}  ({nrow(pro_day)} rows)")
cli::cli_alert_success("Saved {OUTPUT_CSV}")
cli::cli_alert_info("Next: update 01_load_data.R to apply hybrid combine/pro-day logic")

# ============================================================================
# H) MISSINGNESS COMPARISON — before vs. after pro day integration
# ============================================================================
cli::cli_h1("Missingness comparison: combine-only vs. combine + pro day")

# combine columns in draft_combined (nflreadr uses short names)
measurables <- c("forty", "bench", "vertical", "broad_jump", "cone", "shuttle")

n_players <- draft_combined |>
  filter(season %in% c(DRAFT_YEARS_TRAIN, DRAFT_YEARS_SCORE)) |>
  distinct(pfr_player_id) |>
  nrow()

# One row per player — draft_combined may have multi-year rows
base_combine <- draft_combined |>
  filter(season %in% c(DRAFT_YEARS_TRAIN, DRAFT_YEARS_SCORE)) |>
  select(pfr_player_id, all_of(measurables)) |>
  distinct(pfr_player_id, .keep_all = TRUE)

# Rename pro_day measurables to avoid .x/.y collision
pro_day_slim <- pro_day |>
  select(pfr_player_id,
    pd_forty = forty, pd_bench = bench, pd_vertical = vertical,
    pd_broad_jump = broad_jump, pd_cone = cone, pd_shuttle = shuttle
  )

after_tbl <- base_combine |>
  left_join(pro_day_slim, by = "pfr_player_id") |>
  mutate(
    forty_hybrid      = coalesce(forty,      pd_forty),
    bench_hybrid      = coalesce(bench,      pd_bench),
    vertical_hybrid   = coalesce(vertical,   pd_vertical),
    broad_jump_hybrid = coalesce(broad_jump, pd_broad_jump),
    cone_hybrid       = coalesce(cone,       pd_cone),
    shuttle_hybrid    = coalesce(shuttle,    pd_shuttle)
  )

comparison <- tibble(
  measurable      = measurables,
  n_missing_before = map_int(measurables, ~ sum(is.na(after_tbl[[.x]]))),
  n_missing_after  = map_int(
    paste0(measurables, "_hybrid"),
    ~ sum(is.na(after_tbl[[.x]]))
  )
) |>
  mutate(
    n_filled   = n_missing_before - n_missing_after,
    pct_before = round(n_missing_before / n_players * 100, 1),
    pct_after  = round(n_missing_after  / n_players * 100, 1),
    pct_filled = round(n_filled         / n_players * 100, 1)
  )

cli::cli_alert_info("Total training+scoring players: {n_players}")
print(comparison |> select(measurable, n_missing_before, pct_before, n_missing_after, pct_after, n_filled, pct_filled))
