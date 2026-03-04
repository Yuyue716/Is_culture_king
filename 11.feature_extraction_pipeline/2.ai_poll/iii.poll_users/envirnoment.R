# Print initial message
print("Starting environment setup...")

# load utils
print("Loading libraries...")
library(data.table)
library(dplyr)
print("Basic data libraries loaded.")

# load utils to deal with APIs
print("Loading API handling libraries...")
library(httr)
library(jsonlite)
print("API libraries loaded.")

# use digest library to create hash function
print("Loading digest library...")
library(digest)
print("Digest library loaded.")

# Sample function override
print("Overriding 'sample' function...")
sample <- function(x, size, replace = F, prob = NULL) {
  if (length(x) == 1) {
    print("Single integer detected in sample, returning x directly.")
    return(x)
  }
  base::sample(x, size = size, replace = replace, prob = prob)
}
print("Overridden 'sample' function loaded.")

# function to get only files from directory (and ignore folders)
print("Defining function: get_files_from_dir...")
get_files_from_dir <- function(dir) {
  print(paste("Listing files in directory:", dir))
  all_items <- list.files(path = dir, full.names = TRUE)
  
  # Get the information about each item
  info <- file.info(all_items)
  
  # Filter out directories and keep only files
  files <- all_items[!info$isdir]
  
  print(paste("Found", length(files), "files in directory:", dir))
  return(files)
}
print("Function 'get_files_from_dir' defined.")

# load X API utils
print("Sourcing X API utilities...")
source('utils/X.api.v2_functions.R')
print("X API utilities loaded.")

# load date-time utils
print("Sourcing date-time functions...")
source('utils/date.time_functions.R')
print("Date-time utilities loaded.")

# load parsing utils
print("Sourcing parsing functions...")
source('utils/parse_functions.R')
print("Parsing utilities loaded.")

# load openAI library
print("Loading openai library...")
library(openai)
print("OpenAI library loaded.")

# load gpt utils
print("Sourcing GPT functions...")
source('utils/gpt_functions.R')
print("GPT utilities loaded.")

# load general utils 
print("Loading R.utils...")
library(R.utils)
print("R.utils loaded.")

# set api key
print("Setting OpenAI API key...")
Sys.setenv(OPENAI_API_KEY = readLines(con = 'tokens/OpenAI'))
print("OpenAI API key set.")

# # # (1) SET QUOTAS FOR DEMOGRAPHIC GROUPS 
print("Sourcing quotas frame script...")
source('R scripts/2.ai_poll/i.set_parameters/c.quotas_frame.R')
print("Quotas frame setup complete.")

# # # (2) LOAD BACKGROUND INFO FOR PAST VOTE CHOICE QUESTIONS
print("Sourcing geo_candidates_lookup script...")
source('R scripts/2.ai_poll/i.set_parameters/d.geo_candidates_lookup.R')
print("Geo candidates lookup loaded.")

print("Loading 2022 redistricting context data...")
load(file = 'generated_data/2022 redistricting context/context.RData')
print("Context data loaded.")

# # # (3) LOAD BALLOT ACCESS FOR EACH PARTY
print("Loading ballot access context data...")
load(file = 'auxiliary_data/Wikipedia/Ballot access context/ballot_access.RData')
print("Ballot access data loaded.")

# # # (4) DEFINE HYPER-PARAMETERS
print("Defining hyper-parameters for tweet history context...")
m = 10
m.trends = m*2
tau = 90 # days
print(paste("Set m =", m, ", m.trends =", m.trends, ", tau =", tau))

# initialise background info for prompts
print("Initializing background info (bg)...")
bg <- ''
print("Background info initialized.")

print("Environment setup complete.")
