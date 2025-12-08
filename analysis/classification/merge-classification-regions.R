set.seed(777)

library(sits)
library(restoreutils)

#
# General definitions
#
base_cubes_dir <- restoreutils::project_cubes_dir()
base_classifications_dir <- restoreutils::project_classifications_dir()

# Model
model_version <- "samples-simoes-natveg"

# Merge - version
classification_version <- "samples-simoes-natveg"

# Merge - years
classification_years <- 2018

#
# 1. Create roi
#
roi <- fs::file_temp(ext = ".gpkg")

sf::st_read(system.file("extdata/cerrado/cerrado-regions-bdc-md.gpkg", package = "restoreutils"))  |>
  sf::st_union() |>
  sf::st_make_valid() |>
  sf::st_write(roi)

#
# 2. Merge classification maps
#
for (classification_year in classification_years) {
  # Define output directories
  classification_dir <- restoreutils::create_data_dir(
    base_classifications_dir / classification_version, classification_year
  )
  # Classifications to merge
  classification_files <- fs::dir_ls(
    path = classification_dir,
    regexp = glue::glue(".*_MOSAIC_.*{model_version}-q\\d.tif$")
  )
  # Define output file
  out_mosaic <- stringr::str_replace(
    string = fs::path_file(classification_files[[1]]),
    pattern = "-q\\d",
    replacement = ""
  )
  out_mosaic <- classification_dir / out_mosaic

  # Create temporary vrt
  temp_vrt <- fs::file_temp(ext = ".vrt")
  sf::gdal_utils(
    util = "buildvrt", source = classification_files, destination = temp_vrt
  )
  # Mosaic files
  sf::gdal_utils(
    util = "warp",
    source = temp_vrt,
    destination = out_mosaic,
    options = c(
      "-ot", "Byte",
      "-of", "GTiff",
      "-cutline", roi,
      "-crop_to_cutline",
      "-co", "BIGTIFF=YES",
      "-co", "TILED=YES",
      "-co", "COMPRESS=ZSTD",
      "-co", "PREDICTOR=1",
      "-co", "NUM_THREADS=ALL_CPUS"
    ),
    config_options = c(
      "GDAL_CACHEMAX" = "4096",
      "GDAL_TIFF_INTERNAL_MASK" = "YES"
    ),
    quiet = FALSE
  )
  # Build overviews
  sf::gdal_addo(out_mosaic)
}
