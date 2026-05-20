rm(list = ls())

# -------------- 1. Check Necessary packages are Installed ---------------------
# R
if(!require("sf")) install.packages("sf")
if(!require("dplyr")) install.packages("dplyr")
if(!require("ncdf4")) install.packages("ncdf4")
if(!require("terra")) install.packages("terra")
if(!require("here")) install.packages("here") 
if(!require("ggplot2")) install.packages("ggplot2") 

library(sf)
library(dplyr)
library(ncdf4)
library(terra)
library(here)
library(ggplot2)

wd <- here()
setwd(wd)

# Python
python = Sys.which("python3.10")
python <- python[1L]
system2(python, c("-m", "pip install -r requirements.txt"))



# ----------- 2. Call Python script to download raw from CDS API ---------------

#system2(python, c("data/fao_lccs/query_cds_api.py"), stdout = TRUE)
# Commented out for now, we don't currently need it

# ----------- 3. To be added: processing with darts pipeline -------------------
# Rasters are processed using the darts pipeline: https://dart-pipeline.readthedocs.io/en/latest/
# This was previously done for
# another project, so we are migrating over the code. For now, we are taking the
# outputs from the processing from another project, making some minor adjustments, 
# and uploading the data

# -------------------- 4. Read in Current NCDF Files  --------------------------
# When we have the darts pipeline code up and running we will likely remove ncdf
# files from repo and just have geoJSON. For now, we read in our current ncdf files
# from another project, subset to our interested timepoint (most recent) and convert
# to geoJSON


ncdf_raw <- nc_open("data/fao_lccs/raw/COD-2022-satellite_land_cover_urban.zs.nc")
names(ncdf_raw$var)
names(ncdf_raw$dim)

# Note there's only one timepoint in this file which is confusing

# Pick the most recent time layer
vals <- ncvar_get(ncdf_raw, "lccs_class")
regions <- ncvar_get(ncdf_raw, "region")

urbanization_table <- data.frame(ZSCode = regions,
                                 urban_fraction = vals)

healthzone_shapefile <- st_read("data/shapefiles/DRC_Health_zones.shp")

# Disambiguate Nom for zones whose name appears in more than one province
# (currently Bili and Lubunga), mirroring the Python schema contract.
nom_counts <- healthzone_shapefile |>
  dplyr::count(Nom) |>
  dplyr::filter(n > 1) |>
  dplyr::pull(Nom)
healthzone_shapefile <- healthzone_shapefile |>
  dplyr::mutate(Nom = dplyr::if_else(
    Nom %in% nom_counts,
    paste0(Nom, " (", PROVINCE, ")"),
    Nom
  ))

joined_shapefile <- healthzone_shapefile |>
  dplyr::left_join(urbanization_table)

p <- ggplot(joined_shapefile) +
  geom_sf(aes(fill = log(urban_fraction)), col = NA) +
  scale_fill_viridis_c(
    name = "Urban fraction (Grey = 0% Urban)",   # legend title
    option = "C",
    breaks = log(c(0.001, 0.1, 1)),
    labels = c(0.001, 0.1, 1),
  ) +
  theme_classic() +
  theme(axis.line = element_blank(),
        axis.ticks = element_blank(),
        axis.text = element_blank(),
        legend.position = "inside",
        legend.position.inside = c(0.25,0.15),
        legend.direction = "horizontal",
        legend.title.position = "top",
        legend.background = element_blank()) +
  ggtitle("Proportion of each healthzone classified as 'Urban' (code 190) by UN FAO LCCS")

ggsave("data/fao_lccs/processed_plot.png", p, height = 6, width = 6, units = "in")


final_export <- joined_shapefile |>
  dplyr::select(Nom, urban_fraction) |>
  dplyr::rename(nom = Nom) |>
  st_drop_geometry()

write.csv(final_export, "data/fao_lccs/processed/fao_lccs__urban_fraction__static.csv")

