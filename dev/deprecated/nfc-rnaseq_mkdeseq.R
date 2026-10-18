#!/usr/bin/env Rscript
#SBATCH --account=PAS0471
#SBATCH --time=10
#SBATCH --mem=4G
#SBATCH --job-name=make_dds
#SBATCH --output=slurm-make_dds-%j.out

# DESCRIPTION ------------------------------------------------------------------
# This script will create a DESeq object from one of the RDS files that the
# nf-core 'rnaseq' pipeline produces.

# SETUP ------------------------------------------------------------------------
# Constants
# - Expected TSV file location within the nf-core rnaseq output:
INFILE_PART <- "star_salmon/salmon.merged.gene_counts_length_scaled.tsv"

# Load/install packages
rep <- "https://cloud.r-project.org"
lib <- Sys.getenv("R_LIBS_USER")
dir.create(path = lib, showWarnings = FALSE, recursive = TRUE)

suppressPackageStartupMessages( {
  if (!require(argparse, quietly = TRUE)) install.packages("argparse", repos = rep, lib = lib)
  if (!require(pacman, quietly = TRUE)) install.packages("pacman", repos = rep, lib = lib)
  if (!require(BiocManager, quietly = TRUE)) install.packages("BiocManager", repos = rep, lib = lib)
  if (!require(DESeq2, quietly = TRUE)) BiocManager::install("DESeq2")
  packages <- c("argparse", "DESeq2")
  pacman::p_load(char = packages, install = TRUE)
} )

# Parse arguments
parser <- ArgumentParser()
parser$add_argument("-i", "--indir",
                    type = "character",
                    required = TRUE,
                    default = NULL,
                    help = "Top-level dir with nf-core RNAseq workflow results [REQUIRED]")
parser$add_argument("-o", "--outfile",
                    type = "character",
                    required = FALSE,
                    default = NULL,
                    help = "Output file path [default: dds.rds in input dir])")
parser$add_argument("--meta",
                    type = "character",
                    required = FALSE,
                    default = NULL,
                    help = "Metadata file (TSV) [optional]")
parser$add_argument("--id_col",
                    type = "integer",
                    required = FALSE,
                    default = 1,
                    help = "In metadata file, column number with sample IDs [default: 1]")
args <- parser$parse_args()

# Save argument in variables
indir <- args$indir
outfile <- args$outfile
meta_file <- args$meta
sample_id_column <- args$id_col

# Define input files
infile <- file.path(indir, INFILE_PART)

# Output files
if (is.null(outfile)) outfile <- file.path(indir, "dds.rds")
outdir <- dirname(outfile)
logdir <- file.path(outdir, "logs")
dir.create(logdir, showWarnings = FALSE, recursive = TRUE)

# Report
message("Starting script nfc-rnaseq_make-deseq.R")
Sys.time()
message()
message("Input dir:                        ", indir)
message("Input RDS file:                   ", infile)
message("Output RDS file (DESeq object):   ", outfile)
if (!is.null(meta_file)) message("Input metadata file:              ", meta_file)
message("======================================================================")
message()

# Check input files
if (!file.exists(infile)) stop("Input file ", infile, " does not exist")
if (!is.null(meta_file)) if (!file.exists(meta_file)) stop("Metadata file ", meta_file, " does not exist")


# CREATE THE DESEQ OBJECT ------------------------------------------------------
# Load counts
count_df <- read.delim(infile)
rownames(count_df) <- count_df$gene_id
count_df$gene_id <- count_df$gene_name <- NULL
count_mat <- round(as.matrix(count_df))
message("\n# Dimensions of the count matrix:")
dim(count_mat)

# Metadata
if (!is.null(meta_file)) {
  meta_df <- read.delim(meta_file, header = TRUE, sep = "\t")
  message("# Number of rows in the metadata: ", nrow(meta_df))
  
  # Sample IDs as rownames
  rownames(meta_df) <- meta_df[[sample_id_column]]
  
  # Sort by sample ID
  meta_df <- meta_df[order(meta_df[[sample_id_column]]), ]
  
  # Filter missing samples
  smp <- meta_df[[sample_id_column]]
  missing <- smp[! smp %in% colnames(count_mat)]
  if (length(missing > 0)) {
    message("The following samples in the metadata are missing from the count table:")
    print(missing)
    meta_df <- meta_df[-match(missing, meta_df[[sample_id_column]]), ]
    message("# Number of rows left in the metadata: ", nrow(meta_df))
  }
  
  # Make columns factors (except the 1st one, which should be sample IDs)
  cols <- colnames(meta_df[2:ncol(meta_df)])
  meta_df[cols] <- lapply(meta_df[cols], as.factor)
  
  # Check that sample names are the same, and that samples are in the same order
  stopifnot(all(rownames(meta_df) == colnames(count_mat)))
  
  # Report
  message("\n# Sample names:")
  print(rownames(meta_df))
} else {
  # Create dummy metadata df on the fly
  meta_df <- data.frame(sample_id = colnames(count_mat))
  rownames(meta_df) <- meta_df$sample_id
}

# Create DESeq object (For now, set design to dummy `~1` => intercept only)
dds <- DESeqDataSetFromMatrix(countData = count_mat,
                              colData = meta_df,
                              design = ~1)

# Save the output file
saveRDS(dds, outfile)


# WRAP UP ----------------------------------------------------------------------
# List output
message("\n# Listing the output file(s):")
system(paste("ls -lh", outfile))

message("\n# Done with script nfc-rnaseq_make-deseq.R")
Sys.time()
message()
sessionInfo()

# Docs:
#  - https://nf-co.re/rnaseq/3.10.1/output#salmon
#  - https://github.com/nf-core/rnaseq/issues/499
#  - https://bioconductor.org/packages/devel/bioc/vignettes/tximport/inst/doc/tximport.html

# Alternatively, could load RData from the workflow's DESeq analysis (these are the same)
# infile_deseq <- file.path(NFCORE_RNASEQ_OUTDIR, "star_salmon/deseq2_qc/deseq2.dds.RData")
# load(infile_deseq)
