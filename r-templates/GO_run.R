# Load packages
library(clusterProfiler)
library(enrichplot)
library(tidyverse)
library(ggridges)
library(ggupset)

# Source script with functions
source("mcic-scripts/rnaseq/rfuns/enrich_funs.R")

# Input files
GO_file <- "/fs/ess/PAS0471/jelmer/example_data/rnaseq/helico/GCF_030705265.1_GO-map.tsv"
DE_file <- "/fs/ess/PAS0471/jelmer/example_data/rnaseq/helico/DEGs.tsv"

# Set random seed - needed for reproducible GSEA results due to permutations
set.seed(1)

# Read the input files
GO_map <- read_tsv(GO_file, show_col_types = FALSE) 
DE_res <- read_tsv(DE_file, show_col_types = FALSE) 


# RUN AND VISUALIZE FOR ONE CONTRAST AT A TIME ---------------------------------
# To be able to use the "enrichplot" visualizations,
# use return_df=FALSE to keep the native clusterProfiler object format
ORA_SHSA <- run_ora(contrast = "SH vs. SA",
                    DE_res = DE_res, term_map = GO_map, return_df = FALSE)
gsea_SHSA <- run_gsea(contrast = "SH vs. SA",
                      DE_res = DE_res, term_map = GO_map, return_df = FALSE)

# Ridgeline plot
ridgeplot(gsea_SHSA) +
  theme(axis.text.y = element_text(size = 10))

# Upsetplot
upsetplot(gsea_SHSA)


# RUN ORA FOR ALL CONTRASTS ----------------------------------------------------
# The classic Over-representation Analysis (ORA) enrichment test
# Run all contrasts, one at a time, and collect in a single dataframe

# Enrichment only for genes with log-fold change > 0 (DE_direction: up)
GO_ORA_up <- map_dfr(
  .x = unique(DE_res$contrast), .f = run_ora,
  DE_res = DE_res, term_map = GO_map, DE_direction = "up", return_df = TRUE
  )

# Enrichment only for genes with log-fold change < 0 (DE_direction: down)
GO_ORA_down <- map_dfr(
  .x = unique(DE_res$contrast), .f = run_ora,
  DE_res = DE_res, term_map = GO_map, DE_direction = "down", return_df = TRUE
)

# Combine up/down results
GO_ORA <- bind_rows(GO_ORA_up, GO_ORA_down)


# RUN GSEA FOR ALL CONTRASTS ---------------------------------------------------
# Gene Set Enrichment Analysis (GSEA) - uses all genes, both DEGs and not-DE genes:
# it is therefore not separately run for DE directions
GO_GSEA <- map_dfr(
  .x = unique(DE_res$contrast), .f = run_gsea,
  DE_res = DE_res, term_map = GO_map, return_df = TRUE
  )


# VISUALIZE ORA RESULTS USING FUNCTIONS IN ENRICH_FUNS.R -----------------------
# (Both of these functions will plot a number in a box/dot for each category,
# which is the nr of DEGs in each category.)

# Make a data subset for visualization
GO_ORA_viz <- GO_ORA |>
  # Optional filtering by contrasts (all contrasts at once will be too many)
  filter(contrast %in% c("SH vs. SA", "SH vs. SZ", "SA vs. SZ")) |>
  # Optional filtering by p-value (in this example, a little too many terms would otherwise be plotted)
  filter(any(padj < 0.01), .by = "term")

# The 'cdotplot()' (for Cleveland's dotplot) function
# Example 1: facet vertically by DE_direction (up vs down), and horizontally by contrast
# (facet_scales = "free_y" => have the same x-axis scale across facets) 
GO_ORA_viz |>
  cdotplot(facet_var1 = "DE_direction", facet_var2 = "contrast",
           facet_scales = "free_y")

# Example 2: facet horizontally be ontology (BP vs CC vs MF)
GO_ORA_viz |>
  cdotplot(facet_var1 = "ontology", facet_var2 = "contrast",
           facet_scales = "free_y")

# Example 3: include the GO category ID
GO_ORA_viz |>
  cdotplot(facet_var1 = "ontology", facet_var2 = "contrast",
           facet_scales = "free_y", add_term_id = TRUE)

# Alternative plot type: the 'tileplot()' function
GO_ORA_viz |>
  tileplot(facet_var1 = "DE_direction", facet_var2 = "contrast")
  

# VISUALIZE GSEA RESULTS USING FUNCTIONS IN ENRICH_FUNS.R ----------------------
GO_GSEA_viz <- GO_GSEA |>
  # Optional filtering by contrasts (all contrasts at once will be too many)
  filter(contrast %in% c("SH vs. SA", "SH vs. SZ", "SA vs. SZ")) |> 
  # Optional filtering by p-value
  filter(any(padj < 0.01), .by = "term")

GO_GSEA_viz |>
  cdotplot(facet_var1 = "ontology", facet_var2 = "contrast",
           x_var = "median_lfc", fill_var = "padj_log",
           label_var = NULL, facet_scales = "free_y")
