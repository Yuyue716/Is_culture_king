# Clean workspace and set environment
rm(list = ls())
gc() # Garbage collection
options(scipen = 999, timeout = 10000)

setwd("~/Desktop/Mechanical Pollster - is Culture King ?/")

# Load required packages
library(data.table)
library(dplyr)
library(httr)
library(jsonlite)
library(usmap)
library(zoo)

# Override sample function to handle single integer input properly
sample <- function(x, size, replace = FALSE, prob = NULL) {
  if (length(x) == 1) return(x)
  base::sample(x, size = size, replace = replace, prob = prob)
}

# Load utility functions
source('utils/gpt_functions.R')
source('utils/image.url_functions.R')
source('tokens/imgur_auth.R')

# Set OpenAI API key
Sys.setenv(OPENAI_API_KEY = readLines('tokens/OpenAI'))

# Load independent and dependent feature objects
source('R scripts/2.ai_poll/i.set_parameters/a.independent_features_object.R')
source('R scripts/2.ai_poll/i.set_parameters/b.dependent_features_object.R')

# Load geo candidates lookup
source('R scripts/2.ai_poll/i.set_parameters/d.geo_candidates_lookup.R')

### Data Loading and Preprocessing ---------------------------------------------

# Load and prepare district race data
kos_race <- fread("auxiliary_data/Redistricting 2022 Context/Daily Kos/House and Senate 5-Year American Community Survey Racial Demographics by Citizenship Status - 118th House—2022.csv")
tmp <- unlist(kos_race[1]); tmp[tmp==''] <- NA
kos_race[1] <- as.data.table(t(zoo::na.locf(tmp)))
kos_race <- kos_race[, grepl('District|Code|Total Population by Race', kos_race[1]), with=FALSE]
names(kos_race) <- unlist(kos_race[2])
names(kos_race)[grepl('District|Code', kos_race[1])] <- c('district','code')
kos_race <- kos_race[-c(1:3)]
kos_race <- cbind(extract_district_info(kos_race$district), kos_race[, !'district'])

# Load rural/suburban/urban data
kos_rural <- fread("auxiliary_data/Redistricting 2022 Context/Daily Kos/Daily Kos Elections urban-suburban-rural population by congressional district (118th congress) - Total Pop..csv")
kos_rural <- kos_rural[, grepl('%|CD', names(kos_rural)), with=FALSE]
kos_rural[kos_rural$CD=='TX-20']$CD[2] <- 'TX-21'
for (col_name in grep('%|CD', names(kos_rural), value=TRUE)) {
  kos_rural[[col_name]] <- gsub('%','', kos_rural[[col_name]])
}
names(kos_rural) <- gsub(' %','', names(kos_rural))

# Merge race and rural data
kos <- merge(kos_race, kos_rural, by.x='code', by.y='CD', all.x=TRUE)

# Add education and income data
kos_edu <- fread("auxiliary_data/Redistricting 2022 Context/Daily Kos/Bachelor's degrees or greater for ages 25+ & median household income by congressional district (2018-2022) - 2022 - 118th House.csv")
kos <- merge(kos, kos_edu[, c('District',"Bachelor's","Median Income")], by.x='code', by.y='District', all.x=TRUE)

# Add geographic descriptions
kos_description <- fread("auxiliary_data/Redistricting 2022 Context/Daily Kos/Daily Kos Elections congressional district geographic descriptions & largest places (118th Congress) - Descriptive name.csv")
kos <- merge(kos, kos_description[, c('CD',"Geographic Description")], by.x='code', by.y='CD', all.x=TRUE)

# Add major places
kos_places <- fread("auxiliary_data/Redistricting 2022 Context/Daily Kos/Daily Kos Elections congressional district geographic descriptions & largest places (118th Congress) - By places.csv")
major_places_cols <- grep('% of CD', names(kos_places))
kos_places$`Major Places` <- paste(
  'The most populated place in the district is', kos_places$`Largest place`, 
  'accounting for', kos_places[[major_places_cols[1]]], '% of the population.',
  ifelse(!is.na(kos_places[[major_places_cols[2]]]),
         paste('The second most populated place is', kos_places$`Second-largest place`,
               'accounting for', kos_places[[major_places_cols[2]]], '% of the population.'), NA),
  ifelse(!is.na(kos_places[[major_places_cols[3]]]),
         paste('The third most populated place is', kos_places$`Third-largest place`,
               'accounting for', kos_places[[major_places_cols[3]]], '% of the population.'), NA)
)
kos <- merge(kos, kos_places[, c('CD',"Major Places")], by.x='code', by.y='CD', all.x=TRUE)

kos <- kos[, !'code']
names_to_rename <- names(kos)[!grepl('state|district|Median Income|Geographic Description|Major Places|Urban|Rural|Bachelor|Suburban', names(kos))]
names(kos)[match(names_to_rename, names(kos))] <- paste0('% Pop. who identifies as ', names_to_rename)
names(kos)[grepl('Bachelor', names(kos))] <- "% Pop. who achieved a Bachelor's degree"
names(kos)[grepl('Urban|Suburban|Rural', names(kos))] <- paste0("% Pop. who lives in ", names(kos)[grepl('Urban|Suburban|Rural', names(kos))], " areas")

