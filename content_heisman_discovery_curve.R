# ============================================================================
# Heisman "Discovery Curve"
#
#   Question: do Heisman winners win by being GOOD, or by MOVING?
#   Method:   for each winner, find their prior season and their Heisman season
#             and measure the change in national percentile rank of a
#             position-normalized production index.
#   Data:     data/01c_college_stats_raw.rds (cfbfastR player-season)
#
#   Outputs: output/heisman_*.csv plus a self-describing handoff bundle in
#   output/heisman_handoff/ (BRIEFING.md there is hand-written, never regenerated).
#
#   FIVE DATA TRAPS this script exists to avoid. Every one of them was found by
#   producing a confidently wrong number first. Each is repeated inline at the
#   line of code that defuses it.
#
#   1. STATS ARE SPLIT ACROSS CATEGORY TABLES. Mark Ingram's 2009 lives on three
#      separate rows (a 1-attempt passing row, his real rushing row, a receiving
#      row). distinct(athlete_id, season) keeps whichever lands first and
#      silently discards the rest -- it turned a 1,542-yard Heisman season into
#      1 pass attempt. Aggregate with max(), never dedupe.
#      -> defused in section B
#
#   2. THE POOL CHANGES SIZE UNDER THE PERCENTILE. CFBD carries ~120 qualifying
#      QBs/season through 2021 (one per FBS team), then ~250 from 2022 on
#      because FCS *and Division II* teams were added. A percentile computed
#      across that boundary is not comparable to itself. Filter to FBS, and for
#      Heisman purposes all the way down to P4 (trap 4).
#      -> defused at FBS_CONFS / P4_CONFS
#
#   3. COVERAGE COLLAPSES BEFORE 2009. 2008 carries 77 qualifying QBs for 122
#      teams; 2005 carries one. Percentiles there are computed against a pool
#      missing 45 starting quarterbacks. The window starts at winner-year 2011
#      so that every winner's PRIOR season (2010+) also has full coverage.
#      -> defused at FIRST_WINNER_YEAR
#
#   4. THE PRODUCTION INDEX IS VOLUME-BIASED TOWARD THE GROUP OF 5. The 2025
#      national top eight are South Florida, North Texas, UNLV, Texas State,
#      Old Dominion, Delaware, FAU and UConn -- G5 teams throw more, against
#      worse defenses. All 15 winners in this window were P4. Ranking a Heisman
#      candidate against that field measures pace, not candidacy.
#      -> defused at P4_CONFS / P4_INDEP
#
#   5. DO NOT ANCHOR THE TARGET ON THE *MEDIAN* WINNER. Winners are a
#      distribution, not a point. A bar set at the median winner's percentile
#      (99.2) excluded 5 of 15 actual winners -- including Mendoza, who won it
#      from 9th nationally. It measured how often players clear a bar the
#      reigning Heisman winner did not clear. Anchor on RANK instead,
#      calibrated so the zone contains ~90% of real winners (rank <= 3, which
#      in practice captures 15 of 15).
#      -> defused at ZONE_RANK
# ============================================================================

suppressMessages({
  library(tidyverse)
  library(cli)
  library(cfbfastR)
})

RAW_CACHE  <- "data/01c_college_stats_raw.rds"
REC_CACHE  <- "data/heisman_team_records.rds"
OUT_CURVE  <- "output/heisman_discovery_curve.csv"
OUT_TARGET <- "output/heisman_2026_targets.csv"
OUT_BASE   <- "output/heisman_2026_base_rates.csv"

# Handoff bundle -- self-describing copies for downstream drafting. BRIEFING.md
# lives here too but is hand-written and is never overwritten by this script.
HANDOFF    <- "output/heisman_handoff"

# TRAP 2: FBS only -- percentile rank is meaningless if the denominator
# silently absorbs FCS and DII rosters partway through the panel.
FBS_CONFS <- c(
  "ACC", "American Athletic", "Big 12", "Big East", "Big Ten",
  "Conference USA", "FBS Independents", "Mid-American", "Mountain West",
  "Pac-10", "Pac-12", "SEC", "Sun Belt", "WAC"
)

# TRAP 4: P4 only -- an all-FBS ranking measures pace, not candidacy.
P4_CONFS <- c("ACC", "Big Ten", "Big 12", "SEC", "Pac-10", "Pac-12", "Big East")
P4_INDEP <- c("Notre Dame")   # the only independent that is a real P4 program

