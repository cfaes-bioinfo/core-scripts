## Function to make a boxplot showing abundance of an ASV/genus/etc
plot_abund <- function(
  ID,
  x_var = "treatment", col_var = "treatment", facet_var = NULL,
  ps = NULL, count_mat = NULL, meta = NULL, tax_df = NULL,
  model_res = NULL,
  omit_id = NULL, tax_level = "ASV",
  cols = NULL, title_size = 14,
  saveplot = FALSE, plotdir = here("reports/figs"), plot_id = NULL,
  ...) {
  
  ## If a phyloseq object is provided, take the count data and metadata from there
  if (!is.null(ps)) {
    if (is.null(meta)) meta <- sample_data(ps)
    if (is.null(count_mat)) count_mat <- as(t(otu_table(ps)), "matrix")
    if (is.null(tax_df)) tax_df <- as.data.frame(tax_table(ps)[ID, ]) %>% rownames_to_column("ASV")
  }
  
  if (!is.null(facet_var)) {
    if (is.factor(meta[[facet_var]])) meta[[facet_var]] <- droplevels(meta[[facet_var]])
  }
  
  ## Plot title
  if (is.null(omit_id)) if (tax_level == "ASV") omit_id <- FALSE else omit_id <- TRUE
  plot_title <- taxtitler(ID, tax_df,
                          omit_id = omit_id, tax_level = tax_level, ...)
  
  ## Create df with data to plot
  count_df <- data.frame(meta, count = count_mat[ID, ], ID = ID)
  
  ## Create the main plot
  p <- ggplot(count_df) +
    aes(x = .data[[x_var]], y = count) +
    geom_boxplot(outlier.shape = NA) +
    scale_y_continuous(expand = expansion(mult = c(0.05, 0.2))) +
    labs(x = x_var,
         y = "Normalized abundance",
         title = plot_title) +
    theme(legend.position = "right",
          plot.title = element_text(size = title_size, hjust = 0.5),
          panel.grid.major.x = element_blank(),
          panel.grid.minor.y = element_blank(),
          plot.margin = unit(c(0.5, 0.5, 1, 0.5), "cm"))
  
  ## Color points, if needed
  if (!is.null(col_var)) {
    p <- p + geom_point(aes(color = .data[[col_var]]),
                        position = position_jitter(w = 0.1, h = 0),
                        size = 2)
    if (is.null(cols)) p <- p + scale_color_brewer(palette = "Dark2")
    if (!is.null(cols)) p <- p + scale_color_manual(values = cols)
  } else {
    p <- p + geom_point(position = position_jitter(w = 0.1, h = 0),
                        size = 2, color = "grey50")
  }
  
  ## Create facet, if needed
  if (!is.null(facet_var)) {
    p <- p + facet_wrap(vars(.data[[facet_var]]), labeller = label_both)
  }
  
  ## Add significance
  if (!is.null(model_res)) {
    stat_df <- get_sig(fID = ID, model_res = model_res, facet_var = facet_var)
    p <- p + geom_text(data = stat_df,
                       aes(x = Inf, y = Inf, label = label),
                       hjust = 1.1, vjust = 1.5, size = 4, color = "darkred")
  }
  
  ## Save or print plot
  if (saveplot == TRUE) {
    if (is.null(plot_id)) plot_id <- ID else plot_id <- paste0(plot_id, "_", ID)
    plotfile <- here(plotdir, paste0("boxplot_", plot_id, ".png"))
    ggsave(plotfile, p)
    return(plotfile)
  } else {
    print(p)
  }
}

## Get pheatmap plot dimensions so it doesn't run out of the image
## See https://stackoverflow.com/questions/61874876/get-size-of-plot-in-pixels-in-r
get_plot_dims <- function(heat_map) {
  plot_height <- sum(sapply(heat_map$gtable$heights, grid::convertHeight, "in"))
  plot_width  <- sum(sapply(heat_map$gtable$widths, grid::convertWidth, "in"))
  return(list(height = plot_height, width = plot_width))
}

