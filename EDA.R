# ============================================================================
# EDA.R — Exploratory Data Analysis
# Signal validation before model training.
#
# Reads:  data/02_draft_features.rds
# Writes: output/figures/eda/*.png
#
# Run after 02_feature_engineering.R, before 03_model_spec.R.
# ============================================================================
source("00_config.R")
library(ggridges)
library(tidytext) 

dir.create("output/figures/eda", showWarnings = FALSE, recursive = TRUE)

draft_fe <- read_rds("data/02_draft_features.rds")

train <- draft_fe |>
  filter(season %in% DRAFT_YEARS_TRAIN, !is.na(outcome_class))

# Readable group labels for facets
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

train <- train |>
  mutate(
    group_label  = group_labels[model_group],
    outcome_class = factor(outcome_class, levels = c("boom", "expected", "bust"))
  )

outcome_colors <- c("boom" = "#1a9850", "expected" = "#878787", "bust" = "#d73027")

# ============================================================================
# A) OUTCOME DISTRIBUTIONS PER GROUP
# ============================================================================
cli::cli_h1("A) Outcome distributions")

p_outcomes <- train |>
  count(group_label, outcome_class) |>
  group_by(group_label) |>
  mutate(pct = n / sum(n)) |>
  ggplot(aes(x = outcome_class, y = pct, fill = outcome_class)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = scales::percent(pct, accuracy = 1)),
            vjust = -0.3, size = 3) +
  facet_wrap(~ group_label, nrow = 2) +
  scale_fill_manual(values = outcome_colors) +
  scale_y_continuous(labels = scales::percent_format(), limits = c(0, 1)) +
  labs(title = "Outcome Distribution by Position Group",
       subtitle = "Training data 2006–2020",
       x = NULL, y = NULL) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "none",
        strip.text = element_text(face = "bold"))

ggsave("output/figures/eda/A_outcome_distributions.png",
       p_outcomes, width = 10, height = 5, dpi = 150)
cli::cli_alert_success("Saved A_outcome_distributions.png")

# ============================================================================
# B) FEATURE DISTRIBUTIONS BY OUTCOME CLASS
# Ridgeline plots — one chart per feature family, faceted by group
# Only plotted for groups / eras where coverage is meaningful
# ============================================================================
cli::cli_h1("B) Feature distributions by outcome class")

save_ridgeline <- function(data, feature, title, filename, groups = NULL) {
  plot_data <- data
  if (!is.null(groups)) plot_data <- plot_data |> filter(model_group %in% groups)
  plot_data <- plot_data |> filter(!is.na(.data[[feature]]))

  if (nrow(plot_data) < 30) {
    cli::cli_alert_warning("Skipping {filename} — insufficient data")
    return(invisible(NULL))
  }

  p <- plot_data |>
    ggplot(aes(x = .data[[feature]], y = outcome_class,
               fill = outcome_class, color = outcome_class)) +
    geom_density_ridges(alpha = 0.55, scale = 0.9, rel_min_height = 0.01) +
    facet_wrap(~ group_label, scales = "free_x") +
    scale_fill_manual(values  = outcome_colors) +
    scale_color_manual(values = outcome_colors) +
    labs(title = title,
         subtitle = "Training data 2006–2020 | covered seasons only",
         x = feature, y = NULL) +
    theme_minimal(base_size = 11) +
    theme(legend.position = "none",
          strip.text = element_text(face = "bold"))

  ggsave(glue::glue("output/figures/eda/{filename}.png"),
         p, width = 12, height = 6, dpi = 150)
  cli::cli_alert_success("Saved {filename}.png")
}

# -- Athleticism (all groups) -------------------------------------------------
save_ridgeline(train, "athleticism_composite",
               "Athleticism Composite by Outcome Class",
               "B1_athleticism_composite")

save_ridgeline(train, "forty",
               "40-Yard Dash by Outcome Class",
               "B2_forty")

# -- Draft context (all groups) -----------------------------------------------
save_ridgeline(train, "log_pick",
               "Draft Pick (log) by Outcome Class",
               "B3_log_pick")

save_ridgeline(train, "draft_age",
               "Draft Age by Outcome Class",
               "B4_draft_age")