FIRST_WINNER_YEAR <- 2011   # TRAP 3: earliest year with usable prior-season coverage

# ---------------------------------------------------------------------------
# A) Heisman winners
# ---------------------------------------------------------------------------
winners_all <- tribble(
  ~season, ~player,             ~team,           ~pos_grp,
  2005,    "Reggie Bush",       "USC",             "RB",
  2006,    "Troy Smith",        "Ohio State",      "QB",
  2007,    "Tim Tebow",         "Florida",         "QB",
  2008,    "Sam Bradford",      "Oklahoma",        "QB",
  2009,    "Mark Ingram",       "Alabama",         "RB",
  2010,    "Cam Newton",        "Auburn",          "QB",
  2011,    "Robert Griffin III","Baylor",          "QB",
  2012,    "Johnny Manziel",    "Texas A&M",       "QB",
  2013,    "Jameis Winston",    "Florida State",   "QB",
  2014,    "Marcus Mariota",    "Oregon",          "QB",
  2015,    "Derrick Henry",     "Alabama",         "RB",
  2016,    "Lamar Jackson",     "Louisville",      "QB",
  2017,    "Baker Mayfield",    "Oklahoma",        "QB",
  2018,    "Kyler Murray",      "Oklahoma",        "QB",
  2019,    "Joe Burrow",        "LSU",             "QB",
  2020,    "DeVonta Smith",     "Alabama",         "WR",
  2021,    "Bryce Young",       "Alabama",         "QB",
  2022,    "Caleb Williams",    "USC",             "QB",
  2023,    "Jayden Daniels",    "LSU",             "QB",
  2024,    "Travis Hunter",     "Colorado",        "WR",
  2025,    "Fernando Mendoza",  "Indiana",         "QB"
)

winners <- winners_all |> filter(season >= FIRST_WINNER_YEAR)

# ---------------------------------------------------------------------------
# B) One clean row per athlete-season
#     TRAP 1: max() across category tables, NOT distinct(). Each stat appears on
#     exactly one category row and is NA on the others, so max-with-NA-as-0
#     reassembles the full line. Deduping would silently keep one row and throw
#     the other two away.
# ---------------------------------------------------------------------------
cli_h1("Building player-season table")

raw <- read_rds(RAW_CACHE)

STAT_COLS <- c("passing_att","passing_yds","passing_td","passing_int",
               "rushing_car","rushing_yds","rushing_td",
               "receiving_rec","receiving_yds","receiving_td")

first_non_na <- function(x) {
  x <- x[!is.na(x) & x != ""]
  if (length(x) == 0) NA_character_ else x[1]
}

player_seasons <- bind_rows(raw) |>
  mutate(across(all_of(STAT_COLS), ~ coalesce(as.numeric(.x), 0))) |>
  group_by(athlete_id, season) |>
  summarise(
    player     = first_non_na(player),
    team       = first_non_na(team),
    conference = first_non_na(conference),
    position   = first_non_na(position),
    across(all_of(STAT_COLS), max),
    .groups    = "drop"
  ) |>
  mutate(
    pos_grp = case_when(
      position == "QB"           ~ "QB",
      position %in% c("RB","FB") ~ "RB",
      position %in% c("WR","TE") ~ "WR",
      TRUE                       ~ NA_character_
    ),
    tot_yds = passing_yds + rushing_yds + receiving_yds,
    tot_td  = passing_td  + rushing_td  + receiving_td,
    # Scoreboard-shaped on purpose: a proxy for the stat line a voter sees,
    # not an efficiency metric.
    hpi     = tot_yds / 10 + 6 * tot_td,
    is_fbs  = conference %in% FBS_CONFS,
    is_p4   = conference %in% P4_CONFS | team %in% P4_INDEP,
    qualifies = case_when(
      pos_grp == "QB" ~ passing_att  >= 150,
      pos_grp == "RB" ~ rushing_car  >= 100,
      pos_grp == "WR" ~ receiving_rec >= 30,
      TRUE            ~ FALSE
    )
  ) |>
  filter(!is.na(pos_grp))

