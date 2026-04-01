# ============================================================================
# install_check.R
# Run this on the modeling machine after an R version upgrade.
# Checks all required packages, installs missing ones, flags known gotchas.
# ============================================================================

options(repos = c(CRAN = "https://cloud.r-project.org"))

cat("R version:", R.version.string, "\n\n")

# All packages needed by the pipeline
pkgs <- c(
  # Core modeling
  "tidyverse", "tidymodels",
  "xgboost", "ranger", "finetune", "baguette", "probably",
  # Deep learning (torch must be installed before tabnet)
  "torch", "tabnet",
  # NFL data
  "nflreadr",
  # Feature engineering / joining
  "fuzzyjoin", "stringdist",
  # Scraping
  "rvest", "polite",
  # Content / output
  "gt", "scales", "glue", "cli",
  # Python bridge (for TabPFN)
  "reticulate"
)

# ---- Check what's installed vs missing -------------------------------------

installed_pkgs <- rownames(installed.packages())
missing <- setdiff(pkgs, installed_pkgs)
present <- intersect(pkgs, installed_pkgs)

cat("=== Installed (", length(present), "/", length(pkgs), ") ===\n")
ip <- installed.packages()[present, "Version", drop = FALSE]
print(ip)

if (length(missing) == 0) {
  cat("\nAll packages present. Running load checks...\n")
} else {
  cat("\n=== Missing (", length(missing), ") ===\n")
  print(missing)
  cat("\nInstalling missing packages...\n")

  # Install torch BEFORE tabnet (tabnet depends on torch)
  if ("torch" %in% missing) {
    cat("\n[torch] Installing torch package...\n")
    install.packages("torch")
    missing <- setdiff(missing, "torch")
  }

  # Install everything else (except tabnet — handled after torch loads)
  other_missing <- setdiff(missing, "tabnet")
  if (length(other_missing) > 0) {
    install.packages(other_missing)
  }

  # tabnet last
  if ("tabnet" %in% missing) {
    install.packages("tabnet")
  }
}

# ---- torch: requires a second step to download the C++ backend -------------

if ("torch" %in% rownames(installed.packages())) {
  cat("\n[torch] Checking C++ backend...\n")
  tryCatch({
    library(torch)
    cat("[torch] Backend OK — version:", as.character(torch_version()), "\n")
  }, error = function(e) {
    cat("[torch] Backend NOT installed. Run this:\n")
    cat("  torch::install_torch()\n")
    cat("  (Downloads ~500MB — do once per R version upgrade)\n")
  })
} else {
  cat("[torch] Not installed — run install_check.R again after installing.\n")
}

# ---- xgboost version check -------------------------------------------------
# xgboost 3.x changed the API vs 2.x. tidymodels parsnip wraps it, so
# direct xgb.train() calls (if any) may need updating.

if ("xgboost" %in% rownames(installed.packages())) {
  xgb_ver <- packageVersion("xgboost")
  cat("\n[xgboost] Installed version:", as.character(xgb_ver), "\n")
  if (xgb_ver >= "3.0.0") {
    cat("[xgboost] v3.x detected — breaking changes from v2.x:\n")
    cat("  - xgb.DMatrix() 'data' arg renamed; use xgb.DMatrix(data = ...)\n")
    cat("  - Some nthread defaults changed\n")
    cat("  - tidymodels parsnip handles this — direct xgb calls may need review\n")
  }
}

# ---- Load check: try library() on everything installed --------------------

cat("\n=== Load checks ===\n")
for (pkg in pkgs) {
  if (pkg %in% rownames(installed.packages())) {
    result <- tryCatch({
      suppressPackageStartupMessages(library(pkg, character.only = TRUE))
      "OK"
    }, error = function(e) paste("FAILED:", conditionMessage(e)))
    cat(sprintf("  %-15s %s\n", pkg, result))
  } else {
    cat(sprintf("  %-15s NOT INSTALLED\n", pkg))
  }
}

cat("\nDone. Fix any FAILED entries before running the pipeline.\n")
