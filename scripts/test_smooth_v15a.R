# test_smooth_v15a.R -- time sits_smooth with torch and with C++ on a crop of
# one finished probs tile, and compare the two results.
#
# The crop is copied to WORK_DIR; the classification output_dir is only read.
# sits uses torch when it is functional, and forces 1 worker when a GPU is
# present; SITS_SMOOTH_FORCE_CPP=TRUE selects the C++ smoother, which uses
# `multicores` workers.
#
# Usage: Rscript scripts/test_smooth_v15a.R PROBS.tif QML WORK_DIR [SIZE]
# SIZE is the crop side in pixels (default 2048), from the top left corner.
suppressPackageStartupMessages(library(sits))

if (!nzchar(Sys.getenv("GDAL_DISABLE_READDIR_ON_OPEN"))) {
  Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR")
}
cpu_workers <- 64L
memsize <- 60 # GB; the classification runs beside this test

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) stop("usage: test_smooth_v15a.R PROBS.tif QML WORK_DIR [SIZE]")
probs_tif <- args[[1]]
qml <- args[[2]]
work_dir <- args[[3]]
size <- if (length(args) >= 4) as.integer(args[[4]]) else 2048L

say <- function(...) message(format(Sys.time(), "%H:%M:%S"), " | ", ...)

# sits names results <sat>_<sensor>_<tile>_<start>_<end>_<band>_<version>.tif
version <- sub("\\.tif$", "", strsplit(basename(probs_tif), "_")[[1]][[7]])
stopifnot(grepl("_probs_", basename(probs_tif)))

read_qml <- function(path) {
  x <- readLines(path, warn = FALSE)
  x <- regmatches(x, regexpr("<paletteEntry[^>]*>", x))
  attr <- function(name) sub(paste0('.*', name, '="([^"]*)".*'), "\\1", x)
  data.frame(value = as.integer(attr("value")), label = attr("label"))
}
pal <- read_qml(qml)
labels <- setNames(pal$label, pal$value)

in_dir <- file.path(work_dir, "input")
unlink(work_dir, recursive = TRUE)
dir.create(in_dir, recursive = TRUE)
crop <- file.path(in_dir, basename(probs_tif))
sf::gdal_utils("translate", probs_tif, crop,
               options = c("-srcwin", "0", "0", size, size, "-co", "COMPRESS=LZW"))
say("crop ", size, " x ", size, " of ", basename(probs_tif))

probs <- sits_cube(
  source     = "BDC",
  collection = "LANDSAT-OLI-16D",
  data_dir   = in_dir,
  bands      = "probs",
  labels     = labels,
  version    = version,
  progress   = FALSE
)

smooth <- function(method) {
  Sys.setenv(SITS_SMOOTH_FORCE_CPP = if (method == "cpp") "TRUE" else "FALSE")
  out <- file.path(work_dir, method)
  dir.create(out)
  say(method, ": torch ", sits:::.torch_smooth_available(), ", gpu ", sits:::.torch_gpu_available())
  t <- system.time(bayes <- sits_smooth(probs, multicores = cpu_workers, memsize = memsize,
                                        output_dir = out, progress = FALSE, version = method))
  say(method, ": ", sprintf("%.1f s elapsed, %.1f s user", t[["elapsed"]], t[["user.self"]]))
  list(time = t[["elapsed"]], file = sits:::.tile_path(bayes))
}
res_torch <- smooth("torch")
res_cpp <- smooth("cpp")

a <- terra::rast(res_torch$file)
b <- terra::rast(res_cpp$file)
d <- abs(terra::values(a) - terra::values(b))
same_class <- mean(max.col(terra::values(a), ties.method = "first") ==
                   max.col(terra::values(b), ties.method = "first"), na.rm = TRUE)
say(sprintf("result: torch %.1f s, cpp %.1f s, cpp/torch %.2f", res_torch$time, res_cpp$time,
            res_cpp$time / res_torch$time))
say(sprintf("result: max |torch - cpp| %.4f (file units), same class in %.2f%% of pixels",
            max(d, na.rm = TRUE), 100 * same_class))
