#!/usr/bin/env Rscript
#SBATCH --account=PAS0471
#SBATCH --output=slurm-kegg_map-%j.out
#SBATCH --time=12:00:00

# kegg_map.R by Jelmer Poelstra, last edited 2024-11-09
# Script to create a KEGG 'map'/lookup
# - Input is a tab-separated file that contains KO numbers in the second column and has no column header line
#   This is the format output by the GhostKOALA webserver (https://www.kegg.jp/ghostkoala)
# - The script will look up KEGG modules and pathways that each KO number belongs to

# Example command to run the script:
#> input_ko_list=/fs/ess/PAS0471/jelmer/refdata/kegg/ko_list
#> output_ko_map=/fs/ess/PAS0471/jelmer/refdata/kegg/ko_map.tsv
#> module load R/4.4.0-gnu11.2
#> sbatch mcic-scripts/annot/kegg_map.R "$input_ko_list" "$output_ko_map"

# SET-UP -----------------------------------------------------------------------
# Process command-line arguments
args <- commandArgs(trailingOnly = TRUE)
ko_file <- args[1]             # Input file with KO numbers in the 1st column, and gene IDs in the second
kegg_map_file <- args[2]       # Output: KO-to-pathway+module mappings

# Report
message("\n# Starting script kegg_map.R")
Sys.time()
message("# Input KO file:               ", ko_file)
message("# Output KEGG map:             ", kegg_map_file)
message("==============================================\n")

# Check input
stopifnot(file.exists(ko_file))

# Install/load packages
if (!"pacman" %in% installed.packages()) install.packages("pacman")
packages <- c(
    "tidyverse",
    "here",
    "KEGGREST",
    "clusterProfiler"
)
pacman::p_load(char = packages)
source("mcic-scripts/rnaseq/rfuns/kegg-db_funs.R")


# CREATE KEGG MAP --------------------------------------------------------------
# Create output dir if needed
outdir <- dirname(kegg_map_file)
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

# Read input files
message("\n# Now reading the input file...")
ko_terms <- read.delim(ko_file, sep = "\t", header = FALSE) |>
  mutate(K_nr = ifelse(V2 == "", NA, V2)) |> 
  drop_na() |>
  pull(K_nr)
message("\n# Number of ko_terms: ", length(ko_terms))

# Get KEGG pathways associated with the different K-terms
message("\n# Now creating the KEGG map...")
kegg_map <- map_dfr(.x = ko_terms, .f = pw2ko, outdir)

# Write files
message("\n# Now writing the output file...")
write_tsv(kegg_map, kegg_map_file)


# WRAP UP ----------------------------------------------------------------------
message("\n==============================================")
message("# Listing the output file:")
system(paste("ls -lh", kegg_map_file))

message("\n# Done with script kegg_map.R")
Sys.time()
sessionInfo()
