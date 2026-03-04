################################################################################
# IMPLEMENT TEMPORAL INCLUSION CRITERIA FOR USER POLLING
################################################################################

# STEP 1: LOAD THE CURRENT DATASET OF TWEETS & USERS
# -----------------------------------------------
# Load the pool object from the specified file path.
load(file = path_tweets[j])

# If no users are available in the current dataset, move to the next path.
if (length(pool$users) <= 0) {
  message('No valid users for query in path: ', path_tweets[j], '.',
          '\nMoving to next path ...')
  next
}

################################################################################
# STEP 2: RETRIEVE LIST OF PREVIOUSLY POLLED USERS
# -----------------------------------------------
# Gather the paths of all files that record previously polled users.
user.files <- get_files_from_dir(dir = 'generated_data/users')

# If there are previously recorded users, load and consolidate their information.
if (length(user.files) > 0) {
  
  message('Loading previously polled users...')
  
  # Initialize an empty data table to store historical user polling records.
  user.list <- data.table()
  
  # Loop through each user file and stack (append) them into user.list
  for (i in user.files) {
    load(file = i)
    # Ensure the date is in a standard Date format (YYYY-MM-DD)
    users$date <- as.Date(substr(users$date, 1, 10), "%Y-%m-%d")
    user.list <- rbindlist(list(user.list, users))
  }
  
  ##############################################################################
  # STEP 3: APPLY TEMPORAL INCLUSION CRITERIA
  # -----------------------------------------
  # Identify users who have been polled recently (within 'tau' days).
  
  message('Identifying users who have already been polled within the temporal inclusion time-frame ...')
  
  # Mark users as recently seen if their last polling date is within 'tau' days.
  user.list$recent <- ifelse(user.list$date >= (Sys.Date() - tau), TRUE, FALSE)
  
  # Extract the set of forbidden users (i.e., those recently polled).
  forbidden.users <- unique(user.list$user[user.list$recent])
  
  # Remove these forbidden users from the current pool if any exist.
  if (length(forbidden.users) > 0) {
    message('Banishing already-polled users...')
    pool$users <- pool$users[!unlist(pool$users$id) %in% forbidden.users, ]
  }
  
} else {
  # If no prior user-file records exist, this is the first time observing these users.
  # All users are eligible by default since we have no historical data.
  message(
    'There is no user-file to draw upon.',
    '\nThis must be the first set of users we are observing from the pool.',
    '\nEvery user meets the temporal inclusion criteria by default.'
  )
}

################################################################################
# STEP 4: CHECK FOR ANY REMAINING ELIGIBLE USERS
# ----------------------------------------------
# If no users remain after applying the temporal inclusion criteria, proceed to the next path.
if (dim(pool$users)[1] <= 0) {
  message('No valid users from path: ', path_tweets[j],
          ', remain eligible for polling after temporal inclusion criteria.',
          '\nMoving to next path...')
  next
}

################################################################################
# STEP 5: EXTRACT AND RECORD THE MOST RECENT OBSERVATION DATE FOR EACH USER
# --------------------------------------------------------------------------
# For each user still in the pool, determine their most recent tweet date.
last_observed_user <- sapply(
  unlist(pool$users$id),
  function(id) {
    max(unlist(pool$tweets[pool$tweets$author_id == id, ]$created_at))
  }
)

# Create a data table of the users that survive the filter and their last observed date.
users <- data.table(
  user = names(last_observed_user),
  date = last_observed_user
)

# Count how many users remain eligible after temporal inclusion.
n.inc.users <- dim(pool$users)[1]

################################################################################
# STEP 6: UPDATE THE DATABASE OF POLLED USERS
# -------------------------------------------
# Save the current set of polled users so we can exclude them in future iterations.
message('Updating database of polled users ...')
save(
  users,
  file = paste0('generated_data/users/',
                gsub('generated_data/tweets/', '', path_tweets[j])),
  compress = TRUE
)

message('Database of polled users updated !')

################################################################################
# END OF TEMPORAL INCLUSION CRITERIA IMPLEMENTATION
################################################################################