# National percentile within P4 position-season, qualifiers only.
pctile_tbl <- player_seasons |>
  filter(is_p4, qualifies) |>
  group_by(season, pos_grp) |>
  mutate(
    n_qual   = n(),
    hpi_pct  = percent_rank(hpi) * 100,
    hpi_rank = rank(-hpi, ties.method = "min")
  ) |>
  ungroup()

cli_alert_success("{nrow(pctile_tbl)} qualifying P4 player-seasons")
pctile_tbl |>
  filter(season >= 2010) |>
  count(season, pos_grp) |>
  pivot_wider(names_from = pos_grp, values_from = n) |>
  as.data.frame() |>
  (\(d) { cli_alert_info("P4 qualifier pool by season (stability check):"); print(d, row.names = FALSE) })()

# ---------------------------------------------------------------------------
# C) Winner season + prior season
# ---------------------------------------------------------------------------
cli_h1("Matching winners")

win_season <- winners |>
  left_join(
    pctile_tbl |> select(season, player, team, athlete_id,
                         tot_yds, tot_td, hpi, hpi_pct, hpi_rank, n_qual),
    by = c("season", "player", "team")
  )

miss <- win_season |> filter(is.na(athlete_id))
if (nrow(miss) > 0) {
  cli_alert_danger("UNMATCHED (excluded): {paste0(miss$player, ' ', miss$season, collapse='; ')}")
}
win_season <- win_season |> filter(!is.na(athlete_id))

prior <- player_seasons |>
  select(athlete_id, season,
         prior_team = team, prior_conf = conference, prior_is_p4 = is_p4,
         p_tot_yds = tot_yds, p_tot_td = tot_td, p_hpi = hpi,
         p_qualifies = qualifies)

prior_pct <- pctile_tbl |>
  select(athlete_id, season, p_hpi_pct = hpi_pct, p_hpi_rank = hpi_rank, p_n_qual = n_qual)

curve <- win_season |>
  mutate(prior_season = season - 1) |>
  left_join(prior,     by = c("athlete_id", "prior_season" = "season")) |>
  left_join(prior_pct, by = c("athlete_id", "prior_season" = "season")) |>
  mutate(
    across(c(p_tot_yds, p_tot_td, p_hpi), ~ coalesce(.x, 0)),
    p_qualifies  = coalesce(p_qualifies, FALSE),
    prior_is_p4  = coalesce(prior_is_p4, FALSE),
    on_radar     = p_qualifies & prior_is_p4,
    transferred  = !is.na(prior_team) & prior_team != team,

    pct_climb  = if_else(on_radar, hpi_pct - p_hpi_pct, NA_real_),
    rank_climb = if_else(on_radar, p_hpi_rank - hpi_rank, NA_integer_),
    yds_growth = if_else(p_tot_yds > 0, (tot_yds - p_tot_yds) / p_tot_yds * 100, NA_real_),
    td_growth  = if_else(p_tot_td  > 0, (tot_td  - p_tot_td)  / p_tot_td  * 100, NA_real_),
    hpi_growth = if_else(on_radar,  (hpi - p_hpi) / p_hpi * 100, NA_real_),

    bucket = case_when(
      !on_radar         ~ "A. No P4 book",
      p_hpi_pct >= 95   ~ "C. Already elite",
      TRUE              ~ "B. Climbed the board"
    )
  ) |>
  arrange(season)

# ---------------------------------------------------------------------------
# D) Report
# ---------------------------------------------------------------------------
cli_h1("The Discovery Curve: Heisman winners {FIRST_WINNER_YEAR}-2025")

curve |>
  transmute(
    Yr = season, Player = str_trunc(player, 18), Pos = pos_grp,
    Tx = if_else(transferred, "T", ""),
    PrYd = round(p_tot_yds), PrTD = round(p_tot_td),
    `Pr%` = if_else(on_radar, sprintf("%.1f", p_hpi_pct), "--"),
    HsYd = round(tot_yds), HsTD = round(tot_td),
    `Hs%` = sprintf("%.1f", hpi_pct),
    Climb = if_else(is.na(pct_climb), "--", sprintf("%+.1f", pct_climb)),
    Bucket = bucket
  ) |>
  as.data.frame() |>
  print(row.names = FALSE)

cli_h2("Bucket counts")
curve |> count(bucket) |> mutate(pct = sprintf("%.0f%%", n/sum(n)*100)) |>
  as.data.frame() |> print(row.names = FALSE)

