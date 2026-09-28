set.seed(777)

library(glue)
library(sits)

# Cubes are flat dirs of thousands of files on BeeGFS; without this, each
# GDAL open lists the dir and reads run 6x slower (2026-09-27).
if (!nzchar(Sys.getenv("GDAL_DISABLE_READDIR_ON_OPEN"))) {
  Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR")
}

#
# Tiles of Cerrado
#
cerrado_tiles <- c(
  "007009", "008009", "008010", "009009", "009010", "009011", "009013", "009014",
  "010009", "010010", "010011", "010012", "010013", "010014", "010015", "011009",
  "011010", "011011", "011012", "011013", "011014", "011015", "012008", "012009",
  "012010", "012011", "012012", "012013", "012014", "012015", "013006", "013007",
  "013008", "013009", "013010", "013011", "013012", "013013", "013014", "013015",
  "014005", "014006", "014007", "014008", "014009", "014010", "014011", "014012",
  "014013", "014014", "014015", "015005", "015006", "015007", "015008", "015009",
  "015010", "015011", "015012", "015013", "015014", "016004", "016005", "016006",
  "016007", "016008", "016009", "016010", "016011", "016012", "016013", "017004",
  "017005", "017006", "017007", "017010", "017011", "017012"
)

#
# Setup directory
#
base_dir <- file.path("~/classification-cerrado", "data", "derived")
cubes_dir <- file.path(base_dir, "cubes")
models_dir <- file.path(base_dir, "models")
classifications_dir <- file.path(base_dir, "classifications")

dir.create(classifications_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(classifications_dir))

#
# Setup versions
#
publication_version <- "v15a"
model_version <- glue("tempcnn-cer-{publication_version}")
raster_version <- "raster"
classification_version <- glue("{model_version}-{raster_version}")

#
# Setup years
#
years <- c(2018) # v15a: 2018 first, for the group review
start_year_offset <- 1L # 1L for a 2-year classification; 0L for 1 year

#
# Hardware
#
# Readers are the torch dataloader workers (num_workers, from multicores in
# .torch_predict_chunks); each prefetches 2 blocks, and the main process holds
# the block in the GPU, so 2 x workers + 1 blocks share memsize.
gpu_workers <- 8L
blocks_in_ram <- 2L * gpu_workers + 1L
# Smoothing and labeling run on CPU.
cpu_workers <- 64L
memsize <- 250 # GB of RAM, cgroup limit is 316
gpu_memory <- 90 # GB for batches; the H100 NVL has 94, the rest holds the model and CUDA context
# TempCNN inference memory per pixel is not known exactly; 64 KB is a
# conservative estimate. sits splits a batch that does not fit and warns.
gpu_bytes_per_pixel <- 64 * 1024

# No persistent sits_parallel cluster: it would ignore the worker counts above.

#
# Telemetry, all to the screen (the run is piped to tee).
#
say <- function(...) message(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " | ", ...)
gpu_state <- function() {
  out <- tryCatch(system2("nvidia-smi", c("--query-gpu=memory.used,memory.total,utilization.gpu",
                                          "--format=csv,noheader"), stdout = TRUE),
                  error = function(e) "nvidia-smi unavailable")
  paste(out, collapse = "; ")
}
ram_state <- function() {
  g <- gc(verbose = FALSE)
  sprintf("R session %.1f GB used (max %.1f GB)", sum(g[, 2]) / 1024, sum(g[, 6]) / 1024)
}
cgroup_mem <- function() {
  f <- "/sys/fs/cgroup/memory.current"
  if (file.exists(f)) sprintf("cgroup memory %.1f GB", as.numeric(readLines(f)) / 1e9) else "cgroup memory n/a"
}
say("sits ", as.character(packageVersion("sits")), ", torch cuda available: ",
    tryCatch(torch::cuda_is_available(), error = function(e) NA))
say("versions: ", classification_version, "; years: ", paste(years, collapse = " "))
say("hardware: gpu_workers ", gpu_workers, ", cpu_workers ", cpu_workers, ", memsize ", memsize,
    " GB, gpu_memory ", gpu_memory, " GB, gpu_bytes_per_pixel ", gpu_bytes_per_pixel,
    ", processing_bloat_gpu ", sits:::.conf("processing_bloat_gpu"))
say("GDAL_DISABLE_READDIR_ON_OPEN=", Sys.getenv("GDAL_DISABLE_READDIR_ON_OPEN"))
say("GPU: ", gpu_state())

#
# Define processing chunks
#
chunk_size <- 7L
tiles <- split(cerrado_tiles, ceiling(seq_along(cerrado_tiles) / chunk_size))

#
# Load model
#
model_file <- file.path(models_dir, glue("model-{model_version}.rds"))
stopifnot(file.exists(model_file))
model <- readRDS(model_file)
say("model: ", model_file)

