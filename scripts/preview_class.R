# preview_class.R -- small PNG previews of sits class tiles with sits plot,
# colored by a QML palette, for a quick look on a phone.
#
# Every PNG has the same size (WIDTH x HEIGHT), whatever the tile size.
# Pixel values are taken as the QML `value`; sits writes class codes in the
# order of sits_labels(model), and the QML must follow that order.
#
# Usage: Rscript scripts/preview_class.R QML VERSION DATA_DIR OUT_DIR
# Plots every class tile of VERSION found in DATA_DIR.
suppressPackageStartupMessages(library(sits))

WIDTH <- 940L
HEIGHT <- 720L
DPI <- 110L

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4) stop("usage: preview_class.R QML VERSION DATA_DIR OUT_DIR")
qml <- args[[1]]
version <- args[[2]]
data_dir <- args[[3]]
out_dir <- args[[4]]
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

read_qml <- function(path) {
  x <- readLines(path, warn = FALSE)
  x <- regmatches(x, regexpr("<paletteEntry[^>]*>", x))
  attr <- function(name) sub(paste0('.*', name, '="([^"]*)".*'), "\\1", x)
  data.frame(value = as.integer(attr("value")), label = attr("label"), color = attr("color"))
}
pal <- read_qml(qml)
stopifnot(nrow(pal) > 0, !anyNA(pal$value))

cube <- sits_cube(
  source     = "BDC",
  collection = "LANDSAT-OLI-16D",
  data_dir   = data_dir,
  bands      = "class",
  labels     = setNames(pal$label, pal$value),
  version    = version,
  progress   = FALSE
)

for (tile in cube[["tile"]]) {
  t0 <- Sys.time()
  p <- plot(cube, tile = tile, legend = setNames(pal$color, pal$label),
            max_cog_size = HEIGHT, legend_position = "outside") +
    tmap::tm_title(paste(tile, version))
  png_file <- file.path(out_dir, paste0(tile, "_class_", version, ".png"))
  tmap::tmap_save(p, png_file, width = WIDTH, height = HEIGHT, units = "px", dpi = DPI)
  message(sprintf("%s: %.1f s", basename(png_file),
                  as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}