cli_alert_info("Winners already top-5pct nationally the prior year: {sum(curve$bucket == 'C. Already elite')}")
cli_alert_info("Highest prior-year percentile by any winner: {sprintf('%.1f', max(curve$p_hpi_pct[curve$on_radar]))} ({curve$player[curve$on_radar][which.max(curve$p_hpi_pct[curve$on_radar])]})")

on_radar <- curve |> filter(on_radar)
cli_h2("Winners who WERE on the P4 radar (n = {nrow(on_radar)})")
cli_alert_info("median prior percentile:   {sprintf('%.1f', median(on_radar$p_hpi_pct))}")
cli_alert_info("median Heisman percentile: {sprintf('%.1f', median(on_radar$hpi_pct))}")
cli_alert_info("median climb: {sprintf('%+.1f', median(on_radar$pct_climb))} percentile points")
cli_alert_info("median yardage growth: {sprintf('%+.0f%%', median(on_radar$yds_growth, na.rm=TRUE))}")
cli_alert_info("median TD growth:      {sprintf('%+.0f%%', median(on_radar$td_growth,  na.rm=TRUE))}")

cli_h2("Yards vs TDs -- which lever actually moves?")
on_radar |>
  transmute(Yr = season, Player = str_trunc(player, 18),
            YdGrowth = sprintf("%+.0f%%", yds_growth),
            TDGrowth = sprintf("%+.0f%%", td_growth)) |>
  arrange(desc(parse_number(TDGrowth))) |>
  as.data.frame() |> print(row.names = FALSE)
cli_alert_info("TD growth beat yardage growth in {sum(on_radar$td_growth > on_radar$yds_growth, na.rm=TRUE)} of {sum(!is.na(on_radar$td_growth))}")

dir.create("output", showWarnings = FALSE)
write_csv(curve, OUT_CURVE)

# ---------------------------------------------------------------------------
# E) TEAM RECORDS (cached). Voting closes before the postseason, so every record
#    used here is REGULAR SEASON ONLY.
# ---------------------------------------------------------------------------
cli_h1("Team records")

REC_SEASONS <- (FIRST_WINNER_YEAR - 1):2025

if (file.exists(REC_CACHE)) {
  cli_alert_info("Loading cached team records from {REC_CACHE}")
  recs_raw <- read_rds(REC_CACHE)
} else {
  cli_alert_info("Pulling team records from cfbfastR (needs CFBD_API_KEY)")
  recs_raw <- map_dfr(REC_SEASONS, function(y) {
    Sys.sleep(0.3)
    tryCatch(cfbd_game_records(year = y) |> mutate(season = y),
             error = function(e) {
               cli_alert_warning("Records failed for {y}: {conditionMessage(e)}")
               NULL
             })
  })
  if (nrow(recs_raw) == 0) cli_abort("No team records retrieved -- is CFBD_API_KEY set?")
  write_rds(recs_raw, REC_CACHE)
  cli_alert_success("Cached team records to {REC_CACHE}")
}

recs <- recs_raw |>
  transmute(season, team,
            team_w   = regular_season_wins,
            team_l   = regular_season_losses,
            team_rec = sprintf("%d-%d", regular_season_wins, regular_season_losses))

# ---------------------------------------------------------------------------
# F) WINNERS' LEAP TABLE -- the core evidence, with team context.
#     Non-transfers with no qualifying prior season (backups, redshirts) still
#     had a team; fill prior_team with their Heisman team so the record joins.
# ---------------------------------------------------------------------------
cli_h1("The leap: where winners came from")

leap <- curve |>
  mutate(prior_team_fill = coalesce(prior_team, team)) |>
  left_join(recs, by = c("season", "team")) |>
  left_join(recs |> rename(p_team_w = team_w, p_team_l = team_l, p_team_rec = team_rec),
            by = c("prior_season" = "season", "prior_team_fill" = "team")) |>
  transmute(
    heisman_season        = season,
    player, position      = pos_grp,
    prior_season,
    prior_team            = prior_team_fill,
    prior_yards           = round(p_tot_yds),
    prior_td              = round(p_tot_td),
    prior_natl_rank       = p_hpi_rank,
    prior_pool            = p_n_qual,
    prior_team_rec        = p_team_rec,
    heisman_team          = team,
    heisman_yards         = round(tot_yds),
    heisman_td            = round(tot_td),
    heisman_natl_rank     = hpi_rank,
    heisman_pool          = n_qual,
    heisman_team_rec      = team_rec,
    spots_climbed         = rank_climb,
    production_growth_pct = round(hpi_growth, 1),
    team_wins_added       = team_w - p_team_w,
    had_prior_p4_season   = on_radar,
    changed_schools       = transferred
  )

