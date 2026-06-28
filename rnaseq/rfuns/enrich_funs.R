# Packages
if (!"tidyverse" %in% installed.packages()) install.packages("tidyverse")
if (!"ggforce" %in% installed.packages()) install.packages("ggforce")
if (!"colorspace" %in% installed.packages()) install.packages("colorspace")
if (!"BiocManager" %in% installed.packages()) install.packages("BiocManager")
if (!"clusterProfiler" %in% installed.packages()) BiocManager::install("clusterProfiler")
if (!"GO.db" %in% installed.packages()) BiocManager::install("GO.db")

# GO TERM FUNCTIONS ------------------------------------------------------------
# Get descriptions and ontologies (BP/MF/CC) for all GO terms 
get_GO_info <- function() {
  suppressPackageStartupMessages(library(GO.db))
  
  df <- AnnotationDbi::select(
    GO.db,
    columns = c("GOID", "TERM", "ONTOLOGY"),
    keys = keys(GO.db, keytype = "GOID"),
    keytype = "GOID"
  ) |>
    dplyr::rename(
      term = GOID,
      description = TERM,
      ontology = ONTOLOGY
    ) |>
    tibble()
  
  detach("package:GO.db", unload = TRUE)
  detach("package:AnnotationDbi", unload = TRUE)
  
  return(df)
}

# Get GO levels (currently only 1-3, the most generic ones)
get_GO_levels <- function() {
  suppressPackageStartupMessages(library(GO.db))
  
  # 1. Identify level 1 (The three root terms)
  lvl1_ids <- c("GO:0008150", "GO:0003674", "GO:0005575")
  
  # 2. Create a helper function to safely fetch children across all three sub-ontologies
  get_children <- function(go_ids) {
    # Query each ontology environment separately, returning NA if not found
    bp <- unname(unlist(mget(go_ids, GO.db::GOBPCHILDREN, ifnotfound = NA)))
    cc <- unname(unlist(mget(go_ids, GO.db::GOCCCHILDREN, ifnotfound = NA)))
    mf <- unname(unlist(mget(go_ids, GO.db::GOMFCHILDREN, ifnotfound = NA)))
    
    # Combine, drop NAs, and return unique IDs
    all_children <- c(bp, cc, mf)
    unique(all_children[!is.na(all_children)])
  }
  
  # 3. Extract lvl 2 and lvl 3 terms systematically
  lvl2_ids <- get_children(lvl1_ids)
  lvl3_ids <- get_children(lvl2_ids)
  
  # 4. Build the unified lookup table dataframe
  lvl_lookup <- tibble(GO_ID = unique(c(lvl1_ids, lvl2_ids, lvl3_ids))) |>
    mutate(GO_lvl = case_when(
      GO_ID %in% lvl1_ids ~ 1,
      GO_ID %in% lvl2_ids ~ 2,
      GO_ID %in% lvl3_ids ~ 3,
      TRUE ~ NA_real_
    ))
  
  return(lvl_lookup)
}


