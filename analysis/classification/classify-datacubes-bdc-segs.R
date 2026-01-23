set.seed(777)

library(sits)
library(restoreutils)

#
# General definitions
#
base_cubes_dir <- restoreutils::project_cubes_dir()
base_segs_dir <- fs::path("data/derived/segments")
base_classifications_dir <- restoreutils::project_classifications_dir()

# Model
model_version <- "samples-cer-v4a-tempcnn-default"

# Segments dir
segmentation_version <- "spacing-10-compactness-03-2018"

# Classification - version
classification_version <- glue::glue("{model_version}-{segmentation_version}")

# Classification - years
regularization_years <- 2018

# Hardware - Multicores
multicores <- 30

# Hardware - Memory size
memsize <- 96


#
# 1. Load model
#
model <- readRDS(
  restoreutils::project_model_file(version = model_version)
)


#
# 2. Classify cubes
#
for (classification_year in regularization_years) {
  # Define output directories
  cube_dir <- restoreutils::create_data_dir(
    base_cubes_dir, classification_year
  )

  classification_dir <- restoreutils::create_data_dir(
    base_classifications_dir / classification_version, classification_year
  )

  segs_dir <- base_segs_dir / segmentation_version

  classification_rds <- classification_dir / "mosaic.rds"

  # Load cube
  cube <- sits_cube(
    source      = "BDC",
    collection  = "LANDSAT-OLI-16D",
    data_dir    = cube_dir
  )

  cube <- slider::slide_dfr(cube, function(row) {
    tryCatch({
      sits_cube(
        source      = "BDC",
        collection  = "LANDSAT-OLI-16D",
        raster_cube = row,
        vector_dir  = segs_dir,
        vector_band = "segments",
        multicores  = multicores,
        version     = segmentation_version
      )
    }, error = function(e) {
      return(NULL)
    })
  })

  # Classify cube
  probs <- slider::slide_dfr(cube, function(row) {
    tryCatch({
      sits_classify(
        data        = row,
        ml_model    = model,
        multicores  = multicores,
        memsize     = memsize,
        output_dir  = classification_dir,
        progress    = TRUE,
        version     = classification_version
      )
    }, error = function(e) {
      return(NULL)
    })
  })

  # Define classification labels
  class <- sits_label_classification(
    cube       = probs,
    multicores = multicores,
    memsize    = memsize,
    output_dir = classification_dir,
    progress   = TRUE,
    version    = classification_version
  )

  # Save rds
  saveRDS(class, classification_rds)
}