leap |>
  arrange(desc(spots_climbed)) |>
  transmute(Yr = heisman_season, Player = str_trunc(player, 18), P = position,
            From = if_else(had_prior_p4_season,
                           sprintf("%d/%d", prior_natl_rank, prior_pool), "none"),
            To   = sprintf("%d/%d", heisman_natl_rank, heisman_pool),
            Spots = if_else(is.na(spots_climbed), "--", sprintf("%+d", spots_climbed)),
            Growth = if_else(is.na(production_growth_pct), "--",
                             sprintf("%+.0f%%", production_growth_pct))) |>
  as.data.frame() |> print(row.names = FALSE)

cli_h2("Did the team jump too?")
leap |>
  arrange(desc(team_wins_added)) |>
  transmute(Yr = heisman_season, Player = str_trunc(player, 18),
            Prior = sprintf("%-13s %s", str_trunc(prior_team, 12), prior_team_rec),
            Heisman = sprintf("%-13s %s", str_trunc(heisman_team, 12), heisman_team_rec),
            `+W` = sprintf("%+d", team_wins_added),
            Spots = if_else(is.na(spots_climbed), "none", sprintf("%+d", spots_climbed))) |>
  as.data.frame() |> print(row.names = FALSE)

cli_alert_info("Median Heisman-year record: {median(leap$team_w)}-{median(leap$team_l)}")
cli_alert_info("Teams with <=2 regular-season losses: {sum(leap$team_l <= 2)}/{nrow(leap)}; <=1 loss: {sum(leap$team_l <= 1)}")
cli_alert_info("Worst record by any winner: {max(leap$team_l)} losses")
cli_alert_info("Teams that added wins: {sum(leap$team_wins_added > 0)}/{nrow(leap)} (median {median(leap$team_wins_added)})")

# The winner leap distribution -- used below to score how rare each 2026 ask is.
WINNER_GROWTH <- sort(leap$production_growth_pct[!is.na(leap$production_growth_pct)])
cli_alert_info("Winner production growth: {paste0(sprintf('%+.0f%%', WINNER_GROWTH), collapse=' ')}")

# ---------------------------------------------------------------------------
# G) 2026 candidates: how big a leap does each need?
# ---------------------------------------------------------------------------
cli_h1("2026 candidates: the price of admission")

# TRAP 5: anchor on RANK, not on the median winner's percentile. A
# median-anchored bar excludes 5 of 15 actual winners, Mendoza among them.
ZONE_RANK <- ceiling(quantile(curve$hpi_rank, 0.90, names = FALSE))
cli_alert_info("Winner rank: median {median(curve$hpi_rank)}, worst {max(curve$hpi_rank)} ({curve$player[which.max(curve$hpi_rank)]}).")
cli_alert_info("Winner's zone set at national rank <= {ZONE_RANK} (captures {sum(curve$hpi_rank <= ZONE_RANK)}/{nrow(curve)} winners).")

# The production it has actually taken to hold that rank in recent seasons.
bar <- pctile_tbl |>
  filter(season %in% 2021:2025) |>
  group_by(season, pos_grp) |>
  summarise(bar_hpi = sort(hpi, decreasing = TRUE)[min(ZONE_RANK, n())], .groups = "drop") |>
  group_by(pos_grp) |>
  summarise(bar_hpi = median(bar_hpi), .groups = "drop")

cli_alert_info("Production required to hold rank {ZONE_RANK}:")
bar |> mutate(bar_hpi = round(bar_hpi, 1)) |> as.data.frame() |> print(row.names = FALSE)

