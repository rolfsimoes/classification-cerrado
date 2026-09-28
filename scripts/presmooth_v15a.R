# presmooth_v15a.R -- smooth (C++) and label the probs tiles of the current
# chunk while classify_v15a.R classifies the next tile on the GPU.
#
# classify_v15a.R smooths with torch on 1 process (8 min per tile, measured
# 2026-09-28); the C++ smoother uses CPU workers. sits_smooth and
# sits_label_classification skip a tile whose output file is valid, so the
# main run skips the tiles done here.
#
# A tile is taken when its probs file is complete (its "Tile 'X' finished"
# line is in the log) and the last tile of the chunk has not finished: after
# it, the main run smooths the chunk, and both would write the same file.
# Processes the eligible tiles once and exits.
#
# Usage: Rscript scripts/presmooth_v15a.R QML [MAX_TILES]
# V15A_LOG, V15A_OUT and V15A_WORK override the paths, for tests only.
suppressPackageStartupMessages(library(sits))

if (!nzchar(Sys.getenv("GDAL_DISABLE_READDIR_ON_OPEN"))) {
  Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR")
}
Sys.setenv(SITS_SMOOTH_FORCE_CPP = "TRUE")

args <- commandArgs(trailingOnly = TRUE)
if (!length(args) %in% 1:2) stop("usage: presmooth_v15a.R QML [MAX_TILES]")
qml <- args[[1]]
max_tiles <- if (length(args) == 2) as.integer(args[[2]]) else Inf

version <- "tempcnn-cer-v15a-raster"
output_dir <- Sys.getenv("V15A_OUT", path.expand(file.path(
  "~/classification-cerrado/data/derived/classifications", version, "2018")))
log_file <- Sys.getenv("V15A_LOG", path.expand("~/restore-plus-cerrado/run_v15a_samples/logs/classify_v15a.log"))
work_dir <- Sys.getenv("V15A_WORK", path.expand("~/classification-cerrado/scripts/run/presmooth"))
# CPU workers; the 8 GPU readers of the main run keep the rest.
cpu_workers <- 32L
memsize <- 60 # GB; the main run uses up to about 110

say <- function(...) message(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " | presmooth | ", ...)

# Log lines of the current run only.
log <- readLines(log_file, warn = FALSE)
log <- unlist(strsplit(log, "\r", fixed = TRUE))
from <- max(c(1L, grep("start_classify:", log)))
log <- log[from:length(log)]

chunk_line <- tail(grep("\\| tiles [0-9]", log, value = TRUE), 1)
if (length(chunk_line) == 0) quit(save = "no")
chunk <- strsplit(sub(".*\\| tiles ", "", chunk_line), ", ")[[1]]
finished <- sub("^Tile '([0-9]+)' finished.*", "\\1", grep("^Tile '[0-9]+' finished", log, value = TRUE))

tile_file <- function(tile, band) {
  file.path(output_dir, sprintf("LANDSAT_OLI_%s_2017-01-01_2018-12-01_%s_%s.tif", tile, band, version))
}
if (tail(chunk, 1) %in% finished) quit(save = "no")
todo <- Filter(function(t) {
  t %in% finished &&
    file.exists(tile_file(t, "probs")) && !file.exists(tile_file(t, "class"))
}, chunk)
todo <- head(todo, max_tiles)
if (length(todo) == 0) quit(save = "no")

read_qml <- function(path) {
  x <- readLines(path, warn = FALSE)
  x <- regmatches(x, regexpr("<paletteEntry[^>]*>", x))
  attr <- function(name) sub(paste0('.*', name, '="([^"]*)".*'), "\\1", x)
  data.frame(value = as.integer(attr("value")), label = attr("label"))
}
pal <- read_qml(qml)
labels <- setNames(pal$label, pal$value)

for (tile in todo) {
  t0 <- Sys.time()
  # sits_cube on output_dir would also parse the block files of the main
  # run; a link in a separate dir holds only this tile.
  in_dir <- file.path(work_dir, tile)
  unlink(in_dir, recursive = TRUE)
  dir.create(in_dir, recursive = TRUE)
  file.symlink(tile_file(tile, "probs"), in_dir)
  probs <- sits_cube(source = "BDC", collection = "LANDSAT-OLI-16D", data_dir = in_dir,
                     bands = "probs", labels = labels, version = version, progress = FALSE)
  say(tile, ": smoothing (C++, ", cpu_workers, " workers)")
  bayes <- sits_smooth(probs, multicores = cpu_workers, memsize = memsize,
                       output_dir = output_dir, progress = FALSE, version = version)
  t1 <- Sys.time()
  say(tile, ": labeling")
  sits_label_classification(bayes, multicores = cpu_workers, memsize = memsize,
                            output_dir = output_dir, progress = FALSE, version = version)
  say(tile, sprintf(": done, smoothing %.1f min, labeling %.1f min",
                    as.numeric(difftime(t1, t0, units = "mins")),
                    as.numeric(difftime(Sys.time(), t1, units = "mins"))))
}
