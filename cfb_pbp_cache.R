# ============================================================================
# cfb_pbp_cache.R
# Cached cfbfastR play-by-play + the house EPA definitions used by the
# storyline-data-packet skill. Source this, then:
#   pbp <- load_cfb_pbp(2026)            # all completed weeks, cached
#   cfb_team_epa(pbp)                    # season off/def EPA + FBS ranks
#   cfb_team_epa(pbp, by = "game")       # per-game log
#
# EPA here is ALWAYS cfbfastR's play-by-play EPA, never CFBD's PPA --
# they come from different expected-points models and disagree by a lot
# (W5 2026 Missouri vs Florida: 0.251 EPA/play vs 0.415 PPA/play).
# ============================================================================

suppressMessages({
  library(cfbfastR)
  library(dplyr)
})

CFB_PBP_DIR <- "data/cfb_pbp"

# Special teams, penalty, timeout and admin rows dilute or invert per-play
# EPA (2026-09-20 Ole Miss-LSU pull gave the wrong team the edge unfiltered).
SCRIMMAGE_PLAY_TYPES <- c(
  "Rush", "Rushing Touchdown",
  "Pass", "Pass Reception", "Pass Incompletion", "Passing Touchdown",
  "Pass Interception", "Pass Interception Return", "Interception Return",
  "Interception Return Touchdown",
  "Sack", "Safety",
  "Fumble", "Fumble Recovery (Own)", "Fumble Recovery (Opponent)",
  "Fumble Return Touchdown", "Fumble Recovery (Opponent) Touchdown",
  "Pass Completion"
)

# A week is only cached once every game in it is final -- caching a
# partial Saturday would silently freeze missing games into the packet.
# Only FBS-involved games count: CFBD lists D-II/D-III games that never
# get marked completed and would otherwise block every week from caching.
completed_weeks <- function(season) {
  games <- cfbd_game_info(season, season_type = "regular")
  games |>
    filter(home_division %in% "fbs" | away_division %in% "fbs") |>
    group_by(week) |>
    summarise(all_final = all(completed), any_final = any(completed), .groups = "drop") |>
    filter(any_final)
}

