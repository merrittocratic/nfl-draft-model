# ============================================================================
# 01b_compute_4yr_av.R
# Merrittocracy — NFL Draft Boom/Bust Model
#
# Ingests season-level AV data from Pro Football Reference CSVs, computes
# 4-year career AV windows per player, and classifies boom/bust/expected
# relative to draft position.
#
# This script serves two purposes:
#   1. Pipeline step 01b for the model (replaces the stub)
#   2. Produces the positional value table for the Downs article
#
# Input:  data/pfr_av_raw/pfr_av_d{draft_year}_s{season_year}.csv
# Output: data/player_4yr_av.rds (full player-level data)
#         content/graphics/downs_positional_value_table.png (article table)
#
# Source: Pro Football Reference / Stathead (paid subscription)
# ============================================================================

library(tidyverse)
library(gt)
library(cli)

# --- Config -----------------------------------------------------------------

# Draft classes to include in analysis
# Model training window is 2006-2020; extend if you have the data
DRAFT_YEARS <- 2006:2020

# 4-year AV window
AV_WINDOW <- 4

# Boom/bust thresholds (standardized residual)
BOOM_THRESHOLD <- 1
BUST_THRESHOLD <- -1

# Path to raw PFR CSVs
RAW_DATA_DIR <- "data/pfr_av_raw"

# --- Position mapping -------------------------------------------------------
# Maps PFR's granular position codes to the 7 sub-model groups from CLAUDE.md
# NOTE: OLB mapped to DL (edge) — most first-round OLBs are pass rushers.
# If this assumption bothers you, flag it and we'll discuss.

pos_group_map <- tribble(
  ~pfr_pos,   ~pos_group,
  # QB
  "QB",       "QB",
  # WR/TE
  "WR",       "WR/TE",
  "TE",       "WR/TE",
  # DL (EDGE + IDL)
  "DE",       "DL",
  "LDE",      "DL",
  "RDE",      "DL",
  "DT",       "DL",
  "LDT",      "DL",
  "RDT",      "DL",
  "NT",       "DL",
  "DL",       "DL",
  "OLB",      "DL",
  "LOLB",     "DL",
  "ROLB",     "DL",
  # OL
  "OT",       "OL",
  "T",        "OL",
  "LT",       "OL",
  "RT",       "OL",
  "G",        "OL",
  "LG",       "OL",
  "RG",       "OL",
  "C",        "OL",
  "OL",       "OL",
  # DB (CB + S)
  "CB",       "DB",
  "LCB",      "DB",
  "RCB",      "DB",
  "S",        "DB",
  "SS",       "DB",
  "FS",       "DB",
  "DB",       "DB",
  # LB (off-ball)
  "LB",       "LB",
  "LLB",      "LB",
  "RLB",      "LB",
  "MLB",      "LB",
  "ILB",      "LB",
  "LILB",     "LB",
  "RILB",     "LB",
  # RB
  "RB",       "RB",
  "FB",       "RB"
)

# --- Ingest all CSVs --------------------------------------------------------

cli_h1("Ingesting PFR AV data")

# Find all matching files
csv_files <- list.files(
  RAW_DATA_DIR,
  pattern = "^pfr_av_d\\d{4}_s\\d{4}\\.csv$",
  full.names = TRUE
)

cli_alert_info("Found {length(csv_files)} CSV files in {RAW_DATA_DIR}")

# Column names for the headerless CSVs
col_names <- c(
  "rank", "player_name", "season_av", "draft_team", "draft_round",
  "draft_pick", "draft_year", "college", "season_year", "age",
  "current_team", "games_played", "games_started", "season_av_dup",
  "position", "pfr_player_id"
)

# Read and bind all files
raw_data <- csv_files |>
  map(\(f) {
    read_csv(
      f,
      col_names = col_names,
      col_types = cols(
        rank = col_integer(),
        player_name = col_character(),
        season_av = col_integer(),
        draft_team = col_character(),
        draft_round = col_integer(),
        draft_pick = col_integer(),
        draft_year = col_integer(),
        college = col_character(),
        season_year = col_integer(),
        age = col_integer(),
        current_team = col_character(),
        games_played = col_integer(),
        games_started = col_integer(),
        season_av_dup = col_integer(),
        position = col_character(),
        pfr_player_id = col_character()
      ),
      show_col_types = FALSE
    )
  }) |>
  bind_rows()

cli_alert_success("Loaded {nrow(raw_data)} player-season rows")

