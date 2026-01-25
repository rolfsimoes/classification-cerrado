set.seed(777)

library(sits)
library(restoreutils)

#
# General definitions
#
region_id <- 1

processing_context <- paste0("cerrado:", region_id)

# Local directories
base_cubes_dir <- restoreutils::project_cubes_dir()
base_mosaic_dir <- restoreutils::project_mosaics_dir()

# Bands
bands <- c("SWIR16", "NIR08", "BLUE")

# Processing years
regularization_years <- c(2015:2017, 2019:2022)

# Hardware - Multicores
multicores <- 40


#
# 1. Load eco region 2 shape
#
eco_region_roi <- restoreutils::roi_cerrado_regions(
  region_id = region_id,
  as_file = TRUE
)


#
# 2. Generate mosaics
#
restoreutils::notify(processing_context, "generate mosaics > initialized")

for (regularization_year in regularization_years) {
  print(regularization_year)

  # Define local directories
  cube_dir <- restoreutils::create_data_dir(base_cubes_dir, regularization_year)
  mosaic_dir <- restoreutils::create_data_dir(base_mosaic_dir, regularization_year)

  # Create output dir
  fs::dir_create(mosaic_dir, recurse = TRUE)

  # Load cube
  cube <- sits_cube(
    source     = "BDC",
    collection = "LANDSAT-OLI-16D",
    bands      = bands,
    data_dir   = cube_dir
  )

  # Transform cube to tiles
  tryCatch({
    restoreutils::notify(processing_context,
                         paste("generate mosaics > processing", regularization_year))

    tiles <- restoreutils::cube_to_rgb_mosaic_bdc(
      cube       = cube,
      output_dir = mosaic_dir,
      roi_file   = eco_region_roi,
      bands      = bands,
      multicores = multicores
    )
  }, error = function(e) {
    restoreutils::notify(processing_context,
                         "generate mosaics > error to generate tiles!")
  })
}