#
# Block and batch plan. Blocks are full-width stripes of the tile, as tall as
# one reader's share of memsize allows, in whole file blocks. Each block goes
# to the GPU in n equal batches, each under gpu_memory.
#
plan_blocks <- function(cube, model) {
  file_block <- sits:::.raster_file_blocksize(sits:::.raster_open_rast(sits:::.tile_path(cube)))
  size <- sits:::.tile_size(sits:::.tile(cube))
  npaths <- length(sits:::.tile_paths(cube, sits:::.ml_bands(model))) +
    length(sits:::.ml_labels(model))
  # RAM per pixel of a block, as sits estimates it for GPU classification.
  ram_per_px <- npaths * 8 * sits:::.conf("processing_bloat_gpu")
  rows <- floor((memsize / blocks_in_ram) * 1e9 / (size[["ncols"]] * ram_per_px))
  rows <- min(rows, size[["nrows"]])
  rows <- max(file_block[["nrows"]], floor(rows / file_block[["nrows"]]) * file_block[["nrows"]])
  block_px <- rows * size[["ncols"]]
  max_batch <- floor(gpu_memory * 1e9 / gpu_bytes_per_pixel)
  n <- ceiling(block_px / max_batch)
  batch <- as.integer(ceiling(block_px / n))
  say("plan: tile ", size[["nrows"]], " x ", size[["ncols"]],
      ", file block ", file_block[["nrows"]], " x ", file_block[["ncols"]],
      ", npaths ", npaths, ", RAM per px ", ram_per_px, " B")
  say("plan: block ", rows, " x ", size[["ncols"]], " = ", block_px, " px, ",
      ceiling(size[["nrows"]] / rows), " per tile, ",
      sprintf("%.1f GB RAM per block, %.1f GB for %d blocks in RAM",
              block_px * ram_per_px / 1e9, block_px * ram_per_px * blocks_in_ram / 1e9, blocks_in_ram))
  say("plan: max batch ", max_batch, " px, ", n, " batch(es) of ", batch, " px, ",
      sprintf("%.1f GB GPU per batch (estimate)", batch * gpu_bytes_per_pixel / 1e9))
  list(block_size = c(nrows = as.integer(rows), ncols = as.integer(size[["ncols"]])),
       batch_size = batch)
}

#
# Year loop
#
for (year in years) {
  # Input cube dir for this year
  start_year <- year - start_year_offset
  end_year <- year

  cube_dir_y1 <- file.path(cubes_dir, as.character(start_year))
  cube_dir_y2 <- file.path(cubes_dir, as.character(end_year))

  # Output classification dir for this year/version
  output_dir <- file.path(classifications_dir, classification_version, as.character(end_year))

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  stopifnot(dir.exists(output_dir))

  # Chunk-of-tiles: sits will resume using output_dir
  for (tile_chunk in tiles) {
    say("year ", end_year, " (", start_year, "-", end_year, ") | tiles ",
        paste(tile_chunk, collapse = ", "))
    say("loading cube")
    cube_y1 <- sits_cube(
      source     = "BDC",
      collection = "LANDSAT-OLI-16D",
      tiles      = tile_chunk,
      data_dir   = cube_dir_y1,
      multicores = cpu_workers,
      progress   = FALSE
    )

    if (start_year == end_year) {
      cube_2y <- cube_y1
    } else {
      cube_y2 <- sits_cube(
        source     = "BDC",
        collection = "LANDSAT-OLI-16D",
        tiles      = tile_chunk,
        data_dir   = cube_dir_y2,
        multicores = cpu_workers,
        progress   = FALSE
      )
      cube_2y <- sits_merge(cube_y1, cube_y2)
    }

    say("cube loaded: ", nrow(cube_2y), " tiles, ", length(sits_timeline(cube_2y)), " dates, bands ",
        paste(sits_bands(cube_2y), collapse = " "))
    plan <- plan_blocks(cube_2y, model)

    say("classifying (probabilities); GPU: ", gpu_state())
    probs <- tryCatch(sits_classify(
      data       = cube_2y,
      ml_model   = model,
      multicores = gpu_workers,
      memsize    = memsize,
      gpu_memory = gpu_memory,
      batch_size = plan[["batch_size"]],
      block_size = plan[["block_size"]],
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

    say("classified; GPU: ", gpu_state())
    say("smoothing")
    bayes <- sits_smooth(
      cube       = probs,
      multicores = cpu_workers,
      memsize    = memsize,
      output_dir = output_dir,
      progress   = TRUE,
      version    = classification_version
    )

    say("labeling")
    class <- sits_label_classification(
      cube       = bayes,
      multicores = cpu_workers,
      memsize    = memsize,
      output_dir = output_dir,
      progress   = TRUE,
      version    = classification_version
    )
    rm(cube_y1, probs, bayes)
    if (exists("cube_y2")) rm(cube_y2)
    invisible(gc())
    say("tiles done; ", ram_state(), "; ", cgroup_mem(), "; GPU: ", gpu_state())
  }

  #
  # Prepare mosaic
  #
  mosaic_dir <- file.path(output_dir, "mosaic")
  crs_bdc <- paste0(readLines("~/r+/bdc.prj"), collapse = "\n")

  dir.create(mosaic_dir, recursive = TRUE, showWarnings = FALSE)
  stopifnot(dir.exists(mosaic_dir))
  stopifnot(exists("class"))

  labels <- sits_labels(class)

  class_cube <- sits_cube(
    source     = "BDC",
    collection = "LANDSAT-OLI-16D",
    data_dir   = output_dir,
    tiles      = cerrado_tiles,
    bands      = "class",
    labels     = labels,
    version    = classification_version,
    progress   = FALSE
  )

  say("mosaicking classification")
  mosaic_class <- sits_mosaic(
    cube       = class_cube,
    crs        = crs_bdc,
    multicores = cpu_workers,
    output_dir = mosaic_dir,
    version    = classification_version
  )

  # Publication is manual, after the map is reviewed.
}

#
# Warnings
#
say("done")
say("warnings:")
print(warnings())
