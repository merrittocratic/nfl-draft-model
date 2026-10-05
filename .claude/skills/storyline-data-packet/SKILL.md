---
name: storyline-data-packet
description: Given a list of college football storylines -- team/coach narratives ("Lane Kiffin should have stayed at Ole Miss"), game results, program trajectories, or (less often) a specific prospect's draft stock -- pull real cfbfastR game/season data, and this model's own outputs when a scored prospect is actually involved, to build a fact-based data packet for a write-up. Use when Merrittocracy gives a list of storylines for a Substack piece or X thread and wants supporting stats pulled together.
---

# Storyline Data Packet

Turn a short list of narrative claims into a sourced data packet
Merrittocracy can write from. This is research, not drafting -- never
write the actual piece here. Full voice/format/autonomy rules for the
actual draft live in `CONTENT_GUIDE.md`; this skill only feeds it.

This is a port of boxscore-prophet's `/storyline-data-packet` skill.
Same job as that one: check a claim against real data, most of the time
that means real GAMES and TEAMS, not the draft-prospect model. Don't
force every storyline through this project's boom/bust machinery --
most storylines here won't touch it at all.

## Inputs

Merrittocracy gives a list of storylines, usually 3-5, tied to a
season/week. Confirm season/week if not stated. Most storylines are
**team, coach, or program narratives anchored to real games** -- e.g.
"Lane Kiffin should have stayed at Ole Miss, and LSU's loss last night
proves it," "this team's defense collapsed after [coordinator] left,"
"[program] is underperforming its recruiting talent." A smaller share
are **prospect/draft-stock narratives** ("[player] looks like a
first-rounder") where this project's own model actually has something
to say. Identify which shape each storyline is before deciding what to
pull -- they use almost entirely different data.

## Process, per storyline

1. **Identify the specific teams, games, and/or people the storyline
   actually turns on.** "Kiffin should have stayed" needs Ole Miss's
   actual 2026 results under the new coach, LSU's actual result from
   the referenced game, and ideally Kiffin's own team's 2026 results at
   his new job, so the comparison is apples-to-apples -- not just the
   final score everyone already saw on TV.

2. **Pull real game and season data via cfbfastR.** For team/coach/game
   storylines, this is the WHOLE job -- there is no cache for any of
   this in the repo (everything cached here is player-level draft-class
   production, 2002-2025 only), so every pull here is a live API call.

   **DEFAULT lens is per-game, not season-long** -- these storylines are
   almost always about a specific week's result, and season-aggregate
   ratings answer a different question (who's been better all year) than
   the one usually being asked (what actually happened in this game).
   Lead with:
   - `cfbfastR::cfbd_game_info(year, week)` or `cfbd_games()` -- schedule
     and final score for the specific game.
   - `cfbfastR::cfbd_pbp_data(year, week, team, epa_wpa = TRUE)` --
     play-by-play for that specific game. **Filter to scrimmage plays
     only** (`play_type %in% c("Rush","Pass Reception","Pass
     Incompletion","Sack","Rushing Touchdown","Passing Touchdown", ...)`)
     before averaging EPA -- special teams/penalty/timeout rows dilute
     or invert the number (confirmed 2026-09-20: an unfiltered pull on
     the Ole Miss-LSU Sept 19 game gave the WRONG team the EPA edge;
     filtered to scrimmage plays it correctly showed Ole Miss ahead,
     0.271 vs 0.167).
   - `cfbfastR::cfbd_game_box_advanced(game_id)` -- CFBD's advanced box
     score for that game: PPA and success rate by quarter, explosiveness,
     havoc (front seven / DB), line yards, stuff rate, field position,
     scoring opportunities and points per opportunity. Cheap second
     lens on the same game; use it alongside the pbp numbers.
   - `cfbfastR::cfbd_drives(year, week, team)` -- drive-level results
     (start position, plays, outcome) for "how the game turned" claims.

   **Pull the full stat menu, not EPA alone (changed 2026-10-05 to match
   boxscore-prophet's 2026-10-01 change).** EPA and success rate stay
   core in every storyline, but they are one lens among several -- the
   Week 4 2026 packets here led nearly every bullet with EPA/play,
   which is the staleness boxscore-prophet flagged. Pull every family
   below that applies to the storyline's teams AND opponents, lead each
   bullet with whichever stat tells that point most clearly, and rotate
   families across bullets so no single metric carries the packet. When
   two families disagree (e.g. a defense 40th in PPA allowed but 11th
   in explosiveness allowed), that disagreement is itself a nugget --
   report both.

   **Stat menu** (season ranks among all FBS or among P4 -- name the
   pool every time, see like-for-like below):
   - *Scoring/volume:* points per game for/against, yards per play,
     points per scoring opportunity (trip inside the 40), time of
     possession, penalties/penalty yards
     (`cfbd_stats_season_team`, `cfbd_stats_season_advanced`).
   - *Passing (off/def):* completion %, yards per attempt, sacks,
     INTs, explosive passes (20+), passing PPA and success rate.
   - *Rushing (off/def):* yards per carry, line yards, stuff rate,
     power success (short-yardage conversion), explosive runs (10+),
     rushing PPA and success rate.
   - *Situational:* 3rd/4th-down conversion %, red-zone/scoring-
     opportunity efficiency, turnover margin, havoc rate, field
     position (average starting spot).
   - *Efficiency:* EPA/play (pbp) or PPA (CFBD -- same concept,
     different source; never mix the two in one comparison), success
     rate, explosiveness, standard-down vs passing-down splits.
   - *Ratings (season-long, opponent-adjusted -- label as such):* SP+
     (`cfbd_ratings_sp`), FPI (`cfbd_ratings_fpi`), SRS
     (`cfbd_ratings_srs`), Elo (`cfbd_ratings_elo`). When ratings
     disagree with each other or with the poll, that's a nugget.
   - *Roster context (CFB-specific, no NFL analogue):* 247 talent
     composite (`cfbd_team_talent`) for "underperforming its talent"
     claims; returning production (`cfbd_player_returning`) for
     "rebuild year" or "experience" claims.
   - *Players (when a storyline turns on one):*
     `cfbd_game_player_stats` / `cfbd_stats_season_player` for box
     scores, `cfbd_metrics_ppa_players_season` for player PPA.

   **Two things make a "for real?" claim concrete instead of vibes:**
   - **Trend:** is the good (or bad) stuff steady across games, or is
     one outlier game carrying the season line? Build a short per-game
     log and say which.
   - **Who they did it against:** opponents' own SP+ (or PPA rank),
     FCS games called out separately, and a prior-season baseline for
     "back" / "collapse" claims. 4-0 against a schedule averaging -12
     SP+ (Nebraska, W4 2026) is a different story than 3-1 against
     contenders.

   **Like-for-like comparisons (ported from boxscore-prophet's
   2026-10-03 rule):** any comparison across seasons, teams, coaching
   regimes, or conferences uses the SAME stat, the SAME side (offense /
   defense / net), the SAME source, and a stated pool on both ends.
   Never pair one source's rank with another's (W4 2026 USC packet here
   put SP+ offense 3rd next to PPA offense 18th -- flagged, but it
   should have been one or the other, labeled). Name the pool every
   time ("119th of 138 FBS", "9th of 68 P4"). Partial seasons vs full
   seasons get the game count stated ("2026, 5 games"). If the
   like-for-like number isn't pulled, pull it before writing the
   bullet.

   **Record-vs-underlying mismatches:** flag close-game results
   (one-score wins/losses), turnover margin, non-offensive and
   special-teams TDs, and failed 2-pt / missed-kick swings -- but only
   when this team's data actually shows them, never as a stock
   explanation (see step 4).

   **Season-long context is secondary, cited explicitly as such, and
   only pulled in when it adds something the game-level number can't
   say on its own** (e.g. "LSU's offense has actually been better than
   this one result suggests" or "Ole Miss's trajectory under the new
   coach"):
   - `cfbfastR::cfbd_ratings_sp(year)` -- Bill Connelly's SP+ overall/
     offense/defense ratings, opponent-adjusted, season-to-date. Always
     label it as season-long when citing it next to a single-game EPA
     number -- they answer different questions and a reader (or Steve)
     can misread a season rating as describing the one game.
   - `cfbfastR::cfbd_stats_season_team(year)` -- season-aggregate team
     stats (points/yards for and against, etc.) -- good for "how has
     this team trended all year" claims.
   - **Coaching-change comparisons** (the Kiffin shape): pull multiple
     seasons of `cfbd_stats_season_team()` / `cfbd_game_info()` for the
     school, and split by coaching regime. No existing helper does this
     -- build the year range and label each season by coach manually.

   **Never state an EPA/success-rate/SP+ number from memory or estimate
   it -- always run the actual pull.** A wrong-direction number reads
   exactly as confident as a right one.

   Rate-limit awareness: `01c_load_college_stats.R`'s own pattern
   sleeps 0.3s between calls (`safe_pull()`) -- worth the same
   courtesy on fresh multi-call pulls here. Account is CFBD Tier 3
   (higher REST limits + GraphQL access), so this throttle is likely
   more conservative than required -- not yet re-tuned against it.

3. **Only if a specific draft-eligible prospect or a school's
   position-group track record is actually part of the storyline**,
   also check this project's own model outputs -- this is the
   exception, not a default step:
   - `output/2026_player_cards.csv` (or the current class's file) --
     `p_boom`/`p_bust`/`p_expected`/`verdict`/`program_note` for that
     specific prospect only. Don't pull this for a pure team/coach
     storyline that has no individual prospect in it.
   - `data/combined_board_mock_<date>.csv` / `combined_board_actual_
     <date>.csv` -- consensus big-board rank vs. mock-draft pick, if
     the storyline is specifically about where a player is being valued.
   - Program pipeline (`output/team_dev_leaderboard.csv`, or the raw
     `prog_pos_*` features in `data/02_draft_features.rds`) -- only
     when the storyline is explicitly about a program's *player
     development track record*, not general team performance. "Ole
     Miss's offense has been worse since Kiffin left" is a team-
     performance claim (step 2); "Ole Miss stopped producing NFL WRs"
     would be a program-pipeline claim (this step).
   - **Heisman-race storylines specifically**: don't rebuild this from
     scratch. `output/heisman_handoff/BRIEFING.md` already encodes this
     project's hardest-won findings on that exact topic (P4-only
     pooling, "count losses not wins," the Dante Moore stat-line trap)
     -- read it before writing a single Heisman number. Regenerate via
     `content_heisman_discovery_curve.R` if the underlying CSVs look
     stale for the current season.

4. **If the data contradicts the proposed storyline, say so plainly**
   and lead with what it actually shows, per `CONTENT_GUIDE.md`'s house
   style ("here's what everyone is saying -- now let's look at what the
   data actually shows"). A corrected nugget is usually a BETTER nugget.
   Two shapes this takes -- don't reach for just one out of habit:
   - **The premise doesn't hold up**: the coaching change everyone
     blames isn't actually where the numbers moved (e.g. the defense
     collapsed, not the offense Kiffin used to run) -- say so and
     redirect to what actually explains the loss.
   - **The premise holds up, but not for the stated reason**: LSU lost,
     but the box score shows it wasn't the offensive scheme gap
     everyone assumes -- it was turnovers, or a specific matchup. Report
     the real mechanism, not just confirmation of the headline.
   - **Score-implied illusion** (ported from boxscore-prophet): find
     what the final score itself implies that the underlying data does
     not support. W4 2026 Florida 52, Ole Miss 28 read as "dominant,"
     but per-play efficiency was nearly even (0.318 vs 0.277 EPA/play)
     and it was 24-21 late in the 3rd -- a strip-sack broke it open.
     Same move on Iowa 20, Michigan 19: the loser out-EPA'd the winner,
     and the margin was a kick-return TD plus a failed 2-pt try.
   The generalizable move is to check what the scoreline or headline
   implies against the data -- not to apply a stock explanation
   (turnovers, defense) out of habit when this game's data doesn't
   back it.

5. **Across the packet as a whole, lean toward genuinely surprising
   finds but don't suppress agreement or manufacture a contrarian angle
   the data doesn't support.** If the box score plainly backs the
   original storyline with no twist, say that -- "the data says exactly
   what you'd think, and here's the specific number that proves it" is
   still a real piece.

## Hard rules

- **Boom/bust language only appears when the packet is actually
  reporting this project's own prospect scoring.** Do not mention it,
  reference it, or reach for it in a team/coach/game storyline that has
  no scored prospect in it -- most packets from this skill won't touch
  it at all. When it DOES appear (a real draft-stock storyline), always
  report a range per `CONTENT_GUIDE.md` (e.g. "35-55% boom
  probability"), never a point estimate.
- **Coaches and programs are fair game for data-backed criticism --
  that's the brand's whole premise.** `CONTENT_GUIDE.md` bans
  disparaging "teams, coaches, or programs *without data backing*" --
  the operative word is "without." A claim like "Kiffin's offense was
  the reason Ole Miss won, and the numbers since he left prove it" is
  exactly the kind of narrative-checking this project exists to do,
  as long as the numbers in the packet actually support it.
- **Never generate claims about a PLAYER's character, work ethic, or
  intangibles** -- per `CONTENT_GUIDE.md`. This is about individual
  players specifically; it does not extend to a coach's play-calling,
  roster management, or program decisions, which are legitimate,
  data-checkable claims.
- **Nothing that could be mistaken for betting advice** -- no "value,"
  "edge" (betting sense), "lock," etc., per `CONTENT_GUIDE.md`.
- **Always credit data sources inline**: "Data via cfbfastR / College
  Football Data API."
- Nothing from this skill is a repo content artifact. Chat output by
  default; if Merrittocracy explicitly asks for a persisted file, it
  goes to `~/content/draft/` (the same folder this repo's own Building
  in Public Log already uses) -- never into this repo's `output/` or a
  `content/` folder here.

- **First use of any advanced/jargon stat gets a plain-language gloss
  inline** -- one short clause, not a paragraph (ported from
  boxscore-prophet). Later mentions of the same stat can go bare.

### Plain-language glossary (reuse this phrasing, only for terms actually used in a given packet)

- **EPA (Expected Points Added):** how many points a play added or cost
  the offense vs. what an average play would be expected to do in that
  down/distance/field-position situation. Same concept as the NFL
  version, computed by cfbfastR's play-by-play.
- **Success rate:** share of plays that kept the offense "on schedule"
  (roughly 50% of yards-to-go on 1st down, 70% on 2nd, 100% on 3rd/4th)
  -- a hit-rate stat, not a big-play stat.
- **PPA (Predicted Points Added):** College Football Data's own version
  of EPA -- same idea, different model. Use PPA or EPA within one
  comparison, never both.
- **Explosiveness:** average value of a team's successful plays -- how
  big the good plays are, as opposed to how often they happen.
- **Havoc rate:** share of plays where the defense records a tackle for
  loss, forced fumble, interception, or pass breakup.
- **Line yards / stuff rate:** rushing yards credited to the offensive
  line (first few yards of each run, weighted); share of runs stopped at
  or behind the line.
- **Points per scoring opportunity:** points per drive that reaches the
  opponent's 40 -- finishing drives, not just moving the ball.
- **FPI / SRS / Elo:** other season-long team ratings (ESPN's predictive
  index; margin adjusted for schedule; a win/loss rating that updates
  each game). Label as season-long, like SP+.
- **Talent composite:** 247Sports' roster talent score, built from
  recruiting rankings -- for "underperforming its talent" claims.
- **Returning production:** share of last season's production (by
  yards/snaps) still on the roster.
- **AV (Approximate Value):** Pro Football Reference's career-value
  metric -- only relevant for a prospect/draft-stock storyline, define
  on first use per `CONTENT_GUIDE.md`.
- **Boom / bust probability:** this project's own prospect-outcome
  model output -- only relevant when the storyline is actually about a
  specific scored prospect. See Hard rules above before using this term
  at all.
- **Program pipeline:** how good a specific school has been at
  developing a specific position group into the NFL, a rolling 10-year
  leave-one-out window -- only relevant for a player-development
  storyline, not a general team-performance one.
- **P4 (Power 4):** ACC, Big Ten, Big 12, SEC (plus Notre Dame,
  independent). Check which pool (P4 vs. all-FBS) a rank was computed
  against before repeating it -- an all-FBS pool usually measures pace,
  not quality (Group of 5 teams throw more against worse defenses).

## Output

Chat output, organized by storyline, each with a short list of sourced
bullets tagged by source category (cfbfastR game/season data / model --
only when actually used / program-pipeline -- only when actually used)
so Merrittocracy can see at a glance what's public-record vs.
house-differentiated. Rotate stat families across bullets (see the stat
menu in step 2) -- if every bullet in a storyline leads with EPA, rework
it. End each storyline with a one-line verdict (e.g. "for real:
efficiency and schedule both back the record" / "the score is ahead of
the underlying numbers"). Close by naming anything that came back weaker
or contrary to the proposed storyline, not just the supporting facts.