## Heatmap plot showing abundances
plot_heatmap <- function(IDs,
                         dds = NULL, count_mat = NULL, meta_df = NULL,
                         groups = c("treatment"),
                         log_transform = TRUE,
                         show_rownames = TRUE, show_colnames = FALSE,
                         id_labsize = 10, annotation_colors = NULL,
                         saveplot = FALSE, plotdir = here("reports/figs"),
                         plot_id = NULL, ...) {
  
  if (!dir.exists(plotdir)) dir.create(plotdir, recursive = TRUE)
  
  ## If a DESeq object is provided, take the count data and metadata from there
  if (!is.null(dds)) {
    if (is.null(meta_df)) meta_df <- as.data.frame(colData(dds))
    if (is.null(count_mat)) count_mat <- assay(normTransform(dds))
  } else {
    meta_df <- data.frame(meta_df)
  }
  
  ## Select groups
  fmeta <- meta_df[, groups, drop = FALSE]
  
  ## Arrange metadata according to the columns with included factors
  if (length(groups) == 1) fmeta <- fmeta %>% arrange(.data[[groups[1]]])
  if (length(groups) == 2) fmeta <- fmeta %>% arrange(.data[[groups[1]]],
                                                      .data[[groups[2]]])
  if (length(groups) == 3) fmeta <- fmeta %>% arrange(.data[[groups[1]]],
                                                      .data[[groups[2]]],
                                                      .data[[groups[3]]])
  
  ## Select IDs
  fcount_mat <- count_mat[match(IDs, rownames(count_mat)),
                          match(rownames(fmeta), colnames(count_mat))]
  fcount_mat <- as.matrix(fcount_mat)
  
  ## Take log10 of counts
  if(log_transform == TRUE) {
    fcount_mat <- log10(fcount_mat)
    fcount_mat[fcount_mat == -Inf] <- 0
  }
  
  ## If few features are included, reduce the cell (row) height
  cellheight <- ifelse(length(IDs) > 20, NA, 20)
  id_labsize <- ifelse(length(IDs) > 40, 6, id_labsize)
  
  ## Truncate long taxon names
  row.names(fcount_mat) <- str_trunc(row.names(fcount_mat),
                                     width = 20, ellipsis = "")
  
  ## If there is only one ID (row), avoid messed-up matrix and don't cluster
  if (length(IDs) == 1) {
    fcount_mat <- t(as.matrix(fcount_mat))
    cluster_rows <- FALSE
  } else {
    cluster_rows <- TRUE
  }
  
  ## Function to create the plot
  pheat <- function(...) {
    pheatmap(
      fcount_mat,
      annotation_col = fmeta, annotation_colors = annotation_colors,
      cluster_rows = cluster_rows, cluster_cols = FALSE,
      show_rownames = show_rownames, show_colnames = show_colnames,
      cellheight = cellheight,
      fontsize = 9, fontsize_row = id_labsize, cex = 1,
      ...
    )
  }
  
  ## Save or print the plot
  if (saveplot == TRUE) {
    
    ## Create the plot - wrap in `png()` call so it doesn't get printed
    setEPS(); postscript(here(plotdir, "tmp.eps"))
    p <- pheat(...)
    plot_dims <- get_plot_dims(p)
    invisible(dev.off())
    
    ## Determine filename
    if (is.null(plot_id)) {
      plot_id <- str_trunc(paste(IDs, collapse = "_"), width = 40, ellipsis = "")
    }
    
    plotfile <- here(plotdir, paste0("heatmap_", plot_id, ".png"))
    ggsave(plotfile, p,
           height = plot_dims$height, width = plot_dims$width, units = "in")
  } else {
    print(pheat())
  }
}

## Get df to add significance to abundance plot
get_sig <- function(fID, model_res, facet_var) {
  fres_all <- model_res %>% dplyr::filter(ID == fID)
  fres_sig <- fres_all %>% dplyr::filter(padj < 0.1)
  
  onelab <- function(i) {
    padjs <- format(fres_sig$padj[i], digits = 3, scientific = TRUE)
    if ("model" %in% colnames(fres_sig) & "term" %in% colnames(fres_sig)) {
      paste0(fres_sig$model[i], " - ", fres_sig$term[i], ": p=", padjs)
    } else {
      paste0(fres_sig$term[i], ": p=", padjs)
    }
  }
  
  if (nrow(fres_all) >= 1 & nrow(fres_sig) >= 1) {
    plab <- paste(sapply(1:nrow(fres_sig), onelab), collapse = "\n")
  } else {
    plab <- "(No significant terms)"
  }
  
  if (!is.null(facet_var)) {
    fac_var <- meta[[facet_var]]
    lev1 <- ifelse(is.factor(fac_var), levels(fac_var)[1], unique(sort(fac_var))[1])
    stat_df <- data.frame(to_replace = lev1, label = plab)
    colnames(stat_df)[1] <- facet_var
  } else {
    stat_df <- data.frame(label = plab)
  }
  
  return(stat_df)
}