# -- College production: offense ----------------------------------------------
save_ridgeline(
  train |> filter(pass_coverage_era),
  "qb_ypa_pctile",
  "College Yards Per Attempt Percentile by Outcome Class",
  "B5_qb_ypa_pctile", groups = "qb"
)

save_ridgeline(
  train |> filter(pass_coverage_era),
  "qb_cmp_pct_pctile",
  "College Completion % Percentile by Outcome Class",
  "B6_qb_cmp_pct_pctile", groups = "qb"
)

save_ridgeline(
  train |> filter(pass_coverage_era),
  "rush_ypc_pctile",
  "College Rush YPC Percentile by Outcome Class",
  "B7_rush_ypc_pctile", groups = c("rb", "qb")
)

save_ridgeline(
  train |> filter(pass_coverage_era),
  "rec_ypr_pctile",
  "College Yards Per Reception Percentile by Outcome Class",
  "B8_rec_ypr_pctile", groups = c("wr_te", "rb")
)

save_ridgeline(
  train |> filter(pass_coverage_era),
  "rec_rec_pctile",
  "College Receptions Percentile by Outcome Class",
  "B9_rec_volume_pctile", groups = c("wr_te", "rb")
)

# -- College production: defense ----------------------------------------------
save_ridgeline(
  train |> filter(def_coverage_era),
  "def_sacks_pctile",
  "College Sacks Percentile by Outcome Class",
  "B10_def_sacks_pctile", groups = c("dl", "lb")
)

save_ridgeline(
  train |> filter(def_coverage_era),
  "def_tfl_pctile",
  "College TFL Percentile by Outcome Class",
  "B11_def_tfl_pctile", groups = c("dl", "lb")
)

save_ridgeline(
  train |> filter(def_coverage_era),
  "def_pbu_pctile",
  "College Pass Breakups Percentile by Outcome Class",
  "B12_def_pbu_pctile", groups = c("cb", "s")
)

save_ridgeline(
  train |> filter(def_coverage_era),
  "int_int_pctile",
  "College Interceptions Percentile by Outcome Class",
  "B13_int_pctile", groups = c("cb", "s")
)

# -- Program pipeline ---------------------------------------------------------
save_ridgeline(train, "prog_pos_boom_rate",
               "Program Position Boom Rate (10-yr) by Outcome Class",
               "B14_prog_pos_boom_rate")

save_ridgeline(train, "prog_all_av_mean",
               "Program Overall AV Mean (10-yr) by Outcome Class",
               "B15_prog_all_av_mean")

# ============================================================================
# C) CORRELATIONS WITH av_residual_z PER GROUP
# ============================================================================
cli::cli_h1("C) Feature correlations with outcome")

numeric_features <- c(
  "log_pick", "draft_age", "athleticism_composite", "n_combine_tests",
  "forty", "vertical", "broad_jump", "cone", "shuttle", "bench", "wt", "ht",
  "prog_pos_n", "prog_pos_av_mean", "prog_pos_boom_rate", "prog_pos_bust_rate",
  "prog_all_n", "prog_all_av_mean", "prog_all_boom_rate", "college_av_pctile",
  "qb_ypa_pctile", "qb_cmp_pct_pctile", "qb_td_pct_pctile", "qb_int_pct_pctile",
  "rush_ypc_pctile", "rush_att_pctile",
  "rec_ypr_pctile", "rec_rec_pctile", "rec_td_pctile",
  "def_tot_pctile", "def_sacks_pctile", "def_tfl_pctile", "def_pbu_pctile",
  "int_int_pctile"
)

# Keep only features that exist in the data
numeric_features <- intersect(numeric_features, names(train))

corr_data <- train |>
  filter(!is.na(av_residual_z)) |>
  group_by(model_group, group_label) |>
  summarise(
    across(
      all_of(numeric_features),
      ~ suppressWarnings(cor(.x, av_residual_z, use = "pairwise.complete.obs")),
      .names = "{.col}"
    ),
    .groups = "drop"
  ) |>
  pivot_longer(all_of(numeric_features), names_to = "feature", values_to = "r") |>
  filter(!is.na(r)) |>
  mutate(direction = if_else(r >= 0, "positive", "negative"))