# --- Compute career year offset ---------------------------------------------
# IMPORTANT: Use season - draft_year + 1 to avoid survivorship bias
# (per project learnings — do NOT filter by "years played")

raw_data <- raw_data |>
  mutate(career_year = season_year - draft_year + 1) |>
  # Drop the duplicate AV column

  select(-season_av_dup)

# --- Filter to 4-year window and target draft classes -----------------------

av_window <- raw_data |>
  filter(
    draft_year %in% DRAFT_YEARS,
    career_year >= 1,
    career_year <= AV_WINDOW
  )

cli_alert_info(
  "Filtered to {n_distinct(av_window$pfr_player_id)} players, ",
  "draft classes {min(DRAFT_YEARS)}-{max(DRAFT_YEARS)}, ",
  "{AV_WINDOW}-year window"
)

# --- Sum 4-year AV per player -----------------------------------------------
# Players missing from a season's CSV get 0 AV for that year (they weren't
# on a roster or didn't play). We handle this by summing whatever seasons
# exist — a player with only 2 seasons of data gets the sum of those 2.

player_av <- av_window |>
  group_by(pfr_player_id, player_name, draft_team, draft_round,
           draft_pick, draft_year, college) |>
  summarise(
    total_4yr_av = sum(season_av, na.rm = TRUE),
    seasons_played = n_distinct(season_year),
    # Use the most common position across their seasons
    position = names(sort(table(position), decreasing = TRUE))[1],
    .groups = "drop"
  )

cli_alert_success("Computed 4-year AV for {nrow(player_av)} players")

# --- Map to position groups -------------------------------------------------

player_av <- player_av |>
  left_join(pos_group_map, by = c("position" = "pfr_pos"))

# Check for unmapped positions
unmapped <- player_av |> filter(is.na(pos_group))
if (nrow(unmapped) > 0) {
  cli_alert_warning(
    "{nrow(unmapped)} players with unmapped positions: ",
    "{paste(unique(unmapped$position), collapse = ', ')}"
  )
  cli_alert_info("These will be excluded from position group analysis")
}

player_av <- player_av |> filter(!is.na(pos_group))

# --- Compute expected AV by draft pick bin ----------------------------------
# Using pick bins to smooth out noise from individual picks
# Bins: 1-5, 6-10, 11-16, 17-22, 23-32 for round 1
# Then broader bins for later rounds

player_av <- player_av |>
  mutate(
    pick_bin = case_when(
      draft_pick <= 5   ~ "1-5",
      draft_pick <= 10  ~ "6-10",
      draft_pick <= 16  ~ "11-16",
      draft_pick <= 22  ~ "17-22",
      draft_pick <= 32  ~ "23-32",
      draft_pick <= 64  ~ "33-64",
      draft_pick <= 100 ~ "65-100",
      draft_pick <= 150 ~ "101-150",
      draft_pick <= 200 ~ "151-200",
      TRUE              ~ "201+"
    )
  )

# Compute expected AV per pick bin (historical average)
expected_av <- player_av |>
  group_by(pick_bin) |>
  summarise(
    expected_av = mean(total_4yr_av, na.rm = TRUE),
    n_players = n(),
    .groups = "drop"
  )

cli_h2("Expected AV by pick bin")
print(expected_av)

player_av <- player_av |>
  left_join(expected_av |> select(pick_bin, expected_av), by = "pick_bin")

# --- Compute residuals and classify boom/bust -------------------------------

player_av <- player_av |>
  mutate(
    av_residual = total_4yr_av - expected_av
  )

# Standardize residuals (within each pick bin for fairness)
player_av <- player_av |>
  group_by(pick_bin) |>
  mutate(
    residual_sd = sd(av_residual, na.rm = TRUE),
    std_residual = if_else(
      residual_sd > 0,
      av_residual / residual_sd,
      0
    )
  ) |>
  ungroup() |>
  select(-residual_sd)

# Classify
player_av <- player_av |>
  mutate(
    label = case_when(
      std_residual > BOOM_THRESHOLD  ~ "Boom",
      std_residual < BUST_THRESHOLD  ~ "Bust",
      TRUE                           ~ "Expected"
    )
  )

# --- Summary stats ----------------------------------------------------------

cli_h2("Overall classification (all rounds)")
player_av |>
  count(label) |>
  mutate(pct = scales::percent(n / sum(n))) |>
  print()

# --- Save full player-level data --------------------------------------------