## Create plot title from taxon ID
taxtitler <- function(ID, tax_df, tax_level = "ASV", omit_id = FALSE,
                      tax_df_column = "ID") {
  
  if (!is.null(tax_df)) {
    
    tax_row <- which(tax_df[[tax_df_column]] == ID)
    
    if (tax_level %in% c("genus", "family", "order", "class")) tax_df$species <- NA
    if (tax_level %in% c("family", "order", "class")) tax_df$genus <- NA
    if (tax_level %in% c("order", "class")) tax_df$family <- NA
    if (tax_level %in% c("class", "phylum")) tax_df$order <- NA
    if (tax_level == "phylum") tax_df$class <- NA
    
    taxon <- tax_df[tax_row, ] %>%
      mutate(taxon = case_when(
        !is.na(species) ~ paste0("Species: ", genus, " ", species, "\n(phylum ", phylum, ")"),
        !is.na(genus) ~ paste0("Genus: ", genus, "\n(phylum ", phylum, ")"),
        !is.na(family) ~ paste0("Family: ", family, "\n(phylum ", phylum, ")"),
        !is.na(order) ~ paste0("Order: ", order, "\n(phylum ", phylum, ")"),
        !is.na(class) ~ paste0("Class: ", class, "\n(phylum ", phylum, ")"),
        !is.na(phylum) ~ paste0("Phylum: ", phylum),
        TRUE ~ "No phylum assigned"
      )) %>%
      pull(taxon)
    
    if (omit_id == FALSE) plot_title <- paste0(ID, " - ", taxon)
    if (omit_id == TRUE) plot_title <- taxon
  }
  else {
    if (omit_id == FALSE) plot_title <- ID
    if (omit_id == TRUE) plot_title <- NULL
  }
  
  return(plot_title)
  #plot_title <- str_wrap(plot_title, width = 35)
}

## Plot DivNet diversity
plot_div <- function(ps, divnet_obj = NULL, ytitle = NULL,
                     div_index = "shannon", covar = "treatment",
                     each_sample = FALSE, ...) {
  
  if (!is.null(divnet_obj)) {
    df <- get_divnet(divnet_obj,
                     meta = as_tibble(sample_data(ps)),
                     div_index = div_index)
    if (is.null(ytitle)) ytitle <- paste(div_index, "diversity estimate")
    
  } else {
    df <- get_break(ps)
    if (is.null(ytitle)) ytitle <- "richness estimate"
  }
  
  if(each_sample == TRUE)
    p <- plot_div_sample(df, covar, ytitle, ...)
  else
    p <- plot_div_box(df, covar, ytitle, ...)
  
  return(p)
}

plot_div_box <- function(df, covar, ytitle, y_as_title = FALSE,
                         covar_cols = NULL,
                         group_df = NULL) {
  
  if (!is.null(group_df)) {
    group_df <- df %>%
      group_by(.data[[covar]]) %>%
      summarize(max = max(estimate)) %>%
      left_join(group_df, by = "treatment")
  }
  
  p <- ggplot(df) +
    aes(x = .data[[covar]],
        color = .data[[covar]],
        y = estimate) +
    geom_boxplot(outlier.shape = NA) +
    geom_jitter(width = 0.1, size = 1) +
    scale_y_continuous(labels = scales::comma) +
    labs(x = NULL, y = ytitle, color = covar) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank())
  
  if (!is.null(covar_cols)) p <- p + scale_color_manual(values = covar_cols)
  
  if (!is.null(group_df)) {
    p <- p +
      #ggnewscale::new_scale_color() +
      geom_text(data = group_df, size = 3, fontface = "bold",
                aes(x = .data[[covar]],
                    y = max * 1.1,
                    color = "grey30",
                    label = group)) #+
    #scale_color_brewer(palette = "Pastel1")
  }
  
  if (y_as_title == TRUE) {
    p <- p +
      theme(axis.title.y = element_blank(),
            plot.title = element_text(hjust = 0.5, size = 13)) +
      labs(title = ytitle)
  }
  
  return(p)
}

