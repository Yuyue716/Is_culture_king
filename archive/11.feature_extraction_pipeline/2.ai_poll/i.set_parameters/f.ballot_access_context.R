###############################################################################
# This script scrapes ballot access data for the 2024 U.S. Presidential Election 
# from Wikipedia, cleans and structures it, and then saves the result.
###############################################################################

#----- Setup Environment -------------------------------------------------------
# Note: Removing all objects, forcing garbage collection, and setting the WD 
# can be considered optional and environment-dependent operations.
# Uncomment if necessary.

# rm(list = ls())        # Remove all objects
# gc()                   # Garbage collection
# setwd("~/Desktop/Mechanical Pollster - is Culture King ?/") # Set working directory

# Set R options
options(scipen = 999)      # Use regular digits instead of scientific notation
options(timeout = 10000)   # Increase download timeout

#----- Libraries ---------------------------------------------------------------
library(data.table)
library(rvest)
library(xml2)
library(usmap) # For 'fips_info()' to filter states

#----- Data Source -------------------------------------------------------------
url <- "https://en.wikipedia.org/wiki/Ballot_access_in_the_2024_United_States_presidential_election"

#----- Scrape HTML Table -------------------------------------------------------
webpage <- read_html(url)
ballot_table_node <- html_nodes(
  webpage,
  xpath = '//*[@id="General_election"]/following::table[1]'
)

# Extract initial headers
header_raw <- html_nodes(ballot_table_node, "th")
header <- html_text(header_raw, trim = TRUE)[1:10]

# Adjust headers
header[2] <- 'Electoral votes'

# Clean and normalize header names
header <- gsub("@supports\\(writing-mode:vertical-rl\\)\\{.*?\\}\\}\\}", "", header)
header <- gsub("([a-z])([A-Z])", "\\1 \\2", header, perl=TRUE)
header <- gsub("(Constitution|Independent|Libertarian|Democratic|Green|PSL|Republican)(?=[A-Z])", "\\1-", header, perl=TRUE)
header <- gsub(" \\(presumptive\\)", "", header)

# Extract all rows and filter to those that mention a U.S. state
rows <- html_nodes(ballot_table_node, "tr")
state_abbrs <- usmap::fips_info()$abbr
rows <- rows[grepl(paste0('<th>', state_abbrs, collapse='|'), as.character(rows), ignore.case=FALSE)]

#----- Custom Parsing Function -------------------------------------------------
# This function extracts cell contents from a table row, taking into account 
# background colors, potential images (alts), and colspan attributes.
parse_html_table <- function(html_row) {
  row_str <- gsub("\n", "", as.character(html_row))
  matches <- gregexpr("(<th[^>]*>|<td[^>]*>)(.*?)(</th>|</td>)", row_str, perl=TRUE)
  cells <- regmatches(row_str, matches)[[1]]
  
  cell_list <- list()
  
  for (cell in cells) {
    # Extract content
    content <- sub("(<th[^>]*>|<td[^>]*>)(.*?)(</th>|</td>)", "\\2", cell)
    description <- sub(".*<img [^>]*alt=\"([^\"]*)\".*", "\\1", content)
    
    # If no image alt text found, use raw text (remove tags)
    if (description == content) {
      description <- gsub("<[^>]*>", "", content)
      description <- trimws(description)
    }
    
    # Extract background color if present
    tag_open <- sub("^(<th[^>]*>|<td[^>]*>).*", "\\1", cell)
    background_color <- NA
    if (grepl("style=", tag_open)) {
      style_attr <- sub(".*style=\"([^\"]*)\".*", "\\1", tag_open)
      bg_match <- regexec("background:\\s*([^;]*)", style_attr)
      bg_res <- regmatches(style_attr, bg_match)
      if (length(bg_res[[1]]) > 1) {
        background_color <- trimws(bg_res[[1]][2])
      }
    }
    if (!is.na(background_color)) {
      description <- paste(description, "[background:", background_color, "]")
    }
    
    # Handle colspan
    colspan <- as.numeric(sub(".*colspan=\"([0-9]+)\".*", "\\1", cell))
    if (is.na(colspan)) colspan <- 1
    
    # Repeat cell content for colspan
    for (i in seq_len(colspan)) {
      cell_list <- append(cell_list, description)
    }
  }
  return(cell_list)
}

#----- Parse Rows and Create Data Table ----------------------------------------
ballot_access <- rbindlist(
  lapply(rows, function(r) as.data.table(t(parse_html_table(r)))),
  fill = TRUE
)
names(ballot_access) <- header

# Convert color-coded entries that represent write-ins to "No"
ballot_access <- ballot_access[, lapply(.SD, function(x) {
  ifelse(grepl('#FFFFBB|#FFE3E3|#FED', x), 'No', x)
})]

# Convert all columns from list to character
ballot_access[, (names(ballot_access)) := lapply(.SD, function(col) {
  as.character(unlist(col))
}), .SDcols = names(ballot_access)]

# Check classes again
sapply(ballot_access, class)

# Clean and simplify ballot access values
# Convert entries with "as", "yes", "registration not required", or "petitioning finished" to "Yes"; else "No"
cols_to_clean <- setdiff(names(ballot_access), c('State / electors', 'Electoral votes'))
ballot_access <- ballot_access[,
                               lapply(.SD, function(x) {
                                 ifelse(grepl('as|yes|registration not required|petitioning finished', x, ignore.case=TRUE), 'Yes', 'No')
                               }),
                               by = c('State / electors', 'Electoral votes'),
                               .SDcols = cols_to_clean
]

# Keep only major parties and selected independents
keep_patterns <- c('State / electors', 'Electoral votes', 'Democratic', 'Independent', 'Republican', 'Green', 'Libertarian')
ballot_access <- ballot_access[, grepl(paste(keep_patterns, collapse="|"), names(ballot_access)), with=FALSE]

# Rename columns to reflect candidate names
setnames(ballot_access, old = grep('Democratic', names(ballot_access), value=TRUE), 
         new = 'Kamala Harris, the Democratic Party candidate')
setnames(ballot_access, old = grep('Republican', names(ballot_access), value=TRUE), 
         new = 'Donald Trump, the Republican Party candidate')
setnames(ballot_access, old = grep('Green', names(ballot_access), value=TRUE), 
         new = 'Jill Stein, the Green Party candidate')
setnames(ballot_access, old = grep('Kennedy', names(ballot_access), value=TRUE), 
         new = 'Robert F. Kennedy Jr., who is not affiliated with any political party')
setnames(ballot_access, old = grep('West', names(ballot_access), value=TRUE), 
         new = 'Dr. Cornel West, who is not affiliated with any political party')
setnames(ballot_access, old = grep('Libertarian', names(ballot_access), value=TRUE), 
         new = 'Chase Oliver, the Libertarian Party candidate')

#----- Save Results ------------------------------------------------------------
save(ballot_access, file = 'auxiliary_data/Wikipedia/Ballot access context/ballot_access.RData')
save(ballot_access, file = paste0('auxiliary_data/Wikipedia/Ballot access context/ballot_access_',
                                  gsub('-','', as.character(Sys.Date())), '.RData'))

#----- Quick Check -------------------------------------------------------------
ballot_access[sample(1:.N, size = 1)]
