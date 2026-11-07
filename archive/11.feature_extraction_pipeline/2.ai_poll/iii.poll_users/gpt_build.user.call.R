########################################
### Prepare Initial GPT Messages
########################################

# Prepare base GPT messages
messages_list <- prep_gpt_messages()

# Prepare user profile image for GPT prompt
image_list <- prep_gpt_image(
  image_url = pool$users$profile_image_url[[user]],
  X_size = '_normal'
)

# Append image info to the prompt messages
messages_list_test <- append_gpt_content(
  gpt_messages = messages_list,
  new_content = image_list
)

########################################
### Test Image Download with a Crappy Model
########################################

model_test <- 'gpt-4o-mini'

gen_test <- attempt_gpt_call(
  model = model_test,
  messages.list = messages_list_test,
  temperature = temperature,
  timeout = timeout
)

# If the image fails to download, retry with a different image size parameter
if (any(grepl('Error while downloading', unlist(gen_test)))) {
  image_list <- prep_gpt_image(
    image_url = gsub('_normal', '_bigger', pool$users$profile_image_url[[user]]),
    X_size = ''
  )
}

########################################
### Prepare Tweets for Prompt
########################################

# If user's timeline was extracted, use that data; otherwise, use fallback from pool$tweets
if (EXTRACTED_USER_TIMELINE) {
  # Format tweets from this.user.tweets
  prompt_tweets <- paste0(
    paste0("date and time of tweet (Y-m-d): ", this.user.tweets$data$created_at), "; \n",
    paste0("tweet text: ", unlist(this.user.tweets$data$text), "."),
    collapse = "\n\n"
  )
} else {
  # Format tweets from pool$tweets
  user_tweet_indices <- unlist(pool$tweets$author_id) == pool$users$id[[user]]
  prompt_tweets <- paste0(
    sapply(which(user_tweet_indices), function(i) {
      paste0(
        "date and time of tweet (Y-m-d): ", pool$tweets$created_at[i], ";\n",
        "tweet text: ", pool$tweets$text[i], "."
      )
    }),
    collapse = "\n\n"
  )
}

########################################
### Construct the Final Prompt
########################################

messages_list[[1]]$content[[1]]$text <- paste0(
  bg,
  "A social media account has the following username, name, description and profile image:\n",
  "username:", pool$users$username[[user]], "\n",
  "name:", pool$users$name[[user]], "\n",
  "description:", pool$users$description[[user]], "\n",
  ".\nFurthermore, they self-report their location in their bio as:\n",
  pool$users$location[[user]], "\n\n",
  "They have written the following tweet(s):\n",
  prompt_tweets, "\n\n", criteria.question
)

# Append updated image info to messages
messages_list <- append_gpt_content(
  gpt_messages = messages_list,
  new_content = image_list
)

########################################
### Run the Prompt
########################################

gen <- attempt_gpt_call(
  model = model,
  temperature = temperature,
  messages.list = messages_list,
  timeout = timeout
)

message('GPT OUTPUT:', gen$choices$message.content)

########################################
### If Temperature > 0, Cleanup Output
########################################

if (temperature > 0) {
  reasoning <- gen$choices$message.content
  output <- gen$choices$message.content
  
  # Create a cleanup prompt based on structure
  clean_messages_list <- prep_gpt_messages()
  
  # Loose structure cleanup
  if (cleanup_structure == 'loose') {
    clean_messages_list[[1]]$content[[1]]$text <- paste0(
      "You will be shown a response to a question asking an LLM to detect and infer an attribute for a given user.\n",
      "Remove all unnecessary text, including any explanation of the inference, and retain only the chosen attribute.\n\n",
      "Below is the long-form response:\n\n",
      output
    )
  }
  
  # Strict structure cleanup
  if (cleanup_structure == 'strict') {
    clean_messages_list[[1]]$content[[1]]$text <- paste0(
      "You will be shown a long-form response to a question asking to assign a series of categories to a user.\n",
      "The categories are preceded by a title (e.g. 'AGE:'), a symbol (e.g. 'A1'), and a speculation level.\n",
      "Remove all unnecessary text, and retain only the title, symbol, category, and speculation level.\n",
      "Format strictly as shown below.\n\n",
      "Below is the long form response:\n\n",
      output
    )
  }
  
  # Run cleanup prompt with zero temperature
  temperature <- 0
  model <- 'gpt-4o-mini'
  
  gen <- attempt_gpt_call(
    model = model,
    messages.list = clean_messages_list,
    temperature = temperature,
    timeout = timeout
  )
  
  # Final cleaned output
  output <- gen$choices$message.content
}

# Reset background if used elsewhere
bg <- ''