# Mateer appears twice on purpose: his injured 2025 and his healthy 2024. The
# contrast is the point -- the healthy line already clears the bar.
favorites <- tribble(
  ~player,          ~team,              ~season, ~label,                   ~note,
  "Arch Manning",   "Texas",            2025,    "Arch Manning",           "consensus preseason pick",
  "Julian Sayin",   "Ohio State",       2025,    "Julian Sayin",           "4th in 2025 voting",
  "Dante Moore",    "Oregon",           2025,    "Dante Moore",            "led race in Oct, zero votes",
  "John Mateer",    "Oklahoma",         2025,    "Mateer (2025, hurt)",    "thumb surgery, played hurt",
  "John Mateer",    "Washington State", 2024,    "Mateer (2024, healthy)", "last fully healthy season",
  "C.J. Carr",      "Notre Dame",       2025,    "C.J. Carr",              "preseason list",
  "Jeremiah Smith", "Ohio State",       2025,    "Jeremiah Smith",         "6th in 2025 voting",
  "Cam Coleman",    "Auburn",           2025,    "Cam Coleman",            "transfers to Texas for 2026"
)

# Rank every baseline line against the SAME yardstick (the 2025 P4 field), so a
# 2024 season and a 2025 season are directly comparable.
field_2025 <- pctile_tbl |> filter(season == 2025)
rank_vs_2025 <- function(h, pg) sum(field_2025$hpi[field_2025$pos_grp == pg] > h) + 1
pool_2025    <- function(pg)    sum(field_2025$pos_grp == pg)

targets <- favorites |>
  left_join(player_seasons |> select(player, team, season, pos_grp, tot_yds, tot_td, hpi),
            by = c("player", "team", "season")) |>
  left_join(pctile_tbl |> select(player, team, season, own_season_pct = hpi_pct),
            by = c("player", "team", "season")) |>
  left_join(recs, by = c("team", "season")) |>
  left_join(bar, by = "pos_grp")

if (any(is.na(targets$hpi))) {
  cli_alert_danger("Unmatched candidates: {paste(targets$label[is.na(targets$hpi)], collapse=', ')}")
}

targets <- targets |>
  rowwise() |>
  mutate(rank_vs_2025_field = rank_vs_2025(hpi, pos_grp),
         pool_2025_field    = pool_2025(pos_grp)) |>
  ungroup() |>
  mutate(
    growth_needed_pct        = round((bar_hpi / hpi - 1) * 100, 1),
    target_yards             = round(tot_yds * bar_hpi / hpi, -1),
    target_td                = ceiling(tot_td * bar_hpi / hpi),
    # The Mendoza route: yardage flat, the whole climb in touchdowns.
    target_td_if_yards_flat  = ceiling((bar_hpi - tot_yds / 10) / 6),
    winners_who_leapt_further = map_int(growth_needed_pct, ~ sum(WINNER_GROWTH >= .x)),
    wins_to_reach_12_1       = pmax(0, 12 - team_w)
  )

targets |>
  arrange(growth_needed_pct) |>
  transmute(Candidate = str_trunc(label, 22), P = pos_grp,
            Baseline = sprintf("%d yd/%d TD", round(tot_yds), round(tot_td)),
            Rec = team_rec,
            `vs2025` = sprintf("%d/%d", rank_vs_2025_field, pool_2025_field),
            Need = sprintf("%+.0f%%", growth_needed_pct),
            Target = sprintf("%d yd/%d TD", target_yards, target_td),
            FlatTD = target_td_if_yards_flat,
            `WinnersFurther` = sprintf("%d/%d", winners_who_leapt_further, length(WINNER_GROWTH)),
            `WinsTo12` = wins_to_reach_12_1) |>
  as.data.frame() |> print(row.names = FALSE)

cli_alert_warning("wins_to_reach_12_1 uses the BASELINE season's team. Mateer's 2024 row is Washington State (8-4); his 2026 team is Oklahoma (see his 2025 row).")

# ---------------------------------------------------------------------------
# H) BASE RATE -- the check that keeps this from being anecdote.
#     Winners obviously climbed; that is survivorship. The real question is how
#     often a player standing where each candidate stands TODAY reaches the
#     winner's zone next season. Denominator = every qualifying P4 player.
# ---------------------------------------------------------------------------
cli_h1("Base rate: P(reach winner's zone next season | where you stand now)")

BANDS  <- c(-1, 25, 50, 65, 80, 90, 95, 100.1)
LABELS <- c("0-25","25-50","50-65","65-80","80-90","90-95","95-100")

