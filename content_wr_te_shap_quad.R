# ============================================================================
# content_wr_te_shap_quad.R
# Merrittocracy — WR/TE Article: Faceted SHAP waterfall, 4 prospects
#
# Produces a 2×2 patchwork of individual SHAP waterfall plots for:
#   Carnell Tate (WR, Ohio State)
#   Jordyn Tyson (WR, Arizona State)
#   Makai Lemon  (WR, USC)
#   Kenyon Sadiq (TE, Oregon)
#
# Requires: install.packages(c("shapviz", "patchwork"))
# Requires: data/05_scored_2026.rds  (written by 05_predict_2026.R)
#
# Input:  data/04_best_models.rds, data/02_feature_names.rds,
#         data/05_scored_2026.rds
# Output: output/figures/shap/wr_te_shap_quad.png
# ============================================================================
source("00_config.R")
library(shapviz)
library(patchwork)
library(ggplot2)

# ============================================================================
# A) LOAD
# ============================================================================
cli::cli_h1("WR/TE SHAP quad plot")

best_models     <- map(read_rds("data/04_best_models.rds"), bundle::unbundle)
shared_features <- read_rds("data/02_feature_names.rds")
scored_2026     <- read_rds("data/05_scored_2026.rds")

TARGET_PLAYERS <- c("Carnell Tate", "Jordyn Tyson", "Makai Lemon", "Kenyon Sadiq")

group_raw <- scored_2026 |> filter(model_group == "wr_te")

missing <- setdiff(TARGET_PLAYERS, group_raw$player_name)
if (length(missing) > 0) {
  cli::cli_abort("Players not found in scored_2026: {paste(missing, collapse = ', ')}")
}

# ============================================================================
# B) COMPUTE SHAP FOR wr_te GROUP
# ============================================================================
model  <- best_models[["wr_te"]]
rec    <- extract_recipe(model)
baked  <- bake(rec, new_data = group_raw |> select(position_in_group, all_of(shared_features)))
X_mat  <- baked |> select(-any_of("av_residual_z")) |> data.matrix()

shp <- shapviz(extract_fit_engine(model), X_pred = X_mat, X = baked)

cli::cli_alert_success("SHAP computed for {nrow(group_raw)} wr_te prospects")

# ============================================================================
# C) BUILD INDIVIDUAL WATERFALL PLOTS
# ============================================================================

# Helper: player metadata string for subtitle
player_meta <- function(nm) {
  row <- scored_2026 |> filter(player_name == nm)
  glue::glue(
    "{row$position} | {row$school} | Pick ~{row$pick_est} | ",
    "Boom {scales::percent(row$p_boom, accuracy=1)}  ",
    "Bust {scales::percent(row$p_bust, accuracy=1)}"
  )
}

make_waterfall <- function(nm) {
  i <- which(group_raw$player_name == nm)
  sv_waterfall(shp, row_id = i, max_display = 10L) +
    labs(
      title    = nm,
      subtitle = player_meta(nm)
    ) +
    theme(
      plot.title    = element_text(face = "bold", size = 11),
      plot.subtitle = element_text(size = 8, color = "gray40")
    )
}

plots <- map(TARGET_PLAYERS, make_waterfall)

# ============================================================================
# D) COMBINE & SAVE
# ============================================================================
quad <- (plots[[1]] | plots[[2]]) / (plots[[3]] | plots[[4]]) +
  plot_annotation(
    title   = "2026 WR/TE Draft Class — SHAP Feature Attribution",
    caption = "Model: XGBoost | Outcome: pick-adjusted 4-yr AV z-score | Merrittocracy"
  )

dir.create("output/figures/shap", showWarnings = FALSE, recursive = TRUE)
ggsave("output/figures/shap/wr_te_shap_quad.png", quad, width = 16, height = 12, dpi = 150)
cli::cli_alert_success("Saved output/figures/shap/wr_te_shap_quad.png")
