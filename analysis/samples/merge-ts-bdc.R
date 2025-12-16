library(sits)
library(restoreutils)

#
# General definitions
#
# Output dir
base_output_dir <- "data/derived/"

# Samples version
samples_version <- "samples-cer-v4a"


#
# 1. Create output directories
#
samples_dir <- restoreutils::create_data_dir(base_output_dir, "timeseries")


#
# 2. Get existing samples
#
samples_ts <- fs::dir_ls(samples_dir, glob = glue::glue("*{samples_version}-q*.rds"))


#
# 3. Load and merge
#
samples_ts <- lapply(samples_ts, readRDS) |>
                dplyr::bind_rows() |>
                dplyr::distinct(.data[["latitude"]], .data[["longitude"]], .data[["label"]], .keep_all = TRUE)


#
# 4. Save samples
#
saveRDS(samples_ts, samples_dir / glue::glue("{samples_version}-complete.rds"))
