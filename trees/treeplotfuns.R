# Some useful scripts with trees
# /fs/ess/PAS0471/jelmer/assist/01_archive/2022-06_sochina/scripts/ggtree.R

# Function to convert a BactDating result object to a treedata object
# for plotting with ggtree.
bactdate2treedata <- function(bactdate_obj) {
  
  tree_list <- as.treedata.resBactDating(bactdate_obj)
  
  tree_data <- methods::new(
    'treedata',
    phylo = tree_list[[1]],
    data = as_tibble(as.data.frame(tree_list[[2]]))
    )
  
  return(tree_data)
}


# Function to plot a (time)tree with ggtree
ptree <- function(
    tree,                         # Tree or treedata object
    mrsd = NULL,                  # Most recent sampling date -- using this will turn the tree into a timetree
    meta = NULL,                  # Dataframe with metadata
    tiplab_column = NULL,         # Column from 'meta' with tiplabels to use (default: tree's own tiplabels)
    color_column = NULL,          # Column from 'meta' to color tiplabels by 
    boot = FALSE,                 # Bootstrap values -- 'text': show labels, 'colors': color-code, FALSE: none
    boot_tres = 70,               # If 'boot = text', only show bootstrap vals below this threshold
    ci_name = NULL,               # Name of the column/element with the dating CIs to plot (for timetrees)
    layout = "rectangular",       # Tree layout (one of the layouts supported by ggtree)
    tiplab_offset = 0,            # Offset for tip labels (move to the right)
    tiplab_size = 4,              # Font size of the tiplabels
    xlab_size = 12,               # Font size of the x-axis labels
    right_margin = 3,             # Size of the right margin (increase if labels are running off the plot)
    scale_breaks = NULL,          # Breaks along the x-axis (for timetrees)
    alignment = NULL              # Sequence alignment to add next to the plot
  ) {
  
  # Test args
  stopifnot(boot %in% c(FALSE, "text", "colors"))
  if (!is.null(meta)) {
    if (!is.null(tiplab_column)) stopifnot(tiplab_column %in% colnames(meta))
    if (!is.null(color_column)) stopifnot(color_column %in% colnames(meta))
  }
  
  # Determine if the tree is a timetree
  if (!is.null(mrsd)) timetree <- TRUE else timetree <- FALSE
  
  # Determine the total size of the tree
  if (class(tree) == "treedata") {
    tree_size <- sum(tree@phylo$edge.length)
  } else {
    tree_size <- sum(tree$edge.length)
  }
  
  # Base tree
  if (!timetree) p <- ggtree(tree, layout = layout)
  if (timetree) p <- ggtree(tree, layout = layout, mrsd = mrsd)
  
  # Add annotation dataframe if provided
  if (!is.null(meta)) {
    meta$tiplab <- meta[[tiplab_column]]
    tiplab_column <- "tiplab"
    p <- p %<+% meta
  }
  
  # Add tip labels
  if (!is.null(tiplab_column)) {
    p <- p + suppressWarnings(
      geom_tiplab(aes_string(color = color_column, label = tiplab_column),
                  align = TRUE,
                  offset = tiplab_offset,
                  linesize = 0,
                  size = tiplab_size,
                  fontface = "bold")
    )
  } else {
    p <- p + suppressWarnings(
      geom_tiplab(aes_string(color = color_column),
                  align = TRUE,
                  offset = tiplab_offset,
                  linesize = 0,
                  size = tiplab_size,
                  fontface = "bold")
    )
  }
  
  # Add dating confidence intervals (CIs)
  if (!is.null(ci_name)) {
    p <- p + geom_range(range = ci_name, color = "red", size = 1, alpha = 0.3)
  }
  
  # Add bootstrap support values
  if (boot == "text") {
    p <- p +
      geom_text2(
        aes(subset = !is.na(as.numeric(label)) & as.numeric(label) < boot_tres,
            label = label),
        color = "grey50", size = 3,
        nudge_y = 0.4, nudge_x = -(tree_size / 150)
        )
    
  }
  if (boot == "colors") {
    p <- p +
      geom_nodepoint(
        aes(subset = !is.na(as.numeric(label)), fill = as.numeric(label)),
        shape = 21, size = 2, color = "grey30"
        ) +
      scale_fill_viridis_c(name = "Bootstrap\nsupport", breaks = c(0, 50, 75, 100))
  }

  # X-axis scale for timetree
  if (timetree) {
    if (!is.null(scale_breaks)) {
      n_breaks <- NULL
    } else {
      scale_breaks <- waiver()
      n_breaks <- 8
    }
    p <- p + scale_x_continuous(breaks = scale_breaks, n.breaks = n_breaks,
                                labels = scales::comma)
  }
  
  # Formatting - scales etc
  p <- p +
    #scale_color_brewer(palette = "Dark2") +
    geom_rootedge(rootedge = tree_size / 50) +
    coord_cartesian(clip = "off")
  
  # Formatting - theme
  p <- p +
    theme(plot.margin = margin(0.2, right_margin, 0.2, 0.75, "cm"),
          legend.position = "top",
          legend.box = "vertical")
  if (timetree) {
    p <- p +
      theme(axis.text.x = element_text(size = xlab_size, color = "grey50"),
            axis.line.x.bottom = element_line(color = "grey50"),
            axis.ticks.x.bottom = element_blank(),
            panel.grid.major.x = element_line(linetype = "longdash"))
  } else {
    p <- p + geom_treescale(color = "grey30")
  }
  
  # Print the tree
  if (!is.null(alignment)) {
    msaplot(p, alignment, width = 2)
  } else {
    suppressWarnings(print(p))
  }
}
