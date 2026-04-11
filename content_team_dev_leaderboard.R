# ============================================================================
# content_team_dev_leaderboard.R
# Merrittocracy — NFL Team Draft Development Quality Lollipop Chart
#
# Ranks franchises by pick-adjusted AV residual (2006–2020 draft classes).
# Positive = team consistently gets more than expected; negative = less.
# Relocated franchises flagged — both movers improved dramatically post-move.
#
# Input:  output/team_dev_leaderboard.csv
# Output: output/figures/team_dev_leaderboard.png
# ============================================================================
source("00_config.R")
library(ggplot2)
library(ggtext)
library(scales)

# ============================================================================
# A) LOAD & PREP
# ============================================================================
leaderboard <- read_csv("output/team_dev_leaderboard.csv", show_col_types = FALSE)

# Franchise relocation labels — show both eras as a callout
relocation_map <- tibble(
  team     = c("LAC", "SDG", "LAR", "STL"),
  label    = c("LAC\n(post-move)", "SDG\n(pre-move)", "LAR\n(post-move)", "STL\n(pre-move)"),
  pair     = c("chargers", "chargers", "rams", "rams")
)

leaderboard <- leaderboard |>
  left_join(relocation_map, by = "team") |>
  mutate(
    label       = coalesce(label, team),
    is_relocated = !is.na(pair),
    dot_color   = case_when(
      team %in% c("LAC", "LAR")         ~ "#2563EB",   # post-move (positive story)
      team %in% c("SDG", "STL")         ~ "#DC2626",   # pre-move  (negative story)
      resid_mean > 0                     ~ "#16A34A",   # above average
      TRUE                               ~ "#6B7280"    # below average
    ),
    team_label  = ifelse(is_relocated, label, team)
  ) |>
  arrange(resid_mean) |>
  mutate(team = factor(team, levels = team))

# ============================================================================
# B) CHART
# ============================================================================
p <- ggplot(leaderboard, aes(x = resid_mean, y = team)) +
  # Zero reference line
  geom_vline(xintercept = 0, color = "#374151", linewidth = 0.5, linetype = "dashed") +
  # Lollipop stem
  geom_segment(
    aes(x = 0, xend = resid_mean, y = team, yend = team, color = dot_color),
    linewidth = 0.7
  ) +
  # Lollipop dot
  geom_point(aes(color = dot_color), size = 3.5) +
  # Team labels
  geom_text(
    aes(
      x     = resid_mean + ifelse(resid_mean >= 0, 0.008, -0.008),
      label = team_label,
      hjust = ifelse(resid_mean >= 0, 0, 1),
      color = dot_color
    ),
    size      = 2.6,
    lineheight = 0.85,
    fontface  = "bold"
  ) +
  scale_color_identity() +
  scale_x_continuous(
    breaks = seq(-0.25, 0.25, by = 0.05),
    labels = function(x) ifelse(x == 0, "0", sprintf("%+.2f", x)),
    expand = expansion(mult = c(0.18, 0.22))
  ) +
  labs(
    title    = "Which NFL franchises develop draft picks?",
    subtitle = "Pick-adjusted AV residual, 2006–2020 draft classes (min. 10 picks)\n<span style='color:#2563EB'>**Blue = post-relocation**</span>  <span style='color:#DC2626'>**Red = pre-relocation**</span>  <span style='color:#16A34A'>**Green = above average**</span>",
    x        = "Avg. AV residual vs. pick expectation (standardized)",
    y        = NULL,
    caption  = "Merrittocracy • themerrittocracy.substack.com\nPick-adjusted residual: how far above/below the historical AV curve for that draft slot"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title         = element_text(face = "bold", size = 14, margin = margin(b = 4)),
    plot.subtitle      = element_markdown(size = 9, color = "#374151", margin = margin(b = 12)),
    plot.caption       = element_text(size = 7.5, color = "#6B7280", hjust = 0),
    axis.text.y        = element_blank(),
    axis.ticks.y       = element_blank(),
    panel.grid.major.y = element_blank(),
    panel.grid.minor   = element_blank(),
    panel.grid.major.x = element_line(color = "#E5E7EB", linewidth = 0.4),
    plot.background    = element_rect(fill = "white", color = NA),
    plot.margin        = margin(16, 24, 12, 16)
  )

# ============================================================================
# C) SAVE
# ============================================================================
ggsave(
  "output/figures/team_dev_leaderboard.png",
  plot   = p,
  width  = 8,
  height = 10,
  dpi    = 300,
  bg     = "white"
)

cli::cli_alert_success("Saved output/figures/team_dev_leaderboard.png")
