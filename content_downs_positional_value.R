# ============================================================================
# content_downs_positional_value.R
# Merrittocracy — Caleb Downs / Positional Value Article Table
#
# Produces the gt boom/bust table for the "Is Safety the Safest Pick?"
# article about Caleb Downs and first-round DB value.
#
# Input:  data/02_draft_features.rds  (pipeline output — run 01 → 01b → 02 first)
# Output: output/figures/downs_positional_value_table.png
#
# Copy output to content/graphics/ for publication.
# ============================================================================
source("00_config.R")
library(gt)

# ============================================================================
# A) LOAD & PREP
# ============================================================================
cli::cli_h1("Building positional value table — Downs article")

draft_fe <- read_rds("data/02_draft_features.rds")

# Readable position group labels for the table
group_labels <- c(
  "qb"    = "QB",
  "wr_te" = "WR/TE",
  "dl"    = "DL",
  "ol"    = "OL",
  "cb"    = "CB",
  "s"     = "S",
  "lb"    = "LB",
  "rb"    = "RB"
)

rd1 <- draft_fe |>
  filter(
    season %in% DRAFT_YEARS_TRAIN,
    round_num == 1,
    !is.na(outcome_class)
  ) |>
  mutate(pos_group = group_labels[model_group])

cli::cli_alert_info("First-round picks with outcome labels: {nrow(rd1)}")

# ============================================================================
# B) AGGREGATE BY POSITION GROUP
# ============================================================================

pos_table <- rd1 |>
  group_by(pos_group) |>
  summarise(
    n_drafted      = n(),
    boom_n         = sum(outcome_class == "boom"),
    bust_n         = sum(outcome_class == "bust"),
    boom_rate      = boom_n / n_drafted,
    bust_rate      = bust_n / n_drafted,
    boom_bust_diff = boom_rate - bust_rate,
    avg_4yr_av     = mean(av_4yr, na.rm = TRUE),
    .groups = "drop"
  ) |>
  arrange(desc(boom_bust_diff))

cli::cli_h2("Position group results (Round 1)")
print(pos_table |> select(pos_group, n_drafted, boom_rate, bust_rate, boom_bust_diff))

# ============================================================================
# C) BUILD GT TABLE
# ============================================================================

article_table <- pos_table |>
  select(pos_group, n_drafted, boom_rate, bust_rate, boom_bust_diff, avg_4yr_av) |>
  gt() |>
  tab_header(
    title    = md("**First-Round Boom & Bust Rates by Position Group**"),
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
  fmt_percent(columns = c(boom_rate, bust_rate, boom_bust_diff), decimals = 1) |>
  fmt_number(columns = avg_4yr_av, decimals = 1) |>
  data_color(
    columns = boom_bust_diff,
    palette = c("#d73027", "#fee08b", "#1a9850"),
    domain  = c(-0.3, 0.3)
  ) |>
  data_color(
    columns = bust_rate,
    palette = c("#1a9850", "#fee08b", "#d73027"),
    domain  = c(0, 0.5)
  ) |>
  # Bold the S row — Caleb Downs' position group
  tab_style(
    style     = cell_text(weight = "bold"),
    locations = cells_body(rows = pos_group == "S")
  ) |>
  # Subtle highlight on CB — the risk/reward counterpoint
  tab_style(
    style     = cell_fill(color = "#fff3f3"),
    locations = cells_body(rows = pos_group == "CB")
  ) |>
  # Subtle highlight on RB — the cautionary counterpoint
  tab_style(
    style     = cell_fill(color = "#fff3f3"),
    locations = cells_body(rows = pos_group == "RB")
  ) |>
  tab_source_note(
    source_note = md(
      paste0(
        "Source: Pro Football Reference. Boom = std. residual > 1. ",
        "Bust = std. residual < \u20131. AV adjusted for draft position.<br>",
        "CB and S modeled separately. DL combines EDGE and IDL."
      )
    )
  ) |>
  tab_footnote(
    footnote  = "Boom rate minus bust rate. Higher = safer investment.",
    locations = cells_column_labels(columns = boom_bust_diff)
  ) |>
  tab_options(
    heading.title.font.size        = px(18),
    heading.subtitle.font.size     = px(13),
    table.font.size                = px(13),
    column_labels.font.weight      = "bold",
    source_notes.font.size         = px(10),
    table.width                    = pct(100)
  ) |>
  cols_align(align = "center", columns = -pos_group) |>
  cols_align(align = "left",   columns = pos_group)

# ============================================================================
# D) EXPORT
# ============================================================================

out_path <- "output/figures/downs_positional_value_table.png"
gtsave(article_table, out_path, vwidth = 700)
cli::cli_alert_success("Table saved to {out_path}")
cli::cli_alert_info("Copy to content/graphics/ for publication.")

# ============================================================================
# E) SPOT CHECK — first-round DBs
# ============================================================================
cli::cli_h2("First-round DB picks — spot check classifications")

rd1 |>
  filter(model_group == "db") |>
  arrange(season, pick) |>
  select(pfr_player_name, season, pick, position,
         av_4yr, expected_av, av_residual_z, outcome_class) |>
  print(n = 50)
