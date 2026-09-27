set.seed(777)

library(glue)
library(sits)

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
  "017005", "017006", "017007", "017010", "017011"
)

#
# Setup directory
#
base_dir <- file.path("~/classification-cerrado", "data", "derived")
cubes_dir <- file.path(base_dir, "cubes")
samples_dir <- file.path(base_dir, "timeseries")

# Setup versions
samples_version <- "cer-v15a"
samples_file <- file.path(samples_dir, glue("samples-{samples_version}.rds"))
pasture_file <- file.path(samples_dir, glue("samples-pasture-{samples_version}.rds"))

# New Pasture points, drawn by restore-plus-cerrado scripts/run_samples_v15a.sh
# (plan/SAMPLES-v15a.md in that repository).
pasture_csv <- "~/restore-plus-cerrado/run_v15a_samples/samples/samples_v15a_pasture.csv"

# Strata that enter v15a; drop one here if its visual inspection fails.
strata_keep <- c("interior", "border", "transition")

years <- c(2018, 2020, 2022, 2024)
bands <- c("BLUE", "EVI", "GREEN", "MNDWI", "NBR", "NDVI", "NIR08", "RED", "SWIR16", "SWIR22")

# Setup parallel cluster
# Cubes are on BeeGFS: with 100 workers, 88 of 101 R processes waited on I/O.
# V15A_MULTICORES overrides it; 16 left the disk with spare capacity.
multicores <- as.integer(Sys.getenv("V15A_MULTICORES", "16"))
# sits writes a debug log per call; keep it on local disk, not on BeeGFS.
log_dir <- Sys.getenv("V15A_LOG_DIR", "/tmp/sits_v15a")
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
sits_parallel(workers = multicores, log = TRUE, output_dir = log_dir)

points <- read.csv(pasture_csv)

#
# Extract time series, one period at a time
#
for (year in years) {
  year_file <- file.path(samples_dir, glue("samples-pasture-{samples_version}-{year}.rds"))
  # Checkpoint: an extracted period is not extracted again.
  if (file.exists(year_file)) {
    message("- ", year, ": keep ", year_file)
    next
  }

  message(format(Sys.time(), "%H:%M:%S"), " - ", year, ": loading cube")
  cube_y1 <- sits_cube(
    source     = "BDC",
    collection = "LANDSAT-OLI-16D",
    tiles      = cerrado_tiles,
    data_dir   = file.path(cubes_dir, as.character(year - 1)),
    # sits reads the file metadata with 2 workers unless told otherwise.
    multicores = multicores,
    progress   = FALSE
  )
  cube_y2 <- sits_cube(
    source     = "BDC",
    collection = "LANDSAT-OLI-16D",
    tiles      = cerrado_tiles,
    data_dir   = file.path(cubes_dir, as.character(year)),
    multicores = multicores,
    progress   = FALSE
  )
  cube_2y <- sits_merge(cube_y1, cube_y2)
  message(format(Sys.time(), "%H:%M:%S"), " - ", year, ": cube loaded")

  # v14a series have 24 monthly steps, January y-1 to December y.
  timeline <- sits_timeline(cube_2y)
  stopifnot(length(timeline) == 24, all(bands %in% sits_bands(cube_2y)))

  message("- ", year, ": extract ts")
  year_ts <- list()
  for (stratum in c("interior", "border", "transition")) {
    s <- tibble::as_tibble(points[points$year == year & points$stratum == stratum, ])
    s <- s[, c("longitude", "latitude", "label")]
    s$start_date <- min(timeline)
    s$end_date <- max(timeline)
    ts <- sits_get_data(
      cube = cube_2y,
      samples = s,
      bands = bands,
      multicores = multicores
    )
    # Added after extraction, so the column is not lost inside sits_get_data.
    ts$stratum <- stratum
    message(format(Sys.time(), "%H:%M:%S"), "   ", stratum, ": ", nrow(s), " points, ", nrow(ts), " series")
    year_ts[[stratum]] <- ts
  }
  year_ts <- dplyr::bind_rows(year_ts)

  # Written under a temporary name: a killed run leaves no file the
  # checkpoint above would accept.
  saveRDS(year_ts, paste0(year_file, ".part"))
  file.rename(paste0(year_file, ".part"), year_file)
}

#
# Pasture samples of all periods, with their stratum
#
pasture <- dplyr::bind_rows(lapply(years, function(year) {
  readRDS(file.path(samples_dir, glue("samples-pasture-{samples_version}-{year}.rds")))
}))
saveRDS(pasture, pasture_file)

#
# v15a = v14a + new Pasture samples of the strata kept
#
v14a <- readRDS(file.path(samples_dir, "samples-cer-v14a.rds"))
new <- pasture[pasture$stratum %in% strata_keep, ]
new$stratum <- NULL
v15a <- dplyr::bind_rows(list(v14a, new))

message("- v14a ", nrow(v14a), " + pasture ", nrow(new), " = v15a ", nrow(v15a))
saveRDS(v15a, samples_file)

v15a$time_series <- NULL
class(v15a) <- class(v15a)[-1]
v15a_sf <- terra::vect(
  v15a,
  geom = c("longitude", "latitude"),
  crs = "EPSG:4326",
  keepgeom = TRUE
)

terra::writeVector(
  x = v15a_sf,
  filename = sub("\\.rds$", ".gpkg", samples_file),
  overwrite = TRUE
)
