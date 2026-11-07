#######################################################
### STARTING ROUTINE: poll_users (feature_extraction)
#######################################################

message('Loading environment...')
source('R scripts/2.ai_poll/iii.poll_users/envirnoment.R')

# Load independent and dependent features from external scripts
source('R scripts/2.ai_poll/i.set_parameters/a.independent_features_object.R')
ind_features_table <- parse_features(ind.features)

source('R scripts/2.ai_poll/i.set_parameters/b.dependent_features_object.R')
dep_features_table <- parse_features(dep.features)

source('R scripts/2.ai_poll/i.set_parameters/c.dependent_features_object.stance_module.R')
dep_features_stance_table <- parse_features(dep.features.stance_module)

########################################
### Prompt Instructions
########################################
instructions <- 'I will show you a number of categories to which this user may belong to.
The categories are preceded by a title (e.g. "AGE:" or "SEX:" etc.) and a symbol (e.g. "A1", "A2" or "E1" etc.).
Please select, for each title, the most likely category to which this user belongs to.

In your answer present, for each title, the selected symbol.
Write out in full the category associated with the selected symbol.
The chosen symbol / category must be the most likely to accurately represent this user.
You must only select one symbol / category per title.
A title, symbol and category cannot appear more than once in your answer.

For each selected symbol / category, please note the level of Speculation involved in this selection.
Present the Speculation level for each selection on a scale from 0 (not speculative at all, every single element of the user data was useful in the selection) to 100 (fully speculative, there is no information related to this title in the user data).
Speculation levels should be a direct measure of the amount of useful information available in the user data.
Speculation levels pertain only to the information available in the user data -- namely the username, name, description, location, profile picture and tweets from this user -- and should not be affected by additional information available to you from any other source.

To ensure consistency, use the following guidelines to determine speculation levels:

0-20 (Low speculation): The user data provides clear and direct information relevant to the title. (e.g., explicit mention in the profile or tweets)
21-40 (Moderate-low speculation): The user data provides indirect but strong indicators relevant to the title.
41-60 (Moderate speculation): The user data provides some hints or partial information relevant to the title.
61-80 (Moderate-high speculation): The user data provides limited and weak indicators relevant to the title.
81-100 (High speculation): The user data provides no or almost no information relevant to the title.

For each selected category, please explain at length what features of the data contributed to your choice and your speculation level.

Preserve a strictly structured answer to ease parsing of the text.
Format your output as follows (this is just an example):

**title: AGE**
**explanation: ...**
**symbol: A1)**
**category: 18-25**
**speculation: 90**

YOU MUST GIVE AN ANSWER FOR EVERY TITLE !

Below is the list of categories to which this user may belong to:
'


########################################
### Helper Functions
########################################

# Retry logic for GPT calls
attempt_gpt_call_with_retries <- function(model, messages.list, temperature, timeout, max_retries = 3, sleep_time = 5) {
  # Attempt GPT call with retries, returns successful result or NULL if fails.
  attempt <- 0
  success <- FALSE
  gen_result <- NULL
  
  while (!success && attempt < max_retries) {
    attempt <- attempt + 1
    gen_test <- attempt_gpt_call(
      model = model,
      messages.list = messages.list,
      temperature = temperature,
      timeout = timeout
    )
    
    if (!any(grepl('Error while downloading', unlist(gen_test))) &&
        !any(grepl('The provided image url can not be accessed', unlist(gen_test)))) {
      success <- TRUE
      gen_result <- gen_test
    } else {
      Sys.sleep(sleep_time)
    }
  }
  
  return(gen_result)
}

