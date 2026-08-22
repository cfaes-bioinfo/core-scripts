
# GOSEQ PACKAGE FUNCTIONS ------------------------------------------------------
# This function will run the GO analysis 3 times for each contrast:
# for either DE direction, for LFC>0 DEGs only, and LFC<0 DEGs only.
# Then it will save the results in a TSV and print a summary.
rgoseq_all <- function(contrasts, DE_results, GO_map, gene_lens, ...) {
  
  # Either DE direction
  GO_ei <- map_dfr(.x = contrasts, .f = rgoseq,
                   DE_results = DE_results, gene_lens = gene_len_df, GO_map = GO_map,
                   DE_direction = "either", ...)
  
  # DE up (LFC>0)
  GO_up <- map_dfr(.x = contrasts, .f = rgoseq,
                   DE_results = DE_results, gene_lens = gene_len_df, GO_map = GO_map,
                   DE_direction = "up", ...)
  
  # DE down (LFC<0)
  GO_dn <- map_dfr(.x = contrasts, .f = rgoseq,
                   DE_results = DE_results, gene_lens = gene_len_df, GO_map = GO_map,
                   DE_direction = "down", ...)
  
  # Combine results for different DE directions
  GO_combined <- bind_rows(GO_ei, GO_up, GO_dn) |>
    mutate(DE_direction = factor(DE_direction, levels = c("either", "up", "down")))
  
  # Summarize the results
  smr <- GO_combined |>
    group_by(contrast, DE_direction) |>
    summarize(nsig = sum(sig), .groups = "drop") |>
    pivot_wider(id_cols = contrast, names_from = DE_direction, values_from = nsig)
  print(smr)
  
  return(GO_combined)
}

# GO analysis wrapper function
rgoseq <- function(
    contrast,                          # A DE contrast as specified in the 'contrast' column in the 'DE_results' df
    DE_results,                        # Df with DE results from DESeq2
    GO_map,                            # Df with one GOterm-to-gene relation per row, w/ columns 'gene' and 'go_term'
    gene_lens,                         # Df with gene lengths w/ columns 'gene' and 'length'
    DE_direction = "either",           # 'either' (= both together), 'up' (LFC>0), or 'down' (LFC>0)
    min_in_cat = 2, max_in_cat = Inf,  # Min. & max. nr of total terms in GO term
    min_DE_in_cat = 2,                 # Min. nr. DE genes in GO term for a term to be significant
    p_DE = 0.05,                       # Adj. p-value threshold for DE significance
    lfc_DE = 0,                        # LFC threshold for DE significance
    use_sig_column = NULL,             # Specify column in DE results with TRUE/FALSE indicating DE significance
    ontologies = c("BP", "MF", "CC"),  # GO ontologies to consider
    filter_no_descrip = TRUE,          # Remove GO categories with no description
    rm_padj_na = TRUE,                 # Whether to remove genes with NA for `padj`
    verbose = FALSE,
    ...
) {
  
  if (verbose == TRUE) {
    cat("\n-------------\nStarting analysis for contrast:", contrast, "\n")
  }
  
  DE_vec <- get_DE_vec(
    contrast,
    DE_results,
    DE_direction = DE_direction,
    rm_padj_na = rm_padj_na,
    verbose = verbose,
    use_sig_column = use_sig_column,
    ...
  )
  
  GO_df <- rgoseq_internal(
    contrast,
    DE_vec,
    GO_map,
    gene_lens,
    DE_direction,
    min_DE_in_cat = min_DE_in_cat,
    min_in_cat = min_in_cat,
    max_in_cat = max_in_cat,
    ontologies = ontologies,
    filter_no_descrip = filter_no_descrip,
    verbose = verbose
  )
  
  return(GO_df)
}

