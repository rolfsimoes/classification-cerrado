library(sits)
library(restoreutils)

#
# General definitions
#
region_id <- 3

# Base datacube directories
base_cubes_dir <- restoreutils::project_cubes_dir()

# Samples
samples_file <- "data/raw/timeseries/lulcbrasil_ts_cer_2018-01-01_2018-12-01_ts_v3a.rds"

# Output dir
base_output_dir <- "data/derived/"

# Samples version
samples_version <- glue::glue("samples-cer-v3a-q{region_id}")

# Reference year
samples_reference_year <- 2018

# Hardware - multicores
multicores <- 40


#
# 1. Create output directories
#
samples_dir <- restoreutils::create_data_dir(base_output_dir, "timeseries")


#
# 2. Load existing samples
#
samples_raw <- readRDS(samples_file)


#
# 3. Load data cube
#
cube_dir <- base_cubes_dir / samples_reference_year

cube <- sits_cube(
    source     = "BDC",
    collection = "LANDSAT-OLI-16D",
    data_dir   = cube_dir
)

cube_timeline <- sits_timeline(cube)


#
# 4. Update samples
#
samples_raw[["cube"]] <- NULL
samples_raw[["start_date"]] <- min(cube_timeline)
samples_raw[["end_date"]] <- max(cube_timeline)


#
# 5. Extract time-series
#
samples_ts <- sits_get_data(
  cube = cube,
  samples = samples_raw,
  multicores = multicores
)


#
# 6. Save samples
#
saveRDS(samples_ts, samples_dir / paste0(samples_version, ".rds"))
