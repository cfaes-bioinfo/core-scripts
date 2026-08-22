# Packages
if (!require("DT")) install.packages("DT")
if (!require("kableExtra")) install.packages("kableExtra")
library(DT)
library(kableExtra)

# Function to make an exportable datatable
make_dt <- function(
    df,
    caption = NULL,
    filter = filter,
    pageLength = 10,
    numr_cols = "auto",    # Which columns are numeric
    big_cols = NULL,       # Which columns have big numbers
    sci_notation = TRUE,   # Use scientific number notation
    simple_mode = FALSE,
    center = "all"
    ) {
  
  if (simple_mode == TRUE) {
    dom <- "t"
    paging <- FALSE
    filter <- "none"
  } else {
    dom <- "Blfrtip"
    paging <- TRUE
    filter <- "top"
  }
  
  integer_idx <- as.integer(which(sapply(df, class) == "integer"))
  char_idx <- as.integer(which(sapply(df, class) == "character"))
  numr_idx <- as.integer(which(sapply(df, class) == "character"))
  if (center == "integer") center_idx <- integer_idx
  if (center == "all") center_idx <- c(integer_idx, char_idx, numr_idx)
  
  dt <- datatable(
    df,
    filter = filter,
    class = "compact row-border stripe hover nowrap",
    extensions = "Buttons",
    caption = htmltools::tags$caption(
      style = 'caption-side: bottom; text-align: center;', caption
    ),
    options = list(
      scrollX = TRUE,
      paging = paging,
      pageLength = pageLength,
      autoWidth = TRUE,
      dom = dom,
      buttons = c("copy", "csv", "excel"),
      columnDefs = list(list(className = 'dt-center', targets = center_idx))
    )
  )
  
  if (numr_cols == "auto") {
    numr_cols <- names(df)[which(sapply(df, class) == "numeric")]
  }
  if (sci_notation == TRUE & length(numr_cols) > 0) {
    dt <- dt %>% formatSignif(numr_cols, digits = 3)
  }
  
  # 1000-separator
  if (!is.null(big_cols)) {
    dt <- dt %>% formatCurrency(
      big_cols, currency = "", interval = 3, mark = ",", digits = 0
    )
  }
  
  return(dt)
}

## Function to make a kable table
make_kable <- function(df) {
  df %>%
    kable(format.args = list(big.mark = ",")) %>%
    kable_styling(full_width = FALSE, bootstrap_options = "striped")
}