# Clean and structure GPT output
clean_gpt_output <- function(raw_output) {
  clean_messages <- prep_gpt_messages()
  clean_messages[[1]]$content[[1]]$text <- paste0(
    "You will be shown a long-form response to a question asking to assign a series of categories to a user.\n",
    "The categories are preceded by a title (e.g. 'AGE:'), a symbol (e.g. 'A1'), and a speculation level.\n",
    "Remove all unnecessary text, and retain only the title, symbol, category, and speculation level.\n",
    "Format strictly as shown below.\n\n",
    "Below is the long form response:\n\n",
    raw_output
  )
  
  # Run cleanup prompt with zero temperature
  gen_clean <- attempt_gpt_call(
    model = 'gpt-4o-mini',
    messages.list = clean_messages,
    temperature = 0,
    timeout = 120
  )
  
  return(gen_clean$choices$message.content)
}

########################################
### Main Processing Loop
########################################

# Gather all timeline buckets (subdirectories containing user tweets)
timeline_buckets <- dir(path = 'generated_data/user_tweets/', include.dirs = TRUE)
timeline_buckets <- timeline_buckets[!grepl('depreciated', timeline_buckets)]

for (b in timeline_buckets[1]) {  # Consider extending beyond [1] if needed
  user_paths <- dir(path = paste0('generated_data/user_tweets/', b))
  
  for (u in user_paths[1]) {      # Consider extending beyond [1] if needed
    ai_survey_temp_list <- data.table()
    
    # Load full user object data: profile & timeline
    load(file = paste0('generated_data/user_tweets/', b, '/', u))
    
    # Initialize temporary survey object for this user
    user_id_hash <- as.character(digest(full_user_object$profile$id[[1]], algo = "sha256"))
    ai_survey_temp <- data.table(
      gpt_id = user_id_hash
    )
    
    ########################################
    ### Build Prompts
    ########################################
    
    # DEMO prompt includes independent & dependent features plus the geo prompt
    DEMO_prompt <- paste0(
      instructions,
      paste0(sample(ind.features, replace = FALSE), collapse = '\n'),
      paste0(sample(dep.features, replace = FALSE), collapse = '\n'),
      geo2_currentvote_president_candidatesprompt_default
    )
    
    # STANCE prompt includes stance module dependent features
    STANCE_prompt <- paste0(
      instructions,
      paste0(sample(dep.features.stance_module, replace = FALSE), collapse = '\n')
    )
    
    # Collect prompts in a named vector
    prompts <- c(DEMO = DEMO_prompt, STANCE = STANCE_prompt)
    
    ########################################
    ### Prepare GPT Base Messages
    ########################################
    messages_list <- prep_gpt_messages()
    
    # Prepare user profile image
    image_list <- prep_gpt_image(
      image_url = full_user_object$profile$profile_image_url[[1]],
      X_size = '_normal'
    )
    
    # Append image info to test messages to check accessibility
    messages_list_test <- append_gpt_content(
      gpt_messages = messages_list,
      new_content = image_list
    )
    
    # Test image download accessibility with a simple model
    gen_test_result <- attempt_gpt_call_with_retries(
      model = 'gpt-4o-mini',
      messages.list = messages_list_test,
      temperature = 0.7,
      timeout = 30,
      max_retries = 3
    )
    
    if (!is.null(gen_test_result)) {
      # If successful, append image info to main messages
      messages_list <- append_gpt_content(
        gpt_messages = messages_list,
        new_content = image_list
      )
    } else {
      # If failed due to inaccessible image, remove image content
      if (any(grepl('The provided image url can not be accessed', unlist(gen_test_result)))) {
        messages_list_test[[1]]$content <- messages_list_test[[1]]$content[-2]
      }
    }
    
    ########################################
    ### Preparing Tweets by Months to Election
    ########################################
    dates <- unlist(full_user_object$timeline_tweets$created_at)
    dates <- ymd(sub("T.*", "", dates))
    months_to_election <- interval(dates, as.Date("2024-11-05","%Y-%m-%d")) %/% months(1)
    
    # Loop over each month-to-election interval
    for (month in unique(months_to_election)) {
      months_id <- which(months_to_election == month)
      
      # We need at least 10 tweets to proceed (as per original code comment)
      if (length(months_id) < 10) next
      
      # Start from the user-level survey template for this iteration
      ai_survey_temp_mould <- copy(ai_survey_temp)
      
      # Format tweets for the prompt
      prompt_tweets <- paste0(
        paste0("date and time of tweet (Y-m-d): ", unlist(full_user_object$timeline_tweets$created_at)[months_id]),
        "; \n",
        "tweet text: ",
        unlist(full_user_object$timeline_tweets$text)[months_id],
        ".",
        collapse = "\n\n"
      )
      
      ########################################
      ### Build and Run GPT Prompts (DEMO & STANCE)
      ########################################
      for (p in c('DEMO','STANCE')) {
        
        # Update the primary message with user profile and tweets
        messages_list[[1]]$content[[1]]$text <- paste0(
          "A social media account has the following username, name, description and profile image:\n",
          "username:", full_user_object$profile$username[[1]], "\n",
          "name:", full_user_object$profile$name[[1]], "\n",
          "description:", full_user_object$profile$description[[1]], "\n",
          ".\nFurthermore, they self-report their location in their bio as:\n",
          full_user_object$profile$location[[1]], "\n\n",
          "They have written the following tweet(s):\n",
          prompt_tweets, "\n\n", 
          prompts[p]
        )
        
        # Determine reference table based on prompt type
        if (p == 'DEMO') {
          reference_table <- c(
            ind_features_table,
            dep_features_table,
            parse_features(strsplit(geo2_currentvote_president_candidatesprompt_default, '\n\n')[[1]])
          )
        } else {
          # p == 'STANCE'
          reference_table <- dep_features_stance_table
        }
        
        # Retry logic for main GPT call
        retry_count <- 0
        max_retries_main <- 15
        success_main <- FALSE
        
        while (retry_count < max_retries_main & !success_main) {
          retry_count <- retry_count + 1
          # Try main GPT call
          tryCatch({
            gen <- attempt_gpt_call(
              model = 'gpt4o',
              temperature = 0.7,
              messages.list = messages_list,
              timeout = 120
            )
            
            reasoning <- gen$choices$message.content
            # Clean and extract final structured output
            output <- clean_gpt_output(reasoning)
            
            message(paste('LLM RAW OUTPUT (', p, '):', reasoning))
            message(paste('CLEANED OUTPUT (', p, '):', output))
            
            # Store raw reasoning
            ai_survey_temp_mould[[paste0('gpt_', p)]] <- reasoning
            
            # Parse cleaned output into structured data
            ai_survey_temp_mould <- cbind(
              ai_survey_temp_mould,
              parse_text_to_datatable(
                text = output,
                reference_table = reference_table,
                label = p,
                speculation = TRUE
              )
            )
            
            success_main <- TRUE
          }, error = function(e) {
            message('Error encountered, retrying... (attempt ', retry_count, ' of ', max_retries_main, ')')
            if (retry_count >= max_retries_main) {
              message('Error: ', e$message)
              stop("Maximum retries reached. Exiting.")
            }
          })
        }
      }
      
      ########################################
      ### Add Noise to Date and Save Results
      ########################################
      message('Adding noise to date for privacy...')
      # Add date (of last tweet in selected subset) with noise
      ai_survey_temp_mould$date <- add_noise_to_time(max(unlist(full_user_object$timeline_tweets$created_at)[months_id]))
      
      # Add current month index (months_to_election) and number of tweets
      ai_survey_temp_mould$month <- month
      ai_survey_temp_mould$n_tweets <- length(months_id)
      
      # Accumulate results for this user
      ai_survey_temp_list <- rbindlist(list(ai_survey_temp_list, ai_survey_temp_mould))
      
      # Save inferred user object
      save(ai_survey_temp_list, file = paste0('generated_data/survey_object/gpt_user_inference/ID_', ai_survey_temp$gpt_id, '.RData'))
    }
    print(ai_survey_temp_list)
  }
}