load_cfb_pbp <- function(season, weeks = NULL, refresh = FALSE) {
  dir.create(CFB_PBP_DIR, showWarnings = FALSE, recursive = TRUE)
  wk_status <- completed_weeks(season)
  if (is.null(weeks)) weeks <- wk_status$week

  pulls <- lapply(weeks, function(wk) {
    path <- file.path(CFB_PBP_DIR, glue::glue("pbp_{season}_w{sprintf('%02d', wk)}.rds"))
    week_final <- isTRUE(wk_status$all_final[wk_status$week == wk])

    if (file.exists(path) && !refresh) {
      return(readRDS(path) |> mutate(week = wk))
    }

    cli::cli_alert_info("Pulling {season} week {wk} play-by-play (~80s per week)")
    Sys.sleep(0.3)
    pbp <- tryCatch(
      cfbd_pbp_data(season, week = wk, epa_wpa = TRUE),
      error = function(e) {
        cli::cli_alert_warning("Week {wk} pull failed: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(pbp) || nrow(pbp) == 0) return(NULL)
    # cfbd_pbp_data() has no week column; per-game logs need one
    pbp <- pbp |> mutate(week = wk)

    if (week_final) {
      saveRDS(pbp, path)
    } else {
      cli::cli_alert_warning("Week {wk} has unfinished games -- returned but NOT cached")
    }
    pbp
  })

  out <- bind_rows(pulls)
  cli::cli_alert_success("{season}: {n_distinct(out$game_id)} games, weeks {paste(range(weeks), collapse = '-')}")
  out
}

cfb_scrimmage <- function(pbp, exclude_garbage = TRUE) {
  unknown <- setdiff(unique(pbp$play_type), c(SCRIMMAGE_PLAY_TYPES, NON_SCRIMMAGE_PLAY_TYPES))
  if (length(unknown) > 0) {
    cli::cli_alert_warning("Unclassified play types (excluded): {paste(unknown, collapse = ', ')}")
  }
  out <- pbp |> filter(play_type %in% SCRIMMAGE_PLAY_TYPES)
  if (exclude_garbage) out <- out |> filter(!is_garbage_time(period, pos_score_diff_start))
  out
}

# cfbfastR's EP model includes score margin, so it extrapolates badly in
# blowouts (W2 2026 Miami 77, FAMU 7: 1st-and-10 at own 25 had EP 3.87,
# an 8-yd avg rush game scored -0.41 EPA/rush). Connelly's SP+ garbage-time
# margins: >43 Q1, >37 Q2, >27 Q3, >22 Q4. Overtime is never garbage.
is_garbage_time <- function(period, score_diff) {
  limit <- c(43, 37, 27, 22)[pmin(period, 4)]
  period <= 4 & abs(score_diff) > limit
}

# Known non-scrimmage types, listed so new CFBD play types surface as a
# warning instead of silently dropping out of the EPA average.
NON_SCRIMMAGE_PLAY_TYPES <- c(
  "Kickoff", "Kickoff Return (Offense)", "Kickoff Return Touchdown",
  "Punt", "Punt Return", "Punt Return Touchdown", "Blocked Punt",
  "Blocked Punt Touchdown", "Field Goal Good", "Field Goal Missed",
  "Blocked Field Goal", "Blocked Field Goal Touchdown",
  "Missed Field Goal Return", "Missed Field Goal Return Touchdown",
  "Extra Point Good", "Extra Point Missed", "Two Point Pass", "Two Point Rush",
  "Defensive 2pt Conversion", "Penalty", "Timeout", "End Period",
  "End of Half", "End of Game", "End of Regulation", "Uncategorized",
  "placeholder", "Offensive 1pt Safety", "Start of Period", "Coin Toss",
  "Kickoff Team Fumble Recovery", "Punt Team Fumble Recovery",
  "Penalty Touchdown"
)

# Season (or per-game) offense/defense EPA for every team in the pull.
# Ranks are among FBS teams only and the pool size is returned with them,
# so packets can always say "Nth of M FBS".
cfb_team_epa <- function(pbp, by = c("season", "game"), exclude_garbage = TRUE) {
  by <- match.arg(by)
  fbs <- cfbd_team_info(only_fbs = TRUE, year = unique(pbp$season)[1])$school
  plays <- cfb_scrimmage(pbp, exclude_garbage = exclude_garbage)

  grp <- if (by == "game") c("game_id", "week", "team") else "team"

  side_stats <- function(df, team_col) {
    df |>
      mutate(team = .data[[team_col]]) |>
      group_by(across(all_of(grp))) |>
      summarise(
        plays     = n(),
        epa       = mean(EPA, na.rm = TRUE),
        sr        = mean(success, na.rm = TRUE),
        pass_epa  = mean(EPA[pass == 1], na.rm = TRUE),
        rush_epa  = mean(EPA[rush == 1], na.rm = TRUE),
        pass_sr   = mean(success[pass == 1], na.rm = TRUE),
        rush_sr   = mean(success[rush == 1], na.rm = TRUE),
        .groups   = "drop"
      )
  }

  off <- side_stats(plays, "pos_team") |> rename_with(~ paste0("off_", .x), -all_of(grp))
  def <- side_stats(plays, "def_pos_team") |> rename_with(~ paste0("def_", .x), -all_of(grp))
  out <- inner_join(off, def, by = grp) |> mutate(fbs = team %in% fbs)

  if (by == "season") {
    pool <- sum(out$fbs)
    out <- out |>
      mutate(
        off_epa_rk = if_else(fbs, rank(-if_else(fbs, off_epa, NA_real_), na.last = "keep"), NA_real_),
        def_epa_rk = if_else(fbs, rank(if_else(fbs, def_epa, NA_real_), na.last = "keep"), NA_real_),
        net_epa    = off_epa - def_epa,
        net_epa_rk = if_else(fbs, rank(-if_else(fbs, net_epa, NA_real_), na.last = "keep"), NA_real_),
        fbs_pool   = pool
      )
  }
  out
}
