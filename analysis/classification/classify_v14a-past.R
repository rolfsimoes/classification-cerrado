set.seed(777)

library(glue)
library(sits)

print(packageDescription("sits"))

source(normalizePath("~/r+/lulcbr-publish.R"))
setwd("~/classification-cerrado/")
#
# Versions (single source of truth -- drives the model file, the wait loop,
# and the classification output version)
#
publication_version <- "v14a" # <- was "v13a"
model_version <- glue("tempcnn-cer-{publication_version}")
raster_version <- "raster"
classification_version <- glue("{model_version}-{raster_version}")

#
# Wait for the training script to finish writing the model, then load it.
# A failed read (e.g. caught mid-write) is treated as "not ready" and retried.
#
model_file <- file.path(
  "~/classification-cerrado", "data", "derived", "models",
  glue("model-{model_version}.rds")
)

while (TRUE) {
  loaded <- tryCatch(
    {
      model <- suppressWarnings(readRDS(model_file))
      TRUE
    },
    error = function(e) {
      message(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] Model not ready, waiting 60s..."))
      Sys.sleep(60)
      FALSE
    }
  )
  if (isTRUE(loaded)) break
}
message(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] Model loaded: "), model_file)

message("=== Injecting Model Observability & Improvement ===========")

turbo_tempcnn_model <- function(ml_model, log_file = NULL) {
  message("  - ", getwd(), log_file)
  ml_model2 <- ml_model
  env <- environment(ml_model2)
  assign(".turbo_log_file", log_file, envir = env)
  body(ml_model2) <- quote({
    # Verifies if torch package is installed
    .check_require_packages("torch")
    t0 <- proc.time()[["elapsed"]]
    # Unserialize model
    torch_model$model <- .torch_unserialize_model(
      model = torch_model$model,
      raw = serialized_model
    )
    t1 <- proc.time()[["elapsed"]]
    if (.torch_use_dataloader(values)) {
      # Dataloader (GPU) path: normalization + array conversion now
      # happen inside the torch dataset ($.getbatch) and prediction
      # inside .torch_predict_chunks(), so those stages are no longer
      # observable from this closure.
      n_samples <- NA_integer_
      n_times <- NA_integer_
      n_bands <- NA_integer_
      batch_size <- sits_env[["batch_size"]]
      t2 <- proc.time()[["elapsed"]]
      # Predict!
      values <- .torch_predict_chunks(
        torch_model = torch_model,
        dataset = values[["dataset"]],
        callback = values[["callback"]]
      )
      t3 <- proc.time()[["elapsed"]]
      # Prepare results
      values <- unlist(values)
      t4 <- proc.time()[["elapsed"]]
    } else {
      # CPU path
      n_samples <- nrow(values)
      n_times <- .samples_ntimes(samples)
      n_bands <- length(bands)
      batch_size <- NA_integer_
      # Performs data normalization
      values <- .pred_features_normalize(values, stats = ml_stats)
      t2 <- proc.time()[["elapsed"]]
      # Represent matrix values as array
      C_as_array_inplace(values, c(n_samples, n_times, n_bands))
      # CPU classification
      values <- stats::predict(
        object = torch_model,
        newdata = values,
        accelerator = luz::accelerator(cpu = TRUE)
      )
      t3 <- proc.time()[["elapsed"]]
      # Convert from tensor to array
      values <- torch::as_array(values)
      # Update the columns names to labels
      colnames(values) <- sample_labels
      t4 <- proc.time()[["elapsed"]]
    }
    if (!is.null(.turbo_log_file)) {
      cat(
        paste(
          Sys.time(),
          Sys.getpid(),
          .torch_use_dataloader(values),
          n_samples,
          n_times,
          n_bands,
          batch_size,
          round(t1 - t0, 6), # unserialize
          round(t2 - t1, 6), # normalize (CPU) / setup (GPU)
          round(t3 - t2, 6), # predict
          round(t4 - t3, 6), # post-process
          round(t4 - t0, 6), # total
          sep = "\t"
        ),
        "\n",
        file = .turbo_log_file,
        append = TRUE
      )
    }
    # Return!
    values
  })
  environment(ml_model2) <- env
  class(ml_model2) <- class(ml_model)
  ml_model2
}
model <- turbo_tempcnn_model(
  model,
  log_file = "tempcnn-new-predict-internal.tsv"
)

#
# Tiles of Cerrado
#
cerrado_tiles <- c(
  "015009"
  # "007009", "008009", "008010", "009009", "009010", "009011", "009013", "009014",
  # "010009", "010010", "010011", "010012", "010013", "010014", "010015", "011009",
  # "011010", "011011", "011012", "011013", "011014", "011015", "012008", "012009",
  # "012010", "012011", "012012", "012013", "012014", "012015", "013006", "013007",
  # "013008", "013009", "013010", "013011", "013012", "013013", "013014", "013015",
  # "014005", "014006", "014007", "014008", "014009", "014010", "014011", "014012",
  # "014013", "014014", "014015", "015005", "015006", "015007", "015008", "015009",
  # "015010", "015011", "015012", "015013", "015014", "016004", "016005", "016006",
  # "016007", "016008", "016009", "016010", "016011", "016012", "016013", "017004",
  # "017005", "017006", "017007", "017010", "017011", "017012"
)

#
# Setup directory
# NOTE: base_dir is RELATIVE, so run this with working directory = ~/classification-cerrado
#
base_dir <- file.path("data", "derived")
cubes_dir <- file.path(base_dir, "cubes", "past")
classifications_dir <- file.path(base_dir, "classifications")

