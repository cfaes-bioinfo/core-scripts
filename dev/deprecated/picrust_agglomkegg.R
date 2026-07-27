#!/usr/bin/env Rscript

#SBATCH --account=PAS0471
#SBATCH --cpus-per-task=1
#SBATCH --time=15
#SBATCH --output=slurm-picrust_agglomkegg-%j.out

# SET-UP -----------------------------------------------------------------------
# Load/install packages
repo <- "https://cloud.r-project.org"
lib <- Sys.getenv("R_LIBS_USER")
dir.create(path = lib, showWarnings = FALSE, recursive = TRUE)

suppressPackageStartupMessages( {
  if (!require(pacman)) install.packages("pacman", repos = repo, lib = lib)
  if (!require(tidyverse)) install.packages("tidyverse", repos = repo, lib = lib)
} )
packages <- c("tidyverse")
pacman::p_load(char = packages, install = TRUE, repos = repo)

# Process command-line arguments
args <- commandArgs(trailingOnly = TRUE)
ko_counts_in <- args[1]                  # Input file:  Picrust KO output df
kegg_map_in <- args[2]                   # Input file:  KEGG 'map' (KO-to-pathway & KO-to-module lookup table)
module_out <- args[3]                    # Output file: counts-by-module df
pathway_out <- args[4]                   # Output file: counts-by-pathway df

# Example parameters to run interactively
# ko_counts_in <- "/fs/ess/PAS1548/FGG_Hydroponics_Survey/Analysis/phyloseq_analysis/Picrust_results_16S/KO_metagenome_out/pred_metagenome_unstrat.tsv.gz"
# kegg_map_in <- "/fs/ess/PAS0471/jelmer/refdata/kegg/ko_map.tsv"
# module_out <- "results/picrust/agglom_kegg/kegg_module_counts.txt"
# pathway_out <- "results/picrust/agglom_kegg/kegg_pathway_counts.txt"

# Create output dir if needed
outdir_mod <- dirname(module_out)
outdir_path <- dirname(pathway_out)
dir.create(outdir_mod, recursive = TRUE, showWarnings = FALSE)
dir.create(outdir_path, recursive = TRUE, showWarnings = FALSE)

# Report
message("\n# Starting script picrust_agglomkegg.R")
Sys.time()
message("# KEGG count matrix (input):           ", ko_counts_in)
message("# KEGG map/lookup (input) :            ", kegg_map_in)
message("# Module count matrix (output):        ", module_out)
message("# Pathway count matrix (output):       ", pathway_out)
message()


# FUNCTIONS --------------------------------------------------------------------
# Get mean abundances of KOs that belong to a specified module or pathway
# (The `module` argument can also represent a pathway)
getmod <- function(module, count_mat, kegg_map) {

  # Get the KO IDs for the focal module/pathway from the lookup
  KO_ids <- filter(kegg_map, pw_mod == module) |> pull(KO_id)

  # See which of these KO IDs are actually present in the KO-count-matrix 
  KO_ids_present <- KO_ids[KO_ids %in% rownames(count_mat)]
  
  # Agglomerate results by module/pathway
  if (length(KO_ids_present) > 1) {
    # If there are >1 KOs for this module/pathway,
    # then take the mean count across all KOs in the focal module/pathway:
    mod_mean <- round(colSums(count_mat[KO_ids_present, ]) / length(KO_ids_present))
    mat_out <- data.frame(t(as.matrix(mod_mean)))
    rownames(mat_out) <- module
  
  } else if (length(KO_ids_present) == 1) {
    # If there's only one KO, just take its counts:
    mat_out <- data.frame(t(as.matrix(count_mat[KO_ids_present, ])))
    rownames(mat_out) <- module
  
  } else {
    # Complain if no KOs are found (shouldn't happen):
    message("No KOs found for module/pathway: ", module)
  }
  return(mat_out)
}


# PREPARE THE INPUT FILES ------------------------------------------------------
# KEGG lookup table
kegg_map <- read_tsv(kegg_map_in, show_col_types = FALSE) |>
  dplyr::select(-symbol)

# KO count matrix
ko_counts <- read_tsv(ko_counts_in, show_col_types = FALSE) |>
  column_to_rownames("function") |>
  as.matrix() |>
  round() # Round numbers for diff. abund. tests

n_ko <- length(unique(rownames(ko_counts)))
message("Found ", n_ko, " unique KO terms in the input matrix")


# CREATE MATRIX BY KEGG MODULE -------------------------------------------------
# Get list of all modules represented by KOs in the input matrix
focal_modules <- kegg_map |>
  filter(grepl("^M", pw_mod)) |>
  filter(KO_id %in% rownames(ko_counts)) |>
  pull(pw_mod) |>
  unique()
message("Found ", length(focal_modules), " unique modules")

# Create abundance matrix w/ one row per module, summing KOs across each module
module_df <- map_dfr(.x = focal_modules, .f = getmod, ko_counts, kegg_map) |> 
  rownames_to_column("module")

write_tsv(module_df, module_out)


# CREATE MATRIX BY KEGG PATHWAY ------------------------------------------------
# Get list of all pathways represented by KOs in the input matrix
focal_pathways <- kegg_map |>
  filter(grepl("^map", pw_mod)) |>
  filter(KO_id %in% rownames(ko_counts)) |>
  pull(pw_mod) |>
  unique()
message("Found ", length(focal_pathways), " unique pathways")

# Create abundance matrix w/ one row per pathway, summing KOs across each pathway
pathway_df <- map_dfr(.x = focal_pathways, .f = getmod, ko_counts, kegg_map) |> 
  rownames_to_column("pathway")

write_tsv(pathway_df, pathway_out)


# WRAP UP ----------------------------------------------------------------------
message("\n# Listing the output files:")
system(paste("ls -lh", module_out))
system(paste("ls -lh", pathway_out))

message("\n# Done with script")
Sys.time()
sessionInfo()