plot_div_sample <- function(df, covar, ytitle) {
  ## Make sure samples are sorted by treatment
  df <- df %>%
    arrange(.data[[covar]]) %>% 
    mutate(sampleID = fct_inorder(sampleID))
  
  ggplot(df) +
    aes(x = sampleID, color = treatment) +
    geom_point(aes(y = estimate)) +
    geom_errorbar(aes(ymax = estimate + error, ymin = estimate - error)) +
    scale_y_continuous(labels = scales::comma) +
    labs(x = NULL, y = ytitle) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank(),
          axis.text.x = element_text(angle = 270)) 
}

## Create DivNet diversity dataframe
get_divnet <- function(divnet_obj, meta, div_index) {
  left_join(meta,
            divnet_obj[[div_index]] %>% summary,
            by = c("sampleID" = "sample_names"))
}

## Create breakaway richness dataframe
get_break <- function(ps) {
  left_join(meta(ps),
            summary(breakaway(ps)),
            by = c("sampleID" = "sample_names")) %>%
    filter(!is.nan(upper), !is.nan(lower))
}

## Prep modelsummary table of DivNet model results
modtab_prep <- function(betta_res) {
  res_smr <- as.data.frame(betta_res$table) %>%
    rownames_to_column("term") %>%
    as_tibble()
  
  colnames(res_smr)[2:4] <- c("estimate", "std.error", "p.value")
  
  morestats <- data.frame(
    formula = format(betta_res$function.args$formula),
    logLik = betta_res$loglikelihood,
    AIC = betta_res$aic,
    AICc = betta_res$aicc
  ) %>%
    select(-AICc)
  
  modelsmr_list <- list(tidy = res_smr, glance = morestats)
  class(modelsmr_list) <- "modelsummary_list"
  
  return(modelsmr_list)
}

## Create modelsummary table of DivNet model results
modtab <- function(betta_res,
                   model_names = NULL,
                   fmt = 1, fontsize_pct = 100,
                   print_p = TRUE) {
  
  if (!is.null(betta_res$table)) modelsmr_list <- list(modtab_prep(betta_res))
  if (is.null(betta_res$table)) modelsmr_list <- map(betta_res, modtab_prep)
  
  names(modelsmr_list) <- model_names
  
  if (print_p == TRUE) {
    estim <- "{estimate} (se: {std.error}, p: {p.value}) {stars}"
  } else {
    estim <- "{estimate} (se: {std.error}, p: {p.value}) {stars}"
  }
  
  tab <- modelsummary(
    modelsmr_list,
    fmt = fmt,
    estimate = estim,
    statistic = NULL,
    coef_omit = "Intercept",
    output = "gt"
  )
  
  p_note <- ("  + p < 0.1 , * p < 0.05 , ** p < 0.01 , *** p < 0.001")
  
  tab %>%
    tab_footnote(footnote = p_note,
                 locations = cells_body(rows = 1, columns = 1)) %>%
    tab_options(table.font.size = pct(fontsize_pct))
}

mk_deseq <- function(counts, meta, design = "~1") {
  design <- as.formula(paste("~", design))
  dds <- DESeqDataSetFromMatrix(counts, meta, design = design)
}

run_deseq <- function(dds, tax, fac, lev1, lev2, thres = 0.1) {
  
  dds <- subset(dds, select = !is.na(colData(dds)[[fac]]))
  design(dds) <- as.formula(paste("~", fac))
  deseq_res <- DESeq(dds)
  
  res_raw <- results(deseq_res, contrast = c(fac, lev1, lev2)) %>%
    as.data.frame()  %>%
    filter(padj < thres)
  
  message("## Nr padj < ", thres, ": ", nrow(res_raw))
  
  res_raw %>% 
    merge(., tax, by.x = "row.names", by.y = "ID") %>%
    dplyr::rename(ID = Row.names, LFC = log2FoldChange) %>%
    dplyr::select(-stat, -pvalue, -lfcSE) %>%
    mutate(baseMean = round(baseMean, 2),
           LFC = round(LFC, 2),
           term = paste(lev1, "vs.", lev2)) %>%
    dplyr::select(-baseMean, -LFC) %>% 
    arrange(padj) %>%
    relocate(term)
}