# Function to run a GO analysis with goseq
# (Helper function, use rgoseq to run the analysis)
rgoseq_internal <- function(
    contrast, DE_vec, GO_map, gene_lens,
    DE_direction = "either",
    min_in_cat = 2,
    max_in_cat = Inf,
    min_DE_in_cat = 2,
    ontologies = c("BP", "MF", "CC"),
    filter_no_descrip = TRUE,
    verbose = FALSE
) {
  
  if (verbose == TRUE) {
    message()
    message("rgoseq_internal function...")
    message("GO analysis settings:")
    message("   - min_in_cat: ", min_in_cat, "  // max_in_cat: ", max_in_cat)
    message("   - min_DE_in_cat: ", min_DE_in_cat)
    message("   - Ontologies: ", ontologies)
    message("   - Filter GO cats with no description: ", filter_no_descrip)
  }
  
  if (sum(DE_vec) >= 2) {
    # Remove rows from gene length df not in the DE_vec
    fgene_lens <- gene_lens |> dplyr::filter(gene %in% names(DE_vec))
    if (nrow(fgene_lens) == 0) stop("Error: no rows left in gene length df, gene IDs likely don't match!")
    
    n_removed <- nrow(gene_lens) - nrow(fgene_lens)
    if (verbose == TRUE) message("- Nr genes removed from gene length df (not in DE vector): ", n_removed)
    
    # Remove elements from DE_vec not among the gene lengths
    fDE_vec <- DE_vec[names(DE_vec) %in% fgene_lens$gene]
    if (length(fDE_vec) == 0) stop("Error: no entries left in DE vector, gene IDs likely don't match!")
    
    n_removed <- length(DE_vec) - length(fDE_vec)
    if (verbose == TRUE) message("- Nr genes removed from DE vector (not in gene length df): ", n_removed)
    if (verbose == TRUE) message("- Final length of DE vector: ", length(fDE_vec))
    
    # Check nr of genes with GO annotations
    ngenes_go <- length(intersect(GO_map$gene, names(fDE_vec)))
    if (verbose == TRUE) message("- Nr genes in DE vector with GO annotations: ", ngenes_go)
    
    # Check that gene lengths and contrast vector contain the same genes in the same order
    if (!all(fgene_lens$gene == names(fDE_vec))) {
      message("Gene IDs in gene length df do not match the gene IDs in the DE vector")
      message("IDs in gene length df:")
      print(head(fgene_lens$gene))
      message("IDs in DE vector:")
      print(head(names(fDE_vec)))
      stop()
    }
    
    # Probability weighting function based on gene lengths
    pwf <- nullp(DEgenes = fDE_vec,
                 bias.data = fgene_lens$length,
                 plot.fit = FALSE, genome = NULL, id = NULL)
    
    # Run GO test
    GO_df <- suppressMessages(
      goseq(pwf = pwf,
            gene2cat = GO_map,
            method = "Wallenius",
            use_genes_without_cat = FALSE)
    )
    
    # Process GO results
    GO_df <- GO_df |> dplyr::filter(n_DE_in_cat >= min_DE_in_cat)
    GO_df <- GO_df |> dplyr::filter(numInCat >= min_in_cat)
    GO_df <- GO_df |> dplyr::filter(numInCat <= max_in_cat)
    GO_df <- GO_df |> dplyr::filter(ontology %in% ontologies)
    if (filter_no_descrip == TRUE) GO_df <- GO_df |> dplyr::filter(!is.na(term))
    
    GO_df <- GO_df |>
      mutate(
        padj = p.adjust(over_represented_pvalue, method = "BH"),
        sig = ifelse(padj < 0.05 & n_DE_in_cat >= min_DE_in_cat, TRUE, FALSE),
        contrast = contrast,
        DE_direction = DE_direction
      ) |>
      dplyr::select(
        contrast, DE_direction,
        sig, p = over_represented_pvalue, padj,
        n_DE_in_cat, numInCat,
        term, ontology, description = term
      )
    
    cat(contrast,
        "  DE dir.:", DE_direction,
        "  Nr DEG:", sum(DE_vec),
        "  Nr GO cat:", nrow(GO_df),
        "  Nr sig.:", sum(GO_df$sig),
        "\n")
    
    return(GO_df)
    
  } else {
    cat(contrast,
        "  DE dir.:", DE_direction,
        "  Nr DEG:", sum(DE_vec),
        " -- skipping GO analysis\n")
  }
}

# Create named vector of DE genes (0s and 1s to indicate significance) for goseq analysis
# (Helper function, use rgoseq to run the analysis)
get_DE_vec <- function(
    contrast,                # Focal comparison (contrast)
    DE_results,                  # DE results df from DESeq2
    DE_direction = "either", # 'either' / 'up' / 'down'
    p_DE = 0.05,             # padj threshold for DE
    lfc_DE = 0,              # LFC threshold for DE
    use_sig_column = NULL,   # Use a column in the DE results with TRUE/FALSE indicating DE significance
    rm_padj_na = TRUE,       # Whether to remove genes with NA for `padj`
    verbose = FALSE
) {
  
  fcontrast <- contrast
  
  # If we use a column with precomputed DE significance, don't use thresholds
  if (!is.null(use_sig_column)) {
    if (verbose == TRUE) message("Using column ", use_sig_column, " to find DE genes")
    colnames(DE_results)[grep(use_sig_column, colnames(DE_results))] <- "isDE"
    p_DE <- NULL
    lfc_DE <- NULL
  }
  
  if (verbose == TRUE) {
    message("DE settings:")
    if (!is.null(p_DE)) message("    - DE p value: ", p_DE)
    if (!is.null(lfc_DE)) message("    - Min DE LFC: ", lfc_DE)
    message("    - Remove genes with NA as the adj. p-value: ", rm_padj_na)
  }
  
  # Create df for focal contrast
  fDE <- DE_results |> dplyr::filter(contrast == fcontrast) |> arrange(gene)
  
  # Check if genes are present multiple times -- this would indicate there are multiple contrasts
  if (any(duplicated(fDE$gene))) {
    stop("ERROR: Duplicated gene IDs detected -- there are probably multiple contrasts remaining in your input df")
  }
  
  # Indicate which genes are significant
  if (is.null(use_sig_column)) {
    if (lfc_DE != 0) {
      fDE <- fDE |>
        mutate(isDE = ifelse(padj < p_DE & abs(lfc) > lfc_DE, TRUE, FALSE))
    } else {
      fDE <- fDE |>
        mutate(isDE = ifelse(padj < p_DE, TRUE, FALSE))
    }
  }
  
  # Subset to up/down DEGs if needed
  if (DE_direction == "up")
    fDE <- fDE |> mutate(isDE = ifelse(lfc > 0, isDE, FALSE))
  if (DE_direction == "down")
    fDE <- fDE |> mutate(isDE = ifelse(lfc < 0, isDE, FALSE))
  
  # Report nr of genes
  n_genes <- length(unique(fDE$gene))
  if (verbose == TRUE) message("- Nr unique genes in DE results: ", n_genes)
  
  if (rm_padj_na == TRUE) {
    # Exclude genes with NA adj-p-val - those were not tested
    fDE <- fDE |> dplyr::filter(!is.na(padj))
    n_genes <- length(unique(fDE$gene))
    if (verbose == TRUE) message("- Nr unique genes after removing padj=NA: ", n_genes)
  } else {
    # Otherwise, turn NAs to FALSE (not DE)
    fDE <- fDE |> mutate(isDE = ifelse(is.na(isDE), FALSE, isDE))
  }
  
  DE_vec <- fDE$isDE
  names(DE_vec) <- fDE$gene
  
  if (verbose == TRUE) print(table(DE_vec))
  return(DE_vec)
}