# CLUSTERPROFILER FUNCTIONS ----------------------------------------------------
# Function to run a (GO or KEGG) standard over-representation (ORA) analysis
run_ora <- function(
  df = NULL,                 # DE results df with at least columns 'gene', 'contrast', 'lfc'/'log2FoldChange', 'padj'.
                             # This df should contain *all* genes, not just significantly DE ones.
  contrast = NULL,           # DE comparison as specified in 'contrast' column in DE results
  DE_direction = "either",   # DE direction: 'either' (all DE genes), 'up' (lfc > 0), or 'down' (lfc < 0)
  focal_genes = NULL,
  term_map = NULL,           # Manually provide a functional category/term to gene mapping with columns:
                             # 1:term, 2:gene, and optionally 3:description, 4: ontology
  OrgDb = NULL,              # BioConductor OrgDB (alternative to 'term_map' for available organisms)
  ontology_type = NULL,      # 'GO' (enrichGO function) or 'KEGG' (enrichKEGG).
                             # Only applies when using an 'OrgDb' instead of a 'term_map'
  keyType = "ENTREZID",      # OrgDB gene ID type
                             # Only applies when using an 'OrgDb' instead of a 'term_map'
  GO_ontology = NULL,        # Only applies to GO analysis with an OrgDB *and* when return_df == TRUE (then, default is 'BP')
                             #   In all other cases, the function will always run GO analyses across all 3 ontologies (BP, CC, MF) 
  p_enrich = 0.05,           # Adjusted p-value threshold for enrichment
  q_enrich = 0.2,            # Q value threshold for enrichment
  min_DE_in_cat = 2,         # Nr. DE genes threshold for enrichment: at least this number of genes in the ontology category should be DE
                             #   (Occasionally, 'small' categories with 1 DE gene can have p-values below 0.05 -- this excludes those)
  min_cat_size = 5,          # Min. nr. of genes in a category (= clusterProfiler 'minGSSize' argument - NOTE: clusterProfiler default is 10)
  max_cat_size = 500,        # Min. nr. of genes in a category (= clusterProfiler 'maxGSSize' argument)
  filter_no_descrip = TRUE,  # Remove categories/terms with no description (at least for GO terms, these tend to be old/deprecated ones)
  exclude_nontested = TRUE,  # Exclude genes that weren't tested (i.e., have 'NA' in the 'padj' column) for DE from the 'universe' of genes
  universe = NULL,           # Manually specify a background 'universe' of genes (vector with gene IDs)
  allow_dups = FALSE,        # Allow a gene ID to be present multiple times in a (single-contrast, single DE-direction) list of DEGs
                             #   This should typically *not* be the case, but could be so when working with gene IDs (orthologs)
                             #   from another species than the focal species to run the GO analysis
  sig_only = NULL,           #   Return only significant results. Default: FALSE when return_df is FALSE, TRUE when return_df is TRUE. 
  simplify_terms = FALSE,    # Whether to use the clusterProfiler() simplify function to 'simplify'/filter the resulting list of significant GO terms by term similarity
  simplify_cutoff = 0.7,     # Simplify similarity cutoff
  return_df = FALSE          # Convert results object to a simple dataframe (tibble), instead of keeping the ClusterProfiler object
                             #   Should be FALSE if you want to use the enrichPlot functions directly 
) {

  init_df <- df
  GO_ontologies <- c("BP", "MF", "CC")
  
  if (is.null(focal_genes)) {
    # Check for name of lfc column, and presence of isDE column
    if ("log2FoldChange" %in% colnames(df) & !"lfc" %in% colnames(df)) {
      df <- df |> dplyr::rename(lfc = log2FoldChange)
    }
    if (!"isDE" %in% colnames(df)) {
      df <- df |> mutate(isDE = ifelse(padj < 0.05, TRUE, FALSE))
    }
    
    # Filter DE results to only get those for the focal contrast
    fcontrast <- contrast
    df <- df |> dplyr::filter(contrast == fcontrast)
    stopifnot("ERROR: no rows in DE results dataframe after contrast filtering" = nrow(df) > 0)
    
    # Filter the DE results, if needed: only take over- or under-expressed
    if (DE_direction == "up") df <- df |> dplyr::filter(lfc > 0)
    if (DE_direction == "down") df <- df |> dplyr::filter(lfc < 0)
    
    # Create a vector with DEGs
    focal_genes <- df |> dplyr::filter(isDE) |> pull(gene)
  } else {
    fcontrast <- contrast
    DE_direction <- "NA"
  }
  
  # Check if genes are present multiple times -- this would indicate there are multiple contrasts
  if (any(duplicated(focal_genes))) {
    if (allow_dups) focal_genes <- unique(focal_genes)
    if (!allow_dups) stop("Found duplicated gene IDs: you probably have multiple 'contrasts' in your input df")
  }
  
  # Prepare the term map
  if (!is.null(term_map)) {
    # Rename term_map columns
    colnames(term_map)[1:2] <- c("term", "gene")
    if (ncol(term_map) > 2) colnames(term_map)[3] <- "description"
    if (ncol(term_map) > 3) colnames(term_map)[4] <- "ontology"
    
    # Prep term mappings - term-to-gene
    term2gene <- term_map |> dplyr::select(term, gene)
  
    # Prep term mappings - term-to-name (description)
    if (ncol(term_map) > 2) {
      term2name <- term_map |> dplyr::select(term, description)
      if (filter_no_descrip == TRUE) {
        n_before <- length(unique(term2name$term))
        term2name <- term2name[!is.na(term2name$description), ]
        n_removed <- n_before - length(unique(term2name$term))
        if (n_removed > 0) message("Note: removed ", n_removed, " terms with no description")
      }
    } else {
      term2name <- NA
    }
  
    # Get the background 'universe' of genes:
    # genes that were tested for DE *and* occur in the ontology term map
    # (Excluding the latter is equivalent to goseq's 'use_genes_without_cat=FALSE',
    # and this is done by default by ClusterProfiler -- but non-tested genes *are* included)
    if (!is.null(universe)) {
      univ_vec <- universe[universe %in% term_map$gene]
    } else if (exclude_nontested == TRUE) {
      univ_df <- init_df |> dplyr::filter(!is.na(padj))
      if (!is.null(term_map)) univ_df <- univ_df |> dplyr::filter(gene %in% term_map$gene)
      univ_vec <- unique(univ_df$gene)
    } else {
      univ_vec <- NULL
    }
    
    # Check nr of DE genes in the term map
    genes_in_map <- focal_genes[focal_genes %in% term2gene$gene]
    
    # Report
    cat(
      "Contrast: ", fcontrast,
      " // DE direction: ",
      DE_direction,
      " // DEGs (w/ term): ",
      length(focal_genes),
      " (",
      length(genes_in_map),
      ")",
      " // background genes w/ term: ",
      length(univ_vec),
      sep = ""
    )
    
    # Skip the enrichment analysis if there are too few genes
    if (length(focal_genes) <= 1) {
      message(" // Skipping enrichment analysis: only 1 or 0 DEGs\n")
      return(NULL)
    }
    if (length(genes_in_map) == 0) {
      message("WARNING: None of the DE genes are in the GO/KEGG term dataframe ('term_map')")
      cat("First gene IDs from DE results: ", head(focal_genes), "\n")
      cat("First gene IDs from term_map: ", head(term2gene$gene), "\n")
      cat("Skipping enrichment analysis...\n")
      return(NULL)
    }
    
  } else {
    cat(
      "Contrast: ", fcontrast,
      " // DE direction: ", DE_direction,
      " // Nr DE genes: ", length(focal_genes),
      sep = ""
      )
  }
  
  # Skip the enrichment analysis if there are too few genes
  if (length(focal_genes) <= 1) {
    message("// Skipping enrichment analysis: 1 or 0 DEGs\n")
    return(NULL)
  }

  # Run the enrichment analysis
  if (!is.null(term_map)) {
    # With manual term map
    res <- enricher(
      gene = focal_genes,
      TERM2GENE = term2gene,
      TERM2NAME = term2name,
      universe = univ_vec,
      minGSSize = min_cat_size,
      maxGSSize = max_cat_size,
      pAdjustMethod = "BH",
      pvalueCutoff = 1,
      qvalueCutoff = 1
      )
    if (simplify_terms == TRUE && !is.null(res) && nrow(res) > 0) {
      if ("ontology" %in% colnames(term_map)) {
        ont_lookup <- term_map |>
          dplyr::select(term, ontology) |>
          dplyr::distinct(term, .keep_all = TRUE)
        res_df <- res@result |>
          dplyr::left_join(ont_lookup, by = c("ID" = "term")) |>
          dplyr::filter(p.adjust < p_enrich)
        ontologies <- unique(res_df$ontology[!is.na(res_df$ontology)])
        simplified_rows <- lapply(ontologies, function(ont) {
          rows <- res_df |> dplyr::filter(ontology == ont)
          if (nrow(rows) == 0) return(NULL)
          semData <- GOSemSim::godata(ont = ont, computeIC = FALSE)
          clusterProfiler:::simplify_internal(
            rows, cutoff = simplify_cutoff, measure = "Wang",
            ontology = ont, semData = semData
          )
        })
        keep_ids <- do.call(rbind, simplified_rows)$ID
        cat(" // simplified:", nrow(res_df), "->", length(keep_ids), "terms")
        res@result <- res@result |> dplyr::filter(ID %in% keep_ids)
      }
    }
  } else if (ontology_type == "GO") {
    
    # GO with OrgDB
    if (is.null(GO_ontology)) GO_ontology <- "BP"
    enrichfun <- function(GO_ontology) {
      enrichGO(
        gene = focal_genes,
        OrgDb = OrgDb,
        keyType = keyType,
        universe = univ_vec,
        ont = GO_ontology,
        minGSSize = min_cat_size,
        maxGSSize = max_cat_size,
        pAdjustMethod = "BH",
        pvalueCutoff = 1,
        qvalueCutoff = 1
      )
    }
    
    if (return_df == FALSE) {
      # If keeping the ClusterProfiler format, can't combine multiple results
      res <- enrichfun(GO_ontology = GO_ontology)
      if (simplify_terms == TRUE) {
        res@ontology <- GO_ontology
        simplify(res, cutoff = simplify_cutoff)
      } 
      
    } else {
      if (simplify_terms == FALSE) {
        # If converting to a df, iterate over the GO ontologies
        res <- map_dfr(GO_ontologies, function(x) {
          as_tibble(enrichfun(x)) |> mutate(ontology = x)
        })
      } else {
        res <- map_dfr(GO_ontologies, function(x) {
          rr <- as_tibble(enrichfun(x)) |> mutate(ontology = x)
          rr@ontology <- x
          simplify(rr, cutoff = simplify_cutoff)
        })
      }
    }
    
  }
  
  # ClusterProfiler may return NULL result for small sets
  if (is.null(res)) return(NULL)
  
  # Process the output
  if (return_df == FALSE) {
    
    res_sig <- res |>
      dplyr::filter(
        p.adjust < p_enrich,
        qvalue < q_enrich,
        Count >= min_DE_in_cat
      )
    
    if (is.null(sig_only)) sig_only <- TRUE
    if (sig_only == TRUE) res <- res_sig
    cat(" // enriched terms:", nrow(res_sig), "\n")
    
  } else {
    
    if (is.null(sig_only)) sig_only <- FALSE
    
    # Create a regular df
    res <- as_tibble(res) |>
      mutate(
        sig = ifelse(
          p.adjust < p_enrich & qvalue < q_enrich & Count >= min_DE_in_cat,
          TRUE,
          FALSE
        ),
        contrast = fcontrast,
        DE_direction = DE_direction
        ) |>
      dplyr::select(
        contrast, DE_direction, term = ID, n_focal_in_cat = Count,
        GeneRatio, BgRatio, padj = p.adjust, sig,
        description = Description, any_of("ontology"), gene_ids = geneID
        )
    
    # Add ontology info for GO
    if ("ontology" %in% colnames(term_map)) {
      res <- term_map |>
        dplyr::select(term, ontology) |>
        distinct(term, .keep_all = TRUE) |> 
        right_join(res, by = "term") |>
        relocate(ontology, .before = "gene_ids")
    }
    
    # Add mean & median LFC value
    if (!is.null(df)) {
      w_lfc <- res |>
        separate_longer_delim(cols = gene_ids, delim = "/") |>
        left_join(
          dplyr::select(df, gene, lfc),
          by = join_by("gene_ids" == "gene"),
          relationship = "many-to-many"
          ) |>
        summarize(
          mean_lfc = mean(lfc),
          median_lfc = median(lfc),
          .by = c("term", "contrast", "DE_direction")
          )
      res <- left_join(res, w_lfc, by = c("term", "contrast", "DE_direction"))
    }
    
    # Add gene numbers and enrichment ratio
    res <- res |>
      separate_wider_delim(
        cols = c("GeneRatio", "BgRatio"), delim = "/", names_sep = "_"
      ) |>
      mutate(
        # Total nr of DE genes (in+not in the focal term)
        n_focal = as.integer(GeneRatio_2),
        # Total nr of genes in the functional term
        n_cat = as.integer(BgRatio_1),
        # Total nr of genes tested
        n_total = as.integer(BgRatio_2)
        ) |>
      dplyr::select(-GeneRatio_1, -GeneRatio_2, -BgRatio_1, -BgRatio_2) |>
      mutate(fold_enrich = (n_focal_in_cat / n_focal) / (n_cat / n_total))
    
    # Report
    cat(" // enriched terms:", sum(res$sig), "\n")
  }
  
  return(res)
}