dir.create(classifications_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(classifications_dir))

#
# Setup years
#
years <- c(2001:2015) # ou 2015:2022
start_year_offset <- 1L # 1L para classificação com 2 anos (consistente com v14a); 0L para 1 ano

#
# Hardware
#
Sys.setenv(SITS_FORCE_CPU = TRUE)
multicores <- 48L
memsize <- 128
gpu_memory <- 94
batch_size <- gpu_memory * 1000

#
# Setup parallel cluster
#
sits_parallel(workers = multicores, log = TRUE, output_dir = getwd())

#
# Define processing chunks
#
chunk_size <- 7L
tiles <- split(cerrado_tiles, ceiling(seq_along(cerrado_tiles) / chunk_size))

#
# Year loop
#
for (year in years) {
  # Input cube dir for this year
  start_year <- year - start_year_offset
  end_year <- year

  # Output classification dir for this year/version
  output_dir <- file.path(classifications_dir, classification_version, as.character(end_year))

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  stopifnot(dir.exists(output_dir))

  # Chunk-of-tiles: sits will resume using output_dir
  for (tile_chunk in tiles) {
    message("Year ", end_year, " | tile(s) ", paste(tile_chunk, collapse = ", "))

    message("- loading cube")
    cube_2y <- sits_cube(
      source     = "BDC",
      collection = "LANDSAT-C2-L2",
      tiles      = tile_chunk,
      start_date = paste0(start_year, "-01-01"),
      end_date   = paste0(end_year, "-12-31"),
      data_dir   = cubes_dir,
      progress   = TRUE
    )

    message("- classifying (probabilities)")
    probs <- tryCatch(sits_classify(
      data       = cube_2y,
      ml_model   = model,
      multicores = multicores,
      memsize    = memsize,
      gpu_memory = gpu_memory,
      batch_size = batch_size,
      output_dir = output_dir,
      progress   = TRUE,
      verbose    = TRUE,
      version    = classification_version
    ), error = function(e) {
      message("error when classifying tile(s)")
      message(conditionMessage(e))
      NULL
    })

    if (is.null(probs)) {
      next
    }

    message("- smoothing")
    bayes <- sits_smooth(
      cube       = probs,
      multicores = multicores,
      memsize    = memsize,
      output_dir = output_dir,
      progress   = TRUE,
      version    = classification_version
    )

    # message("- uncertainty")
    # class <- sits_uncertainty(
    #   cube       = bayes,
    #   type       = "margin",
    #   multicores = 32L,
    #   memsize    = 64,
    #   output_dir = output_dir,
    #   version    = classification_version,
    #   progress   = TRUE
    # )

    message("- labeling")
    class <- sits_label_classification(
      cube       = bayes,
      multicores = multicores,
      memsize    = memsize,
      output_dir = output_dir,
      progress   = TRUE,
      version    = classification_version
    )
  }

  # #
  # # Prepare mosaic
  # #
  # mosaic_dir <- file.path(output_dir, "mosaic")
  # crs_bdc <- paste0(readLines("~/r+/bdc.prj"), collapse = "\n")
  #
  # dir.create(mosaic_dir, recursive = TRUE, showWarnings = FALSE)
  # stopifnot(dir.exists(mosaic_dir))
  # stopifnot(exists("class"))
  #
  # labels <- sits_labels(model)
  # names(labels) <- seq_along(labels)
  #
  # class_cube <- sits_cube(
  #   source     = "BDC",
  #   collection = "LANDSAT-OLI-16D",
  #   data_dir   = output_dir,
  #   tiles      = cerrado_tiles,
  #   bands      = "class",
  #   labels     = labels,
  #   version    = classification_version,
  #   multicores = multicores,
  #   progress   = FALSE
  # )
  #
  # message("- mosaicking classification")
  # mosaic_class <- sits_mosaic(
  #   cube       = class_cube,
  #   crs        = crs_bdc,
  #   multicores = multicores,
  #   output_dir = mosaic_dir,
  #   version    = classification_version
  # )

  # uncert_cube <- sits_cube(
  #   source     = "BDC",
  #   collection = "LANDSAT-OLI-16D",
  #   data_dir   = output_dir,
  #   tiles      = cerrado_tiles,
  #   bands      = "margin",
  #   labels     = labels,
  #   version    = classification_version,
  #   progress   = FALSE
  # )

  # message("- mosaicking uncertainty")
  # mosaic_uncert <- sits_mosaic(
  #   cube       = uncert_cube,
  #   crs        = crs_bdc,
  #   multicores = multicores,
  #   output_dir = mosaic_dir,
  #   version    = classification_version
  # )

  # #
  # # Publish
  # #
  # message("- publish")
  # publish_cer(
  #     start_year = start_year,
  #     end_year = end_year,
  #     publication_version = publication_version,
  #     model_version = model_version,
  #     raster_version = raster_version,
  #     workdir = "~/r+",
  #     base_dir = "~/classification-cerrado/data/derived",
  #     template_file = "natveg/cer/v2/natveg_30m_cer_2000-01-01_2000-12-31_class_v2.tif",
  #     qml_template = "lulcbrasil/cer/v12a/lulcbrasil_30m_cer_2017-01-01_2018-12-31_class_v12a.qml",
  #     upload = TRUE,
  #     overwrite = TRUE
  # )
}

#
# Warnings
#
message("- warnings")
print(warnings())
