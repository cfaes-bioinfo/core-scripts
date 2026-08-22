#!/usr/bin/env Rscript
#SBATCH --account=PAS0471
#SBATCH --time=30
#SBATCH --job-name=ggtimetree
#SBATCH --output=slurm-ggtimetree-%j.out

#? From an input tree file, this script will plot a time-tree with ggtree
#? (All tree file formats should be supported)

#? Load the Conda environment as follows to run this script without it needing to install R packages:
#? module load miniconda3 && source activate /fs/ess/PAS0471/jelmer/conda/r_tree

#! TODO
# - Including confidence intervals on the times, see /fs/ess/PAS1568/jelmer/timetree/scripts/ggtree_interactive.R

# SET-UP -----------------------------------------------------------------------
# Load packages
packages <- c("argparse", "ggtree", "ggplot2")
pacman::p_load(char = packages, install = TRUE)

# Constants
LABEL_SIZE <- 4    # Tip labels
XLAB_SIZE <- 12    # X-axis labels (years)

# Variables: parse command-line arguments
parser <- ArgumentParser()
parser$add_argument("-i", "--tree",
                    type = "character", required = TRUE,
                    help = "Input tree file (REQUIRED)")
parser$add_argument("-o", "--figure",
                    type = "character", required = FALSE, default = NULL,
                    help = "Output figure file in '.png' format
                            [default: same dir and name as tree file, but .png extension]")
parser$add_argument("--dates",
                    type = "character", required = FALSE, default = NULL,
                    help = "File with dates (use either --dates or --mrsd)
                            Dates should be in the second column")
parser$add_argument("--header",
                    action = "store_true", required = FALSE, default = FALSE,
                    help = "Dates file has a header [default: false]")
parser$add_argument("--mrsd",
                    type = "character", required = FALSE, default = NULL,
                    help = "Most recent sampling date in YYYY-MM-DD format (use either --dates or --mrsd)")
parser$add_argument("--root",
                    type = "character", default = NULL,
                    help = "ID of sample that should be the root of the tree: tree will be rerooted")
parser$add_argument("--annot",
                    type = "character", default = NULL,
                    help = "Input annotation/metadata file")
parser$add_argument("--color_column",
                    type = "character", default = NULL,
                    help = "Name of annotation file column to color tip labels by")
parser$add_argument("--tiplab_column",
                    type = "character", default = NULL,
                    help = "Name of annotation file column to use as tip labels (instead of labels in the tree file)")                    
args <- parser$parse_args()

# Save args from args list into separate variables
tree_file <- args$tree
figure_file <- args$figure
dates_file <- args$dates
has_header <- args$header
mrsd <- args$mrsd
annot_file <- args$annot
color_column <- args$color_column
tiplab_column <- args$tiplab_column
root <- args$root

# Define the output file name, if needed
if (is.null(figure_file)) {
  figure_file <- file.path(
    dirname(tree_file),
    paste0(tools::file_path_sans_ext(basename(tree_file)), ".png")
    )
}

# Report
message("\n# Starting script ggtimetree.R")
message("# Input tree file:                 ", tree_file)
if (!is.null(dates_file)) message("# Input dates file:                ", dates_file)
if (!is.null(annot_file)) message("# Annotation/metadata file:        ", annot_file)
if (!is.null(tiplab_column)) message("# Metadata column for tip labels:  ", tiplab_column)
if (!is.null(color_column)) message("# Metadata column for colors:      ", color_column)
if (!is.null(mrsd)) message("# Most recent sampling date:       ", mrsd)
if (!is.null(root)) message("# ID of sample to be root:         ", root)
message("# Output figure file:              ", figure_file)
message()


# READ AND PROCESS THE INPUT FILES ---------------------------------------------
# Read the tree
tree_file_ext <- tools::file_ext(tree_file)
if (tree_file_ext %in% c("nex", "nexus")) {
  tree <- ape::read.nexus(tree_file)
} else {
  tree <- treeio::read.tree(tree_file)
}

# Get the most recent sampling date from the dates file
if (!is.null(dates_file)) {
  dates <- read.delim(dates_file, header = has_header)
  mrsd <- sort(dates[[2]])[length((dates[[2]]))]
  # Only 'YYYY-MM-DD' dates will be parsed correctly by as.Date()
  # => convert to 'YYYY-MM-DD' by adding (07)-15 (middle of the month)
  mrsd <- ifelse(nchar(mrsd) == 4, paste0(mrsd, "-07-01"), mrsd)
  mrsd <- ifelse(nchar(mrsd) == 7, paste0(mrsd, "-15"), mrsd)
}
if (is.null(mrsd)) stop("No most recent sample date, use --dates or --mrsd")
message("# Most recent sample date:  ", mrsd)

# Read the annotation
if (!is.null(annot_file)) {
  annot <- read.delim(annot_file)
  if (!is.null(tiplab_column)) {
    annot$tiplab <- annot[[tiplab_column]]
    tiplab_column <- "tiplab"
  }
  message("# Showing the first few lines of the annotation dataframe:")
  print(head(annot))
  cat("\n")
}

# Add root option
if (! is.null(root)) {
  message("\n# Rerooting the tree, using ", root, " as the root...")
  tree <- ape::root(tree, outgroup = root, resolve.root = TRUE) 
}


# PLOT THE TREE ----------------------------------------------------------------
# Base tree
p <- ggtree(tree, layout = "rectangular", mrsd = mrsd)

# Add annotation dataframe if provided
if (!is.null(annot_file)) p <- p %<+% annot

# Tip labels
if (!is.null(tiplab_column)) {
  message("# Using custom tip labels...")
  p <- p + geom_tiplab(aes_string(color = color_column, label = tiplab_column),
                       align = TRUE, linesize = 0, size = LABEL_SIZE)
} else {
  message("# Using default tip labels...")
  p <- p + geom_tiplab(aes_string(color = color_column),
                       align = TRUE, linesize = 0, size = LABEL_SIZE)
}

# Formatting
p <- p +
  geom_rootedge(rootedge = sum(tree$edge.length) / 50) +
  coord_cartesian(clip = "off") +
  scale_x_continuous(n.breaks = 8, labels = scales::comma) +
  theme_tree2() +
  theme(plot.margin = margin(0.2, 3, 0.2, 0.75, "cm"),
        axis.text.x = element_text(size = XLAB_SIZE, color = "grey50"),
        axis.line.x.bottom = element_line(color = "grey50"),
        axis.ticks.x.bottom = element_blank(),
        panel.grid.major.x = element_line(linetype = "longdash"),
        legend.position = "top")

# Save the plot to file
ggsave(figure_file, p, width = 8, height = 8, dpi = "retina")


# WRAP UP ----------------------------------------------------------------------
message("\n# Listing the output file:")
system(paste("ls -lh", figure_file))
message("\n# Done with script ggtimetree.R")
Sys.time()
