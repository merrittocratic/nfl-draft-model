# ============================================================================
# draft_night_helper.R
# Source this after running 05_predict_2026.R.
# Call pick("Player Name") to get the player card + SHAP file path.
# ============================================================================

player_cards <- read_csv("output/2026_player_cards.csv", show_col_types = FALSE)

pick <- function(name) {
  row <- player_cards |> dplyr::filter(tolower(player) == tolower(name))

  if (nrow(row) == 0) {
    # Fuzzy fallback — partial match
    row <- player_cards |> dplyr::filter(grepl(tolower(name), tolower(player)))
  }

  if (nrow(row) == 0) {
    cat("Player not found:", name, "\n")
    return(invisible(NULL))
  }

  if (nrow(row) > 1) {
    cat("Multiple matches — showing first. Others:", paste(row$player[-1], collapse = ", "), "\n")
    row <- row[1, ]
  }

  shap_name <- gsub("[^A-Za-z]", "_", row$player)
  shap_path <- glue::glue("output/figures/shap/{row$model_group}_waterfall_{shap_name}.png")
  shap_exists <- file.exists(shap_path)

  cat("─────────────────────────────────────\n")
  cat(glue::glue("{row$player} | {row$position} | {row$school}\n"))
  cat(glue::glue("Pick: {row$pick_est}  |  Verdict: {row$verdict}\n"))
  cat(glue::glue("Boom: {row$p_boom}  |  Bust: {row$p_bust}  |  Expected: {row$p_expected}\n"))
  cat(glue::glue("Predicted z: {row$predicted_z}  |  Athleticism: {row$athleticism}\n"))
  cat(glue::glue("Program: {row$program_note}\n"))
  cat("─────────────────────────────────────\n")
  cat(glue::glue("SHAP: {shap_path}",
                 if (!shap_exists) "  ⚠️  FILE NOT FOUND" else "  ✓", "\n"))
  cat("─────────────────────────────────────\n")

  invisible(row)
}