# Function to run a Gene Set Enrichment Analysis (gsea)
run_gsea <- function(
    df,                       # Differential expression results, should at least have columns 'contrast', 'gene', 'lfc'
    contrast,                 # Contrast ID, should be one of the values in column 'contrast' in df
    term_map = NULL,          # Gene-to-term map (e.g., GO or KEGG)
                              # Either 'term_map' (use 'manual' lookup table) or OrgDB (use BioC lookup table) is required
    OrgDb = NULL,             # BioConductor OrgDB (alternative to 'term_map' for available organisms)
    keyType = "ENTREZID",     # OrgDB gene ID type
    ontology_type = NULL,     # 'GO' (enrichGO function) or 'KEGG' (enrichKEGG).
                              # Only applies when using an 'OrgDb' instead of a 'term_map'
    GO_ontology = NULL,       # Only for GO analysis with an OrgDB *and* when return_df == TRUE (then, default is 'BP')
                              # In all other cases, will run GO analyses across all 3 ontologies (BP, CC, MF)
                              # (The reason this applies for GO with OrgDB & keeping the ClusterProfiler format is that
                              #  ClusterProfiler will return an error when trying to run enrichGO with all ontologies at once)
    p_enrich = 0.05,          # Adj. p-value threshold for enrichment
    allow_dups = FALSE,       # Allow a gene ID to be present multiple times in a (single-contrast, single DE-direction) list of DEGs
                              # This should typically *not* be the case, but could be so when working with gene IDs (orthologs)
                              # from another species than the focal species to run the GO analysis.
                              # NOTE: This will compute the mean LFC across duplicated genes!
    return_df = FALSE         # Convert results object to a simple dataframe (tibble)
  ) {
  
  # Check for name of lfc column, and presence of isDE column
  if ("log2FoldChange" %in% colnames(df) & ! "lfc" %in% colnames(df)) {
    df <- df |> dplyr::rename(lfc = log2FoldChange)
  }
  
  # Prep the df to later create a gene vector
  fcontrast <- contrast
  gene_df <- df |>
    dplyr::filter(contrast == fcontrast, !is.na(lfc)) |>
    arrange(desc(lfc))
  stopifnot("Error: no rows in DE results dataframe after contrast filtering" = nrow(gene_df) > 0)
  n_DE <- sum(gene_df$padj < 0.05, na.rm = TRUE)
  
  # Check if genes are present multiple times -- this would indicate there are multiple contrasts
  if (any(duplicated(gene_df$gene))) {
    # NOTE: This will compute the mean LFC across duplicated genes!
    if (allow_dups) {
        gene_df <- gene_df |>
          summarize(lfc = mean(lfc), .by = gene) |>
          arrange(desc(lfc))
    } else {
      stop("Found duplicated gene IDs: you probably have multiple 'contrasts' in your input df")
    }
  }
  
  # Create a vector with lfc's and gene IDs
  lfc_vec <- gene_df$lfc
  names(lfc_vec) <- gene_df$gene
  
  # Prepare the functional term map and report
  if (!is.null(term_map)) {
    # Rename term_map columns
    colnames(term_map)[1:2] <- c("term", "gene")
    if(ncol(term_map) > 2) colnames(term_map)[3] <- "description"
    if(ncol(term_map) > 3) colnames(term_map)[4] <- "ontology"
    
    # Prep term mappings - if there's a third column, make a term2name df as well
    term2gene <- term_map[, 1:2]
    term2name <- NA
    if (ncol(term_map) > 2) term2name <- term_map[, c(1, 3)]
    
    # Check & report
    genes_in_map <- names(lfc_vec)[names(lfc_vec) %in% term2gene[[2]]]
    cat("Contrast: ", fcontrast, " // Nr genes with term assigned: ",
        length(genes_in_map), sep = "")

    if (length(genes_in_map) == 0) {
      message("\nERROR: None of the genes are in the term_map dataframe")
      cat("First gene IDs from DE results: ", head(names(lfc_vec)), "\n")
      cat("First gene IDs from term_map: ", head(term2gene[[2]]), "\n")
      stop()
    }
  } else {
    cat("Contrast:", fcontrast)
  }
  
  # Set random seed if it doesn't exist
  if (!exists(".Random.seed")) {
    message("Note: no random seed set, setting seed to 1 with `set.seed(1)`")
    set.seed(1)
  }
  
  # Run the enrichment analysis
  if (!is.null(term_map)) {
    gsea_res <- GSEA(
      geneList = lfc_vec,
      TERM2GENE = term2gene,
      TERM2NAME = term2name,
      pvalueCutoff = 1,
      pAdjustMethod = "BH",
      verbose = FALSE,
      eps = 0,
      seed = TRUE
      )
  } else {
    gsea_res <- gseGO(
      geneList = lfc_vec,
      ont = "ALL",
      OrgDb = OrgDb,
      keyType = keyType,
      pvalueCutoff = 1,
      pAdjustMethod = "BH",
      verbose = FALSE,
      eps = 0,
      seed = TRUE
    )
  }
  
  # Report
  n_sig <- sum(gsea_res$p.adjust < p_enrich)
  cat(" // Nr enriched:", n_sig, "\n")
  
  # Return a df, if requested
  if (return_df == FALSE) {
    gsea_res <- gsea_res |> dplyr::filter(p.adjust < p_enrich)
  } else {
    # Convert to a df
    gsea_res <- as_tibble(gsea_res)
    if("ONTOLOGY" %in% colnames(gsea_res))
        gsea_res <- gsea_res |> rename(ontology = ONTOLOGY)
    gsea_res <- gsea_res |> 
      mutate(sig = ifelse(p.adjust < p_enrich, TRUE, FALSE),
             contrast = fcontrast) |>
      dplyr::select(contrast, term = ID, padj = p.adjust,
                    sig, description = Description, any_of("ontology"),
                    gene_ids = core_enrichment)
    
    # Add GO info
    if ("ontology" %in% colnames(term_map)) {
      gsea_res <- term_map |>
        dplyr::select(term, ontology) |>
        distinct(term, .keep_all = TRUE) |> 
        right_join(gsea_res, by = "term") |>
        relocate(ontology, .before = "gene_ids")
    }
    
    # Add mean & median LFC value
    w_lfc <- gsea_res |>
      separate_longer_delim(cols = gene_ids, delim = "/") |>
      rename(gene = gene_ids) |> 
      left_join(df |> dplyr::select(gene, contrast, lfc),
                by = c("gene", "contrast"),
                relationship = "many-to-many") |>
      summarize(mean_lfc = mean(lfc),
                median_lfc = median(lfc),
                .by = c("term", "contrast"))
    
    gsea_res <- left_join(gsea_res, w_lfc, by = c("term", "contrast"))
  }

  return(gsea_res)
}


