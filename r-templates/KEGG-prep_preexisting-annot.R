# 2025-02-07 - Jelmer Poelstra - R 4.4.0 on OSC-Cardinal
# /fs/ess/PAS0471/jelmer/assist/2025-01_mizuki
# Prepare the Culex pipiens KEGG annotation for use with clusterProfiler
# See https://www.genome.jp/kegg-bin/show_organism?org=cpii

# Load packages
pkgs <- c("tidyverse", "clusterProfiler", "KEGGREST")
pacman::p_load(char = pkgs)

# Source script with functions
source("mcic-scripts/rnaseq/rfuns/kegg-db_funs.R")

# Define output files
outdir <- "results/enrichment/ref"
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
kegg_outfile <- file.path(outdir, "KEGG_map.tsv")

# Set the species ID (see https://www.genome.jp/kegg/tables/br08606.html)
SPECIES_CODE <- "cpii"

# Get Culex pipiens-specific pathways with clusterProfiler
kegg_raw <- clusterProfiler::download_KEGG(species = SPECIES_CODE)

# Get pathway descriptions
pathway_info <- tibble(kegg_raw$KEGGPATHID2NAME) |>
  rename(pathway = from, description = to) |>
  # NOTE: Getting rid of organism-specific suffix:
  mutate(description = sub(" - .*", "", description))

# Get gene-to-pathway df
kegg_df <- tibble(kegg_raw$KEGGPATHID2EXTID) |>
  rename(pathway = from, gene = to) |>
  # NOTE: Adding LOC in front of geneID to get the gene name used in the count table:
  mutate(gene = paste0("LOC", gene)) |>
  left_join(pathway_info, by = "pathway")

# Write the output to file
write_tsv(kegg_df, kegg_outfile)
