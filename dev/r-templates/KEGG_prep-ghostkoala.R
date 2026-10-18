# SETUP ------------------------------------------------------------------------
# Load packages
library(tidyverse)

# Define input files
# I ran GhostKOALA via the webservice at https://www.kegg.jp/ghostkoala on 2025-03-05:
ghostkoala_file <- "results/maize/KEGG/user_ko.txt"
# Output of mcic-scripts/annot/kegg_map.R:
pathway_file <- "results/maize/KEGG/pathway_map.tsv"

# Define output files
outdir <- "results/maize/KEGG"
dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
pw_df_file <- file.path(outdir, "KEGG_pathway-to-gene.tsv")
mod_df_file <- file.path(outdir, "KEGG_module-to-gene.tsv")


# READ AND PRE-PROCESS THE INPUT FILES -----------------------------------------
# Read the gene lookup table
gene_df <- read_tsv(gene_file, show_col_types = FALSE) |>
  select(!c(gene_description, protein_description))

# Read the KO-to-gene table:
ko_df <- read.delim(
  ghostkoala_file, sep = "\t", col.names = c("protein", "KO")
  ) |>
  tibble() |>
  mutate(
    KO = sub("^$", NA, KO),
    gene = sub("_P\\d+", "", protein)
    ) |> 
  drop_na() |>
  select(gene, KO) |>
  distinct()

# Read the pathway ('mapXXXX') and module ('MXXXX') lookup:
pw_mod_df <- read_tsv(pathway_file, show_col_types = FALSE) |>
  filter(!is.na(pw_mod))


# CREATE THE COMBINED DATAFRAMES -----------------------------------------------
# Create a pathway-only dataframe
pw_df <- pw_mod_df |>
  filter(grepl("^map", pw_mod)) |>
  select(KO = KO_id, pw_mod, pw_mod_descr) |>
  left_join(ko_df, by = "KO", relationship = "many-to-many") |>
  select(gene, pathway = pw_mod, description = pw_mod_descr) |>
  arrange(pathway)

# Create a module-only dataframe
mod_df <- pw_mod_df |>
  filter(grepl("^M", pw_mod)) |>
  select(KO = KO_id, pw_mod, pw_mod_descr) |>
  left_join(ko_df, by = "KO", relationship = "many-to-many") |>
  select(gene, module = pw_mod, description = pw_mod_descr) |>
  arrange(module)


# CHECK AND FINALIZE -----------------------------------------------------------
# Check the nr of pathways and modules
length(unique(pw_df$pathway))
length(unique(mod_df$module))

# Write the output files
write_tsv(pw_df, pw_df_file)
write_tsv(mod_df, mod_df_file)