# Create prompt text for geo3 demographics
geo3_lookup_demos <- kos[, c('state','district')]
geo3_lookup_demos$prompt <- apply(kos, 1, function(row) {
  paste(paste(names(kos), row, sep=': '), collapse='\n')
})
geo3_lookup_demos$state_po <- fips_info()[, 'abbr'][match(geo3_lookup_demos$state, fips_info()[, 'full'])]
geo3_lookup_demos$state_fips <- as.numeric(fips_info()[,'fips'])[match(geo3_lookup_demos$state, fips_info()[,'full'])]
geo3_lookup_demos$state <- tolower(geo3_lookup_demos$state)

# Prompt function for district boundaries
prompt.boundaries <- function(geo2, geo3) {
  paste0(
    'Consider the following Congressional District: State - ', geo2, ', District - ', geo3, '.\n',
    'I attach an image of the map of this district after the 2022 redistricting took place.\n',
    'Describe in detail the geographical boundaries of the district AFTER REDISTRICTING, including the counties within its boundaries.'
  )
}

# Prompt function for summarizing context
prompt.text <- function(geo2, geo3, geo3_lookup, geo3_lookup_demos, boundaries_text) {
  election_data <- geo3_lookup[year == 2022 & state_po == geo2 & district == geo3, c('candidate','party','candidatevotes')]
  election_str <- paste0(
    apply(election_data, 1, function(x) paste0(c('candidate: ','party: ','votes: '), x, collapse='\n')),
    collapse='\n'
  )
  
  paste0(
    'BACKGROUND:\n\n',
    'Consider the following Congressional District: State - ', geo2, ', District - ', geo3, '.\n\n',
    'Its geographical boundaries are as follows:', boundaries_text, '\n\n',
    'The results of the election for the congressional seat in this district for 2022 (after redistricting) are:\n\n',
    election_str, '.\n\n',
    'If a party is not mentioned, it means they did not field a candidate for this election.\n\n',
    'Furthermore, the congressional district has the following socio-demographics (after redistricting):\n\n',
    geo3_lookup_demos[state_po == geo2 & district == geo3]$prompt, '\n\n',
    'Summarise all this information in 150 words or less.'
  )
}

### Generate Context for Each District ------------------------------------------

gen.geo3_context_list <- data.table()

# Process by state (geo2) and district (geo3)
for (geo2 in unique(geo3_lookup$state_po)[31:52]) {
  if (geo2 == 'USA') next
  
  dist_list <- unique(geo3_lookup[state_po == geo2]$district)
  
  for (geo3 in dist_list) {
    # Skip if no data for 2022
    if (sum(geo3_lookup$year == 2022 & geo3_lookup$state_po == geo2 & geo3_lookup$district == geo3) == 0) next
    
    # Prepare initial prompt for boundaries
    messages.list <- list(
      list(
        "role" = "user",
        "content" = list(
          list("type" = "text", "text" = prompt.boundaries(geo2, geo3))
        )
      )
    )
    
    # Determine Congress ID
    congress.id <- ifelse(2022 == 2020, 117, ifelse(2022 == 2022, 118, NA))
    if (geo2 == 'DE') congress.id <- 116
    
    # Construct PDF URL
    pdf_url <- paste0(
      "https://www2.census.gov/geo/maps/cong_dist/cd", congress.id, 
      "/cd_based/ST", sprintf("%02d", unique(geo3_lookup[year == 2022 & state_po == geo2 & district == geo3]$state_fips)),
      "/CD", congress.id, "_", geo2, sprintf("%02d", geo3), ".pdf"
    )
    pdf_path <- paste0('auxiliary_data/Redistricting 2022 Context/Census/CD', congress.id, '_', geo2, sprintf("%02d", geo3), '.pdf')
    
    # Get image URL from PDF
    geo3_content_object <- list(temp = pdf_to_url(input.url = pdf_url, pdf.path = pdf_path))
    names(geo3_content_object)[names(geo3_content_object)=='temp'] <- 2022
    
    # Append image URL to message
    image_list <- list('type' = 'image_url', 'image_url' = list('url' = geo3_content_object[["2022"]]$data$link))
    messages.list[[1]]$content[[length(messages.list[[1]]$content)+1]] <- image_list
    
    # Call GPT for boundaries
    gen.geo3_boundaries <- call_gpt(messages.list = messages.list, temperature = 0.7, timeout = 120)
    boundaries_text <- gen.geo3_boundaries$choices$message.content
    
    # Prepare summary prompt
    messages.list <- list(
      list(
        "role" = "user",
        "content" = list(
          list("type" = "text", "text" = prompt.text(geo2, geo3, geo3_lookup, geo3_lookup_demos, boundaries_text))
        )
      )
    )
    
    # Call GPT for summary
    gen.geo3_context.summary <- call_gpt(messages.list = messages.list, temperature = 0.7, timeout = 120)
    
    # Store results
    gen.geo3_context_list <- rbindlist(
      list(
        gen.geo3_context_list,
        data.table(
          state = fips_info()[match(geo2, fips_info()$abbr), 'full'],
          district = geo3,
          boundaries = boundaries_text,
          context.summary = gen.geo3_context.summary$choices$message.content
        )
      )
    )
    
    # Save interim results
    save(gen.geo3_context_list, file = 'generated_data/2022 redistricting context/context.RData')
  } 
}