transitions <- pctile_tbl |>
  select(athlete_id, season, pos_grp, hpi_pct) |>
  mutate(next_season = season + 1) |>
  inner_join(pctile_tbl |> select(athlete_id, season, nxt_rank = hpi_rank),
             by = c("athlete_id", "next_season" = "season")) |>
  filter(season >= FIRST_WINNER_YEAR - 1, season <= 2024) |>
  mutate(start_band = cut(hpi_pct, BANDS, labels = LABELS),
         made_it    = nxt_rank <= ZONE_RANK)

cli_alert_info("n = {nrow(transitions)} consecutive qualifying P4 seasons")
cli_alert_info("Target: finish next season in the national top {ZONE_RANK} at your position.")

band_rates <- transitions |>
  group_by(start_band) |>
  summarise(n = n(), reached = sum(made_it), rate = mean(made_it), .groups = "drop")

band_rates |>
  transmute(start_band, n, reached, rate = sprintf("%.1f%%", rate * 100)) |>
  as.data.frame() |> print(row.names = FALSE)

cli_h2("Same, by position")
transitions |>
  group_by(pos_grp, start_band) |>
  summarise(n = n(), rate = sprintf("%.1f%%", mean(made_it) * 100), .groups = "drop") |>
  pivot_wider(names_from = pos_grp, values_from = c(n, rate)) |>
  as.data.frame() |> print(row.names = FALSE)

cli_h2("Base rate for each candidate's actual starting position")
fav_rates <- targets |>
  filter(!is.na(own_season_pct)) |>
  mutate(start_band = cut(own_season_pct, BANDS, labels = LABELS)) |>
  left_join(transitions |>
              group_by(pos_grp, start_band) |>
              summarise(band_n = n(), band_rate = mean(made_it), .groups = "drop"),
            by = c("pos_grp", "start_band"))

fav_rates |>
  arrange(desc(band_rate)) |>
  transmute(Candidate = str_trunc(label, 22), P = pos_grp,
            `OwnYr%ile` = sprintf("%.1f", own_season_pct),
            Band = as.character(start_band), CompN = band_n,
            `P(top zone)` = sprintf("%.1f%%", band_rate * 100)) |>
  as.data.frame() |> print(row.names = FALSE)

cli_alert_warning("This is P(elite STAT SEASON), not P(win Heisman). Roughly 15-30 players/yr reach the zone; one wins.")

# ---------------------------------------------------------------------------
# I) WRITE EVERYTHING
# ---------------------------------------------------------------------------
cli_h1("Writing outputs")

dir.create("output", showWarnings = FALSE)
dir.create(HANDOFF, showWarnings = FALSE, recursive = TRUE)

write_csv(curve,     OUT_CURVE)
write_csv(targets,   OUT_TARGET)
write_csv(fav_rates, OUT_BASE)

# Handoff bundle: self-describing column names for downstream drafting.
write_csv(leap, file.path(HANDOFF, "winners_leap_table.csv"))

targets |>
  transmute(candidate = label, player, position = pos_grp,
            baseline_season = season, baseline_team = team,
            baseline_team_rec = team_rec,
            baseline_yards = round(tot_yds), baseline_td = round(tot_td),
            rank_vs_2025_field, pool_2025_field,
            bar_production = round(bar_hpi, 1),
            growth_needed_pct, target_yards, target_td,
            target_td_if_yards_flat, winners_who_leapt_further,
            wins_to_reach_12_1, note) |>
  write_csv(file.path(HANDOFF, "candidates_2026_targets.csv"))

band_rates |>
  transmute(starting_percentile_band = start_band,
            n_player_seasons = n,
            n_reached_top_zone = reached,
            probability_pct = round(rate * 100, 1)) |>
  write_csv(file.path(HANDOFF, "base_rates_by_starting_position.csv"))

cli_alert_success("output/: {basename(OUT_CURVE)}, {basename(OUT_TARGET)}, {basename(OUT_BASE)}")
cli_alert_success("{HANDOFF}/: winners_leap_table.csv, candidates_2026_targets.csv, base_rates_by_starting_position.csv")
if (file.exists(file.path(HANDOFF, "BRIEFING.md"))) {
  cli_alert_info("BRIEFING.md present (hand-written -- not regenerated by this script)")
} else {
  cli_alert_warning("BRIEFING.md missing from {HANDOFF} -- the CSVs are hard to read without it")
}
