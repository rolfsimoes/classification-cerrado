set.seed(777)

library(sits)
library(restoreutils)

#
# General definitions
#

# Local directories
base_masks_dir <- restoreutils::project_masks_dir()

# Mask - tiles (works as a roi)
mask_tiles <- c()

roi <- sf::st_read("data/derived/classifications/samples-cer-v4a-tempcnn-default-spacing-10-compactness-05-2018/2018/cerrado-mask-crop.gpkg")

# Mask - version
version <- "rules-v1"

# Classification - version
classification_version <- "samples-cer-v4a-tempcnn-default-spacing-10-compactness-05-2018"

# samples-cer-v4a-tempcnn-default-spacing-10-compactness-05-2018
# samples-cer-v4a-tempcnn-default-spacing-20-compactness-03-2018
# samples-cer-v4a-tempcnn-tuning-spacing-10-compactness-05-2018


# Classification - years
classification_year <- 2018

# Hardware - Multicores
multicores <- 100

# Hardware - Memory size
memsize <- 300

#
# 1. Define output directory
#
classification_dir <- restoreutils::create_data_dir(
  base_masks_dir / version / classification_version, classification_year
)

output_dir <- fs::dir_create(fs::path("data/derived/masks/crosstable"))
output_dir <- fs::dir_create(output_dir / classification_version)

#
# 1. Load base masks
#

# Vegetation maps
classification_masked <- readRDS(classification_dir / "mask-cube.rds")

#
# 2. Load terraclass
#
tc_2018 <- restoreutils::load_terraclass_cerrado_2018(version = "v1", multicores = multicores, memsize = memsize)

#
# 3. Create crosstable
#

tbl <- crosstable_named(
    map            = classification_masked,
    reference      = tc_2018, 
    map_name       = "cerrado-classification", 
    reference_name = "terraclass-2018", 
    multicores     = multicores, 
    memsize        = memsize, 
    data_dir       = output_dir,
    roi            = roi
)

write.csv(
    x = tbl, file = output_dir / "cross_tbl.csv", row.names = FALSE
)