# PLOTTING FUNCTIONS -----------------------------------------------------------
# Function to plot the enrichment results in a heatmap format
tileplot <- function(
  enrich_df,                    # Enrichment results
  contrasts = NULL,             # One or more contrasts (default: all)
  DE_directions = NULL,         # One or more DE directions (default: all)
  x_var = "contrast",           # Column in enrich_df to plot along the x-axis
  fill_var = "padj_log",        # Column in enrich_df to vary fill color by
                                # (the default, padj_log, will be computed from padj)
  facet_var1 = NULL,            # Column in enrich_df to facet by
  facet_var2 = NULL,            # Second column in enrich_df to facet by
                                # When specifiying both facet_var1 and var2: var1=>rows, var2=>columns
  countlab = TRUE,              # Print nrDEInCat genes in the box
  countlab_size = 2,            # Size of nrDEInCat label in the box
  xlabs = NULL,                 # Manually provide a vector with x-axis labels
  xlab_size = 13,               # Size of x-axis labels
  ylab_size = 10,               # Size of y-axis labels (= categories)
  xlab_angle = 0,               # Angle of x-axis labels
  facet_labeller = "label_value", # Facet labeling
  add_term_id = FALSE,          # Add ontology term ID to its name/description
  merge_directions = FALSE      # Whether to 'merge' up+down DE directions into a single cell
                                # If both directions are significant, will show the most significant one
) {
  
  # Check
  if (is.null(facet_var1) && !is.null(facet_var2)) {
    stop("ERROR: Only use facet_var2 when also using facet_var1")
  }
  
  # For GSEA, the following columns will be missing
  if (! "DE_direction" %in% colnames(enrich_df)) enrich_df$DE_direction <- NA
  if (! "n_focal_in_cat" %in% colnames(enrich_df)) enrich_df$n_focal_in_cat <- NA
  if (! "fold_enrich" %in% colnames(enrich_df)) enrich_df$fold_enrich <- NA
  if (! "n_DE" %in% colnames(enrich_df)) enrich_df$n_DE <- NA
  
  # Select contrasts & DE directions
  if (is.null(contrasts)) contrasts <- unique(enrich_df$contrast)
  if (is.null(DE_directions)) DE_directions <- unique(enrich_df$DE_direction)
  
  # Prep the df
  enrich_df <- enrich_df |>
    dplyr::filter(contrast %in% contrasts,
                  DE_direction %in% DE_directions) |>
    mutate(n_focal_in_cat = ifelse(padj >= 0.05, NA, n_focal_in_cat),
           contrast = sub("padj_", "", contrast),
           fold_enrich = ifelse(sig == FALSE, NA, fold_enrich),
           mean_lfc = ifelse(sig == FALSE, NA, mean_lfc),
           median_lfc = ifelse(sig == FALSE, NA, median_lfc),
           n_DE = ifelse(sig == FALSE, NA, n_DE),
           padj = ifelse(sig == FALSE, NA, padj),
           padj_log = -log10(padj)) %>%
    # Only take GO categories with at least one significant contrast (as pre-specified in 'sig' column)
    dplyr::filter(term %in% (dplyr::filter(., sig == TRUE) |> pull(term))) %>%
    # Only take contrasts with at least one significant term
    dplyr::filter(contrast %in% (dplyr::filter(., sig == TRUE) |> pull(contrast))) |>
    arrange(padj_log)
  
  # Modify the ontology term description
  trunc_width <- 40
  enrich_df <- enrich_df |>
    mutate(
      # Capitalize the first letter
      description = paste0(toupper(substr(description, 1, 1)),
                           substr(description, 2, nchar(description))),
      # If there is no description, use the term ID
      description = ifelse(is.na(description), term, description)
    )
  if (add_term_id) {
    enrich_df <- enrich_df |>
      mutate(description = paste0(term, " - ", description))
    trunc_width <- 50
  }
  enrich_df <- enrich_df |>
    mutate(description = str_trunc(description, width = trunc_width))
  
  # Make sure all combinations of contrast, DE_dir, and GO cat. are present
  # A) Make a lookup table with GO terms
  go_lookup <- enrich_df |>
    dplyr::select(any_of(c("term", "ontology", "description"))) |>
    distinct()
  # B) Make a df with all possible combinations of contrast, DE_dir, and GO cat.
  enrich_rows <- enrich_df |>
    dplyr::select(contrast, DE_direction, term) |>
    complete(contrast, DE_direction, term) |>
    left_join(go_lookup, by = c("term"))
  # C) Merge this with the enrich_df
  enrich_df <- left_join(enrich_rows,
                         enrich_df |> dplyr::select(-(any_of(c("ontology", "description")))),
                         by = c("contrast", "DE_direction", "term"),
                         multiple = "all") |>
    mutate(sig = ifelse(is.na(sig), FALSE, sig))
  
  # Merge across DE directions
  if (!"DE_direction" %in% c(x_var, facet_var1, facet_var2)) {
    message("Merging DE directions (showing only most significant)
             because DE direction is not included in any plotting variable")
    merge_directions <- TRUE
  }
  if (merge_directions) {
    enrich_df <- enrich_df |>
      group_by(term, contrast) |>
      arrange(padj, .by_group = TRUE) |>
      slice_head(n = 1)
  }
  
  # Legend title with subscript
  if (fill_var == "padj_log") {
    fill_name <- expression("-Log"[10]*" P")
  } else if (fill_var == "median_lfc") {
    fill_name <- expression(paste("Median log"[2]*"-fold change"))
  } else if (fill_var == "mean_lfc") {
    fill_name <- expression(paste("Mean log"[2]*"-fold change"))
  } else {
    fill_name <- fill_var
  }
  
  # X-label position
  if (is.null(facet_var1)) xlab_pos <- "top" else xlab_pos <- "bottom" 
  
  # Color scale
  if (fill_var %in% c("mean_lfc", "median_lfc")) {
    col_scale <- colorspace::scale_fill_continuous_divergingx(
      palette = "Tropic", mid = 0.0, na.value = "grey98", rev = TRUE
      #https://stackoverflow.com/questions/58718527/setting-midpoint-for-continuous-diverging-color-scale-on-a-heatmap
      )
  } else {
    col_scale <- scale_fill_viridis_c(option = "D", na.value = "grey97")
  }
  
  # Make the plot
  p <- ggplot(enrich_df) +
    aes(x = .data[[x_var]],
        y = description,
        fill = .data[[fill_var]]) +
    geom_tile(stat = "identity", linewidth = 0.25, color = "grey80") +
    col_scale +
    scale_x_discrete(position = xlab_pos) +
    scale_y_discrete(position = "right") +
    labs(fill = fill_name) +
    theme_minimal() +
    theme(legend.position = "left",
          panel.grid = element_blank(),
          axis.title = element_blank(),
          axis.text.x = element_text(size = xlab_size, angle = xlab_angle),
          axis.text.y = element_text(size = ylab_size),
          strip.text = element_text(face = "bold"),
          plot.title = element_text(hjust = 0.5))
  
  # Add x-axis label
  if (!is.null(xlabs)) p <- p + scale_x_discrete(labels = xlabs)
  
  # Add a count of the nr of DE genes in each term
  if (countlab == TRUE) {
    p <- p + suppressWarnings(
      geom_label(aes(label = n_focal_in_cat), fill = "grey95", size = countlab_size)
      )
  }
  
  # Faceting
  if (!is.null(facet_var1)) {
    if (!is.null(facet_var2)) {
      # Facet_grid when there are 2 facet vars
      p <- p + facet_grid(rows = vars(.data[[facet_var1]]),
                          cols = vars(.data[[facet_var2]]),
                          scales = "free",
                          space = "free_y",
                          switch = "y",
                          labeller = facet_labeller)
    } else {
      if (facet_var1 != "ontology") {
        p <- p +
          ggforce::facet_row(facets = vars(.data[[facet_var1]]),
                             scales = "free_x",
                             space = "free")
      } else {
        p <- p +
          ggforce::facet_col(facets = vars(.data[[facet_var1]]),
                             scales = "free_y",
                             space = "free")
      }
    }
  }
  
  return(p)
}

# Cleveland dotplot of enrichment results
cdotplot <- function(
    df,                         # Dataframe with enrichment results from run_enrich()
    contrasts = NULL,           # One or more contrasts (default: all)
    DE_dirs = NULL,             # One or more DE directions (default: all)
    x_var = "padj_log",         # Column in df to plot along the x axis ('padj_log' will be computed from 'padj')
    fill_var = "median_lfc",    # Column in df to vary fill color by ('padj_log' will be computed from 'padj')
    label_var = "n_focal_in_cat",  # Column in df with a number to add as a label in the circles
    facet_var1 = NULL,          # Column in df to facet by
    facet_var2 = NULL,          # Second column in df to facet by (e.g. 'ontology' for GO)
    facet_to_columns = TRUE,    # When only using one facet_var1, facets are columns (or rows)
    facet_scales = NULL,        # Facet scales: 'fixed', 'free', 'free_x', or 'free_y'
    facet_label_fun = "label_value", # Function to label facets with
    x_title = NULL,             # X-axis title
    ylab_size = 11,             # Size of y-axis labels (= term labels)
    add_term_id = FALSE,        # Add term ID (e.g., 'GO:009539') to its description
    point_size = 6,
    label_chars = 40            # Truncate the term labels to this many character (+10 when including the term ID)
) {
  
  # Constants
  y_var <- "term"
  
  # Select contrasts & DE directions
  if (is.null(contrasts)) contrasts <- unique(df$contrast)
  
  # Prep the df
  df <- df |>
    dplyr::filter(sig == TRUE, contrast %in% contrasts) |>
    mutate(padj_log = -log10(padj))
  if (!is.null(DE_dirs)) df <- df |> dplyr::filter(DE_direction %in% DE_dirs)
  
  # Modify the term description
  df <- df |>
    mutate(
      # Capitalize the first letter
      description = paste0(
        toupper(substr(description, 1, 1)),
        substr(description, 2, nchar(description))
        ),
      # If there is no description, use the term ID
      description = ifelse(is.na(description), term, description)
    )
  if (add_term_id == TRUE) {
    df <- df |> mutate(description = paste0(term, " - ", description))
    label_chars <- label_chars + 10
  }
  df <- df |> mutate(description = str_trunc(description, width = label_chars))
  
  # Create a label lookup for the term description
  # The problem is that abbreviated terms could be non-unique!
  label_df <- df |> distinct(term, .keep_all = TRUE) |> select(term, description)
  label_lookup_vec <- label_df$description
  names(label_lookup_vec) <- label_df$term
  
  # Legend position and title
  if (x_var == fill_var) legend_pos <- "none" else legend_pos <- "top"
  if (fill_var == "median_lfc") {
    color_name <- expression(paste("Median log"[2]*"-fold change"))
  } else if (fill_var == "mean_lfc") {
    color_name <- expression(paste("Mean log"[2]*"-fold change"))
  } else if (fill_var == "padj_log") {
    color_name <- expression("-Log"[10]*" P")
  } else {
    color_name <- fill_var
  }
  
  # X-axis title
  if (x_var == "padj_log") {
    x_title <- expression("-Log"[10]*" P")
  } else if (x_var == "padj") {
    x_title <- "Adjusted p-value"
  } else if (x_var == "fold_enrich") {
    x_title <- "Fold enrichment"
  } else if (x_var == "median_lfc") {
    x_title <- expression(paste("Median log"[2]*"-fold change"))
  } else if (fill_var == "mean_lfc") {
    x_title <- expression(paste("Mean log"[2]*"-fold change"))
  } 
  
  # Color scale - https://carto.com/carto-colors/
  if (fill_var %in% c("mean_lfc", "median_lfc")) {
    col_scale <- colorspace::scale_color_continuous_divergingx(
      palette = "Tropic",
      mid = 0.0,
      na.value = "grey97",
      name = color_name,
      rev = TRUE
    )
  } else if (class(df[[fill_var]]) == "numeric") {
    col_scale <- scale_color_viridis_c(
      option = "D",
      na.value = "grey95",
      name = color_name,
      )
  } else {
    col_scale <- scale_color_brewer(palette = "Dark2")
  }
  
  # X-axis left-hand expansion
  if (x_var %in% c("padj_log", "fold_enrich")) {
    expand_min <- 0
  } else {
    expand_min <- 0.09
  }
  
  # Create the base plot
  p <- ggpubr::ggdotchart(
    df,
    x = y_var,
    y = x_var,
    label = label_var,
    color = fill_var,
    sorting = "none",             # Sort value in descending order
    add = "segments",             # Add segments from y = 0 to dots
    rotate = TRUE,                # Rotate vertically
    dot.size = point_size,
    font.label = list(color = "white", size = point_size + 2, vjust = 0.5),
    ggtheme = theme_bw()
  )
  
  # Formatting
  p <- p +
    scale_x_discrete(labels = label_lookup_vec) +
    scale_y_continuous(expand = expansion(mult = c(expand_min, 0.09))) +
    col_scale +
    labs(x = NULL) +
    theme(
      legend.position = legend_pos,
      plot.margin = margin(0.5, 0.5, 0.5, 0.5, unit = "cm"),
      strip.text.y = element_text(angle = 270, face = "bold"),
      strip.placement = "outside",
      axis.title.x = element_text(
        size = 12,
        margin = margin(t = 0.5, b = 0.5, unit = "cm")
      ),
      axis.title.y = element_blank(),
      axis.text.x = element_text(size = 10),
      axis.text.y = element_text(size = ylab_size),
      panel.grid.major = element_blank(),
      panel.grid.minor.x = element_blank()
    )
  
  # Other formatting
  if (!is.null(x_title)) p <- p + labs(y = x_title)
  
  # Vertical lines at 0
  if (x_var %in% c("mean_lfc", "median_lfc", "fold_enrich")) {
    p <- p + geom_hline(yintercept = 0, color = "grey70", linewidth = 1)
    
    # Find the hline layer and move it to the beginning
    hline_idx <- which(sapply(p$layers, function(x) inherits(x$geom, "GeomHline")))
    if (length(hline_idx) > 0) {
      p$layers <- c(p$layers[hline_idx], p$layers[-hline_idx])
    }
  }
  
  # Faceting
  if (!is.null(facet_var1)) {
    if (!is.null(facet_var2)) {
      
      # With 2 faceting variables, use facet_grid()
      if (is.null(facet_scales)) facet_scales <- "free_y"
      p <- p +
        facet_grid(
          rows = vars(.data[[facet_var1]]),
          cols = vars(.data[[facet_var2]]),
          scales = facet_scales,
          space = "free_y",
          labeller = facet_label_fun
          )
    } else if (facet_to_columns) {
      
      # 1 faceting variable default: facet into columns with facet_row()
      if (is.null(facet_scales)) facet_scales <- "free_x"
      p <- p +
        ggforce::facet_row(
          facets = vars(.data[[facet_var1]]),
          scales = facet_scales,
          space = "free",
          labeller = facet_label_fun
          )
    } else {
      
      # 1 faceting variable alternative: facet into rows with facet_col()
      if (is.null(facet_scales)) facet_scales <- "free_y"
      p <- p +
        ggforce::facet_col(
          facets = vars(.data[[facet_var1]]),
          scales = facet_scales,
          space = "free",
          labeller = facet_label_fun
          )
    }
  }

  return(p)
}

# Heatmap for DE genes in significant GO terms
# NOTE: This function requires (calls) the pheat() function from mcic-scripts/rnaseq/DE_funs.R
GO_pheat <- function(
    GO_cat,                    # GO term to plot
    GO_res,                    # GO results from run_enrich() or run_gsea() with return_df=TRUE
    count_mat,                 # Normalized GO matrix
    meta_df,                   # Metadata df
    annot_df = NULL,           # Annotation df: gene IDs as rownames, gene names/descriptions as the single column
    contrast = NULL,           # DE contrast as specified in 'contrast' column in GO_res 
    DE_direction = "either",   # Direction of DE ('either', 'up', or 'down')
    nchar_gene = 30,           # Max. nr. of characters for the gene name/description
    ...                        # Other args to pass to pheat()
    ) {
  
  # Rename before filtering
  fcontrast <- contrast
  DE_dir <- DE_direction
  
  # Filter the GO results
  fgo <- GO_res |> dplyr::filter(term == GO_cat)
  if (!is.null(DE_direction)) fgo <- fgo |> dplyr::filter(DE_direction == DE_dir)
  if (!is.null(fcontrast)) fgo <- fgo |> dplyr::filter(contrast == fcontrast)
  
  # Get a vector with gene IDs
  fgenes <- fgo |> separate_longer_delim(cols = gene_ids, delim = "/") |> pull(gene_ids)
  
  # Report
  message("GO term: ", GO_cat, " (", length(fgenes), " DE genes)")
  
  # Prepare the title
  descrip <- fgo$description[1]
  p <- formatC(fgo$padj, format = "e", digits = 1)
  title <- paste0(GO_cat, " (", descrip, ")\n(DEGs in ", fcontrast, ", enrich-p=", p, ")")
  
  # Make the heatmap
  p <- pheat(genes = fgenes,
             count_mat = count_mat,
             meta_df = meta_df,
             annot_df = annot_df,
             nchar_gene = nchar_gene,
             main = title,
             ...)
  print(p)
}
