set.seed(777)

library(glue)
library(sits)

# -----------------------------------------------------------------------------
# Setup directories
# -----------------------------------------------------------------------------
base_dir <- file.path("~/classification-cerrado", "data", "derived")
samples_dir <- file.path(base_dir, "timeseries")
models_dir <- file.path(base_dir, "models")

dir.create(models_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(models_dir))

# -----------------------------------------------------------------------------
# Versions
# -----------------------------------------------------------------------------
model_method <- "tempcnn"
ml_method <- sits_tempcnn()
samples_version <- "cer-v15a" # <- was "cer-v14a"
model_version <- glue("{model_method}-{samples_version}")

# -----------------------------------------------------------------------------
# Files
# -----------------------------------------------------------------------------
samples_file <- file.path(samples_dir, glue("samples-{samples_version}.rds"))
model_file <- file.path(models_dir, glue("model-{model_version}.rds"))
acc_model_file <- file.path(models_dir, glue("model-{model_version}_acc.rds"))

log_msg <- function(...) {
  message(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " | ", ...)
}

# -----------------------------------------------------------------------------
# Load samples
# -----------------------------------------------------------------------------
stopifnot(file.exists(samples_file))
samples <- readRDS(samples_file)
log_msg("Loaded ", nrow(samples), " samples")

# -----------------------------------------------------------------------------
# Pre-flight check: TempCNN needs every sample to share the same number of
# time steps. v15a binds v14a with newly extracted 2-year Pasture series,
# so confirm they share one temporal length before training.
# -----------------------------------------------------------------------------
n_times <- vapply(samples$time_series, nrow, integer(1))
tt <- table(n_times)
log_msg(
  "Time-steps per sample -> ",
  paste0(names(tt), " steps: ", as.integer(tt), collapse = " | ")
)

if (length(unique(n_times)) > 1) {
  stop(
    "Samples have inconsistent time-series lengths (",
    paste(sort(unique(n_times)), collapse = ", "),
    "). TempCNN requires a single fixed length. ",
    "Check that v14a and the v15a Pasture series cover the same temporal window."
  )
}

print(table(samples$label))

# -----------------------------------------------------------------------------
# Train
# -----------------------------------------------------------------------------
if (!file.exists(model_file)) {
  log_msg("Training ", model_version)
  model <- sits_train(samples = samples, ml_method = ml_method)
  saveRDS(model, model_file)
  log_msg("Saved model: ", model_file)
} else {
  log_msg("Model already exists, skipping training: ", model_file)
}

# -----------------------------------------------------------------------------
# K-fold cross-validation
# Each fold trains a separate TempCNN/torch model in
# parallel, so lower `multicores` if RAM gets tight.
# -----------------------------------------------------------------------------
# Off for the first v15a run: the 2018 map is needed first; run it later.
run_kfold <- FALSE
if (run_kfold && !file.exists(acc_model_file)) {
  log_msg("Cross-validation (k-fold)")
  folds <- 5L
  multicores <- 5L
  acc_model <- sits_kfold_validate(
    samples,
    folds      = folds,
    ml_method  = ml_method,
    multicores = multicores,
    progress   = TRUE
  )
  saveRDS(acc_model, acc_model_file)
  log_msg("Saved accuracy object: ", acc_model_file)
} else {
  log_msg("Accuracy object already exists, skipping k-fold: ", acc_model_file)
}

log_msg("Done.")
