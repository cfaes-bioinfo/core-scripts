# 2025-02-07 - Jelmer Poelstra - R 4.4.0 on OSC-Cardinal
# /fs/ess/PAS0471/jelmer/assist/2025-01_mizuki
# Prepare the Culex pipiens GO annotation for use with clusterProfiler

# Load packages
library(tidyverse)

# Define input files
func_script <- "mcic-scripts/rnaseq/rfuns/enrich_funs.R"
GO_infile <- "results/refdata/GCF_016801865.2-RS_2022_12_gene_ontology.gaf"

# Define output files
outdir <- "results/enrichment/ref"
dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
GO_outfile <- file.path(outdir, "GO_map.tsv")

# Source function file
source(func_script)

# Read the input files
GO <- read_tsv(GO_infile, skip = 8, show_col_types = FALSE)

# Prepare the GO term descriptions df
go_info <- get_GO_info()

# Prep the final lookup table
GO_df <- GO |>
  dplyr::select(term = GO_ID, gene = Symbol) |>
  left_join(go_info, by = "term") |>
  # NOTE: removing terms without a description, these are deprecated:
  filter(!is.na(description)) |> 
  arrange(term)

# Write the output to file
write_tsv(GO_df, GO_outfile)