saveRDS(player_av, "data/player_4yr_av.rds")
cli_alert_success("Saved player-level data to data/player_4yr_av.rds")

# ============================================================================
# ARTICLE TABLE: Positional value for first-round picks
# ============================================================================

cli_h1("Building positional value table for Downs article")

# Filter to first-round picks only
rd1 <- player_av |> filter(draft_round == 1)

cli_alert_info("First-round picks in dataset: {nrow(rd1)}")

# Compute rates by position group
pos_table <- rd1 |>
  group_by(pos_group) |>
  summarise(
    n_drafted = n(),
    boom_n = sum(label == "Boom"),
    bust_n = sum(label == "Bust"),
    expected_n = sum(label == "Expected"),
    boom_rate = boom_n / n_drafted,
    bust_rate = bust_n / n_drafted,
    expected_rate = expected_n / n_drafted,
    boom_bust_diff = boom_rate - bust_rate,
    avg_4yr_av = mean(total_4yr_av, na.rm = TRUE),
    .groups = "drop"
  ) |>
  arrange(desc(boom_bust_diff))

cli_h2("Position group results (Round 1)")
print(pos_table |> select(pos_group, n_drafted, boom_rate, bust_rate, boom_bust_diff))

# --- Build gt table ---------------------------------------------------------

article_table <- pos_table |>
  select(pos_group, n_drafted, boom_rate, bust_rate, boom_bust_diff, avg_4yr_av) |>
  gt() |>
  tab_header(
    title = md("**First-Round Boom & Bust Rates by Position Group**"),
    subtitle = md("*Draft classes 2006–2020 | 4-year Career Approximate Value*")
  ) |>
  cols_label(
    pos_group      = "Position",
    n_drafted      = "Drafted",
    boom_rate      = "Boom %",
    bust_rate      = "Bust %",
    boom_bust_diff = "Boom – Bust",
    avg_4yr_av     = "Avg 4-Yr AV"
  ) |>
  fmt_percent(
    columns = c(boom_rate, bust_rate, boom_bust_diff),
    decimals = 1
  ) |>
  fmt_number(
    columns = avg_4yr_av,
    decimals = 1
  ) |>
  # Color the boom-bust differential
  data_color(
    columns = boom_bust_diff,
    palette = c("#d73027", "#fee08b", "#1a9850"),
    domain = c(-0.3, 0.3)
  ) |>
  # Color bust rate (reversed: low = green)
  data_color(
    columns = bust_rate,
    palette = c("#1a9850", "#fee08b", "#d73027"),
    domain = c(0, 0.5)
  ) |>
  # Bold the DB row (Downs' position group)
  tab_style(
    style = cell_text(weight = "bold"),
    locations = cells_body(rows = pos_group == "DB")
  ) |>
  # Light red background on RB row for contrast
  tab_style(
    style = cell_fill(color = "#fff3f3"),
    locations = cells_body(rows = pos_group == "RB")
  ) |>
  tab_source_note(
    source_note = md(
      "Source: Pro Football Reference. Boom = std. residual > 1. ",
      "Bust = std. residual < –1. AV adjusted for draft position.<br>",
      "DB combines safeties and cornerbacks. DL combines EDGE and IDL."
    )
  ) |>
  tab_footnote(
    footnote = "Boom rate minus bust rate. Higher = safer investment.",
    locations = cells_column_labels(columns = boom_bust_diff)
  ) |>
  tab_options(
    heading.title.font.size = px(18),
    heading.subtitle.font.size = px(13),
    table.font.size = px(13),
    column_labels.font.weight = "bold",
    source_notes.font.size = px(10),
    table.width = pct(100)
  ) |>
  cols_align(align = "center", columns = -pos_group) |>
  cols_align(align = "left", columns = pos_group)

# --- Export table -----------------------------------------------------------

gtsave(article_table, "content/graphics/downs_positional_value_table.png", vwidth = 700)
cli_alert_success("Article table saved to content/graphics/downs_positional_value_table.png")

# --- Diagnostic: list the DB first-rounders for spot-checking ---------------

cli_h2("First-round DB picks (spot check)")
rd1 |>
  filter(pos_group == "DB") |>
  arrange(draft_year, draft_pick) |>
  select(player_name, draft_year, draft_pick, position, total_4yr_av,
         expected_av, std_residual, label) |>
  print(n = 50)

cli_alert_success("Done! Review the DB list above to sanity-check classifications.")
