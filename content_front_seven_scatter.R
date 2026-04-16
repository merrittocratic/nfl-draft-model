# ============================================================================
# content_front_seven_scatter.R
# Merrittocracy — Front Seven Article: EDGE Sack Specialist vs. Broad Disruptor
#
# Produces a scatter plot of first-round EDGE prospects (2006–2020):
#   X = sacks percentile (within draft class)
#   Y = broad disruption percentile (avg of sacks + TFL pctile)
#   Color = outcome class (boom / expected / bust)
#
# Thesis: elite sacks are necessary but not sufficient for EDGE boom outcomes.
# The position is volatile at the top regardless of college production profile.
#
# Input:  data/02_draft_features.rds
# Output: output/figures/edge_sack_specialist_scatter.png
# ============================================================================
source("00_config.R")
library(ggplot2)
library(ggrepel)

# ============================================================================
# A) LOAD & PREP
# ============================================================================
cli::cli_h1("Building EDGE sack specialist scatter")

draft_fe <- read_rds("data/02_draft_features.rds")

edge_r1 <- draft_fe |>
  filter(
    season %in% DRAFT_YEARS_TRAIN,
    !is.na(av_residual_z),
    position == "EDGE",
    round_num == 1,
    !is.na(def_sacks_pctile),
    !is.na(def_tot_pctile)
  ) |>
  mutate(
    outcome_class = factor(outcome_class, levels = c("boom", "expected", "bust")),
    # Only Quinn is labeled — the sole confirmed legitimate 0/0 in the danger zone.
    # Other 0/0 players are cfbfastR data artifacts (school/year coverage gaps):
    #   Jordan (2011, Cal): 62.5 tackles + 5.5 sacks confirmed via PFR
    #   Hughes (2010, TCU): 11.5 sacks confirmed via PFR
    #   Coples (2012, UNC): 7.5 sacks confirmed via PFR
    #   Harvey (2008, Florida): likely gap, unverified
    # Quinn (2011, UNC): suspended senior year — legitimately zero stats
    # Lawson (2016, Clemson): shoulder surgery, missed most of 2015 — likely legit
    label         = if_else(pfr_player_name == "Robert Quinn",
                            pfr_player_name, NA_character_)
  )

cli::cli_alert_info("n = {nrow(edge_r1)} first-round EDGE prospects with complete production data")
cli::cli_alert_info("Boom: {sum(edge_r1$outcome_class == 'boom')} | Expected: {sum(edge_r1$outcome_class == 'expected')} | Bust: {sum(edge_r1$outcome_class == 'bust')}")

# ============================================================================
# B) SCATTER PLOT
# ============================================================================

# 2026 overlay — percentiles from 05_predict_2026.R (within-2026-cohort ranks)
# Update if 05 is re-run before draft night
prospects_2026_overlay <- tibble(
  player_name      = c("Rueben Bain", "Arvell Reese", "David Bailey"),
  def_sacks_pctile = c(0.780,         0.709,          0.957),
  def_tot_pctile   = c(0.660,         0.986,          0.433)
)

p <- ggplot(edge_r1, aes(x = def_sacks_pctile, y = def_tot_pctile, color = outcome_class)) +
  geom_vline(xintercept = 0.5, linetype = "dashed", color = "grey60", linewidth = 0.4) +
  geom_hline(yintercept = 0.5, linetype = "dashed", color = "grey60", linewidth = 0.4) +
  geom_point(size = 3.5, alpha = 0.85,
             position = position_jitter(width = 0.02, height = 0.02, seed = 42)) +
  ggrepel::geom_text_repel(
    aes(label = label),
    size = 3, color = "grey20", fontface = "italic",
    na.rm = TRUE, max.overlaps = 20,
    box.padding = 0.4, point.padding = 0.3,
    nudge_x = 0.15, direction = "y",
    segment.color = "grey50", segment.size = 0.3
  ) +
  # 2026 prospects overlay — triangles, labeled
  geom_point(
    data = prospects_2026_overlay,
    aes(x = def_sacks_pctile, y = def_tot_pctile),
    shape = 17, size = 4, color = "black", inherit.aes = FALSE
  ) +
  ggrepel::geom_text_repel(
    data = prospects_2026_overlay,
    aes(x = def_sacks_pctile, y = def_tot_pctile, label = player_name),
    size = 3, color = "black", fontface = "bold",
    box.padding = 0.5, point.padding = 0.3,
    segment.color = "grey40", segment.size = 0.3,
    inherit.aes = FALSE
  ) +
  scale_color_manual(
    values = c(boom = "#2196F3", expected = "grey70", bust = "#F44336"),
    labels = c("Boom", "Expected", "Bust")
  ) +
  scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  coord_cartesian(xlim = c(0, 1), ylim = c(0, 1)) +
  labs(
    title    = "First-Round EDGE: Pass Rusher vs. All-Around Defender",
    subtitle = "Draft classes 2006–2020 (circles) + 2026 key prospects (triangles) | Production profile doesn't predict who busts",
    x        = "Sacks Percentile (within draft class)",
    y        = "Total Tackles Percentile (within draft class)",
    color    = "Outcome",
    caption  = "Source: Pro Football Reference + cfbfastR. Boom = std. residual > 1 vs. pick expectation. Bust < \u22121."
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title    = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = "grey40", size = 11),
    plot.caption  = element_text(color = "grey50", size = 9),
    legend.position = "right"
  )

# ============================================================================
# C) SAVE
# ============================================================================

out_path <- "output/figures/edge_pass_rusher_vs_allround_scatter.png"
ggsave(out_path, p, width = 9, height = 6, dpi = 300)
cli::cli_alert_success("Saved {out_path}")
