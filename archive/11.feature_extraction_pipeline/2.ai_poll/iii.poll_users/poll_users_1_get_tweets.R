###############################################
### STARTING ROUTINE: poll_users (get_tweets)
###############################################

message('STARTING ROUTINE: poll_users')

########################################
### PART 0: Setup
########################################

message('Loading environment...')
source('R scripts/2.ai_poll/iii.poll_users/envirnoment.R')

message('Loading pool of users')
pool_files <- get_files_from_dir(dir = 'generated_data/tweets')

# Extract file paths based on POOL_TYPE
if (POOL_TYPE == 'LATEST') {
  path_tweets <- pool_files[
    grepl(extract_latest_date(pool_files, time = FALSE), pool_files)
  ]
} else if (POOL_TYPE == 'STORAGE') {
  path_tweets <- pool_files
}

# Shuffle paths to randomize processing order
n_pool_objects <- length(path_tweets)
path_shuffle <- sample(seq_len(n_pool_objects))
save(path_shuffle, file = 'generated_data/tweets/path.shuffle.RData')
load(file = 'generated_data/tweets/path.shuffle.RData')

########################################
### PART 1: Loop Through User Pool Objects
########################################

message('STARTING: Loop through user pool objects ...')

for (j in path_shuffle) {
  
  # Enforce temporal inclusion criteria
  message('ENFORCING: Temporal inclusion criteria ...')
  source('R scripts/2.ai_poll/iii.poll_users/temporal_inclusion_criteria.R')
  
  # Initialize survey object for the current pool object
  message('Initialising survey object for current query ...')
  ai_survey <- data.table()
  
  # Define where to save the survey
  save_path <- paste0('generated_data/survey_object/', gsub('generated_data/tweets/', '', path_tweets[j]))
  
  message('STARTING: Loop through surviving users for this query ...')
  for (user in seq_len(n.inc.users)) {
    
    # Load independent and dependent features
    source('R scripts/2.ai_poll/i.set_parameters/a.independent_features_object.R')
    ind_features_table <- parse_features(ind.features)
    
    source('R scripts/2.ai_poll/i.set_parameters/b.dependent_features_object.R')
    dep_features_table <- parse_features(dep.features)
    
    source('R scripts/2.ai_poll/i.set_parameters/c.dependent_features_object.stance_module.R')
    dep_features_stance_table <- parse_features(dep.features.stance_module)
    
    
    # Flag for extracted user timeline
    EXTRACTED_USER_TIMELINE <- FALSE
    
    # Initialize temporary survey row for this user
    message('Initialising current user survey ...')
    ai_survey_temp <- data.table(
      EXCLUDED = 'no',
      EXTRACTED_USER_TIMELINE = EXTRACTED_USER_TIMELINE
    )
    
    # Hash user ID
    message('Hashing user-id ...')
    ai_survey_temp$gpt_id <- as.character(digest(pool$users$id[[user]], algo = "sha256"))
    
    # Exclude users without location
    message('ENFORCING (A): Null-location exclusion ...')
    if (is.null(pool$users$location[[user]])) {
      message('**USER EXCLUDED: UNKNOWN LOCATION**')
      ai_survey_temp$EXCLUDED <- 'null_location'
      ai_survey <- rbindlist(list(ai_survey, ai_survey_temp), fill = TRUE)
      save(ai_survey, file = save_path, compress = TRUE)
      next
    }
    
    # Entity inclusion criteria
    message('ENFORCING (B): Entity inclusion criteria ...')
    criteria.question <- 'Is this account a real-life Person ("P") or Other ("O")?'
    timeout <- 30
    temperature <- 0.7
    model <- 'gpt4o'
    cleanup_structure <- 'loose'
    source('R scripts/2.ai_poll/iii.poll_users/gpt_build.user.call.R')
    org <- gen$choices$message.content
    ai_survey_temp$gpt_ENTITYREASON <- reasoning
    ai_survey_temp$gpt_ENTITY <- org
    
    message('LLM ENTITY EXTRACTION:', reasoning)
    if (grepl('Other', org) | org == 'O') {
      message('**USER EXCLUDED: NOT A PERSON**')
      ai_survey_temp$EXCLUDED <- 'not_a_person'
      ai_survey <- rbindlist(list(ai_survey, ai_survey_temp), fill = TRUE)
      save(ai_survey, file = save_path, compress = TRUE)
      next
    }
    
    # Impute Geo2 (e.g., state-level info)
    message('IMPUTING (A) GEO2 ...')
    criteria.question <- geo2_prompt
    timeout <- 30
    temperature <- 0.7
    model <- 'gpt4o'
    cleanup_structure <- 'loose'
    source('R scripts/2.ai_poll/iii.poll_users/gpt_build.user.call.R')
    geo2 <- gen$choices$message.content
    ai_survey_temp$gpt_GEO2REASON <- reasoning
    ai_survey_temp$gpt_GEO2 <- geo2
    
    if (grepl('Not from', geo2)) {
      message('**USER EXCLUDED: NOT FROM USA**')
      ai_survey_temp$EXCLUDED <- 'not_from_USA'
      ai_survey <- rbindlist(list(ai_survey, ai_survey_temp), fill = TRUE)
      save(ai_survey, file = save_path, compress = TRUE)
      next
    }
    
    # Quota inclusion criteria
    message('GENERATING (D): Quotas ...')
    criteria.question <- paste0(
      'I will show you categories (e.g. AGE, SEX) each with symbols (e.g. A1). ',
      'Select the most likely category for this user. Include speculation levels (0-100) as described.\n\n',
      'YOU MUST ANSWER FOR EVERY TITLE.\n\nBelow is the list of categories:\n\n',
      paste0(sample(ind.features, replace = FALSE), collapse = '\n')
    )
    
    retry_count <- 0
    max_retries <- 15
    success <- FALSE
    
    while (retry_count < max_retries & !success) {
      tryCatch({
        timeout <- 120
        model <- 'gpt4o'
        temperature <- 0.7
        cleanup_structure <- 'strict'
        source('R scripts/2.ai_poll/iii.poll_users/gpt_build.user.call.R')
        
        ai_survey_temp$gpt_QUOTA <- reasoning
        
        # Parse extracted quota features
        ai_survey_temp <- cbind(
          ai_survey_temp,
          parse_text_to_datatable(
            text = output,
            reference_table = ind_features_table,
            label = 'QUOTA',
            speculation = TRUE
          )
        )
        success <- TRUE
      }, error = function(e) {
        retry_count <<- retry_count + 1
        if (retry_count >= max_retries) {
          message('Error: ', e$message)
          stop("Max retries reached. Exiting.")
        } else {
          message('Error encountered, retrying... (attempt ', retry_count, ' of ', max_retries, ')')
        }
      })
    }
    
    # Apply quota checks
    message('ENFORCING (D-b): Checking quota criteria ...')
    source('R scripts/2.ai_poll/iii.poll_users/quota_inclusion_criteria.R')
    
    # Create a folder to store user tweets
    source_dir <- "generated_data/quota_counter"
    dest_dir <- "generated_data/user_tweets"
    files <- list.files(source_dir, pattern = "\\.RData$", full.names = TRUE)
    
    if (length(files) > 0) {
      # Get most recent quota file and create a folder named after it
      file_names <- basename(files)
      file_no_ext <- tools::file_path_sans_ext(file_names)
      date_times <- as.POSIXct(strptime(file_no_ext, '%Y-%m-%d %H:%M:%OS', tz = 'UTC'))
      sorted_indices <- order(date_times, decreasing = TRUE)
      folder_name <- tools::file_path_sans_ext(basename(files[sorted_indices][1]))
      
      folder_path <- file.path(dest_dir, folder_name)
      if (!dir.exists(folder_path)) {
        dir.create(folder_path)
      }
    } else {
      stop("No Quota files found in the source directory.")
    }
    
    # Get user tweets
    max_results <- ifelse(grepl('trends', path_tweets[j]), m.trends, m)
    this_user_tweets <- robust_get_user_tweets(
      user_id = pool$users$id[[user]],
      max_results = max_results,
      store_path = paste0(folder_path, '/', pool$users$id[[user]], '_', Sys.Date(), '.RData'),
      max_retries = 100,
      sleep = 120
    )
    
    if (length(this_user_tweets$data$text) > 0) {
      EXTRACTED_USER_TIMELINE <- TRUE
      ai_survey_temp$EXTRACTED_USER_TIMELINE <- EXTRACTED_USER_TIMELINE
      message('X API RETURNED ', length(this_user_tweets$data$text), ' TWEETS FOR THIS USER.')
    }
    
    # Combine user profile and tweets into a single object and store
    full_user_object <- list(
      profile = pool$users[unlist(pool$users$id) == pool$users$id[[user]], ],
      pool_tweets = pool$tweets[unlist(pool$tweets$author_id) == pool$users$id[[user]], ],
      timeline_tweets = this_user_tweets$data
    )
    
    save(full_user_object, file = paste0(folder_path, '/', pool$users$id[[user]], '_', Sys.Date(), '.RData'))
    
    # Append current user to survey and save
    ai_survey <- rbindlist(list(ai_survey, ai_survey_temp), fill = TRUE)
    message('***FEATURE EXTRACTION COMPLETE FOR THIS USER***')
    save(ai_survey, file = save_path, compress = TRUE)
    
    print(ai_survey)
    
  }
}

message('ENDING ROUTINE: poll_users (get_tweets)')

########################################
### CLEAN UP
########################################

rm(list = ls())
gc()