# Top 15 features per group by absolute correlation
top_corr <- corr_data |>
  group_by(group_label) |>
  slice_max(order_by = abs(r), n = 15) |>
  ungroup() |>
  mutate(feature = reorder_within(feature, r, group_label))

p_corr <- top_corr |>
  ggplot(aes(x = r, y = feature, fill = direction)) +
  geom_col() +
  geom_vline(xintercept = 0, linewidth = 0.4, color = "grey30") +
  facet_wrap(~ group_label, scales = "free_y", nrow = 2) +
  scale_fill_manual(values = c("positive" = "#1a9850", "negative" = "#d73027")) +
  scale_y_reordered() +
  labs(title = "Feature Correlations with AV Residual (r)",
       subtitle = "Top 15 features per group | Training data 2006–2020",
       x = "Pearson r", y = NULL) +
  theme_minimal(base_size = 10) +
  theme(legend.position = "none",
        strip.text = element_text(face = "bold"))

ggsave("output/figures/eda/C_feature_correlations.png",
       p_corr, width = 16, height = 10, dpi = 150)
cli::cli_alert_success("Saved C_feature_correlations.png")

# Print top 5 per group to console
cli::cli_h2("Top 5 correlates per group")
corr_data |>
  group_by(group_label) |>
  slice_max(order_by = abs(r), n = 5) |>
  arrange(group_label, desc(abs(r))) |>
  select(group_label, feature, r) |>
  mutate(r = round(r, 3)) |>
  print(n = 50)

# ============================================================================
# D) CONTENT-READY CHARTS — mean feature value by outcome class
# ============================================================================
cli::cli_h1("D) Content charts — mean feature by outcome")

save_outcome_means <- function(data, features, title, filename, groups = NULL) {
  plot_data <- data
  if (!is.null(groups)) plot_data <- plot_data |> filter(model_group %in% groups)

  plot_data <- plot_data |>
    select(group_label, outcome_class, all_of(features)) |>
    pivot_longer(all_of(features), names_to = "feature", values_to = "value") |>
    filter(!is.na(value)) |>
    group_by(group_label, outcome_class, feature) |>
    summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop")

  p <- plot_data |>
    ggplot(aes(x = outcome_class, y = mean_val, fill = outcome_class)) +
    geom_col(width = 0.65) +
    facet_grid(feature ~ group_label, scales = "free_y") +
    scale_fill_manual(values = outcome_colors) +
    labs(title = title,
         subtitle = "Mean value by outcome class | Training data 2006–2020",
         x = NULL, y = "Mean") +
    theme_minimal(base_size = 10) +
    theme(legend.position = "none",
          strip.text = element_text(face = "bold"),
          axis.text.x = element_text(angle = 30, hjust = 1))

  ggsave(glue::glue("output/figures/eda/{filename}.png"),
         p, width = 14, height = 7, dpi = 150)
  cli::cli_alert_success("Saved {filename}.png")
}

# Athleticism + draft context — all groups
save_outcome_means(
  train,
  c("athleticism_composite", "log_pick", "draft_age"),
  "Draft Context & Athleticism by Outcome",
  "D1_context_athleticism"
)

# College offense — covered seasons only
save_outcome_means(
  train |> filter(pass_coverage_era),
  c("rush_ypc_pctile", "rec_ypr_pctile", "rec_rec_pctile"),
  "Offensive College Production by Outcome (Covered Seasons)",
  "D2_college_offense",
  groups = c("qb", "rb", "wr_te")
)

# College defense — covered seasons only
save_outcome_means(
  train |> filter(def_coverage_era),
  c("def_sacks_pctile", "def_tfl_pctile", "def_pbu_pctile", "int_int_pctile"),
  "Defensive College Production by Outcome (Covered Seasons)",
  "D3_college_defense",
  groups = c("dl", "lb", "cb", "s")
)

cli::cli_h1("EDA complete")
cli::cli_alert_info("Charts saved to output/figures/eda/")
cli::cli_alert_info(
  "Key question: do college pctile features show outcome separation? ",
  "If ridgelines overlap heavily, signal is weak."
)
