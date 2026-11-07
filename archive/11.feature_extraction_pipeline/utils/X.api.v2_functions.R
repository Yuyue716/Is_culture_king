library(httr)
library(jsonlite)
library(rvest)

###############################
# Setup Bearer Token for X API
###############################

# Make sure you have a "tokens/X" file containing your bearer token
Sys.setenv(BEARER_TOKEN = readLines(con = 'tokens/X'))
bearer_token <- Sys.getenv("BEARER_TOKEN")

if (!nzchar(bearer_token)) {
  stop("Bearer token not found. Please ensure 'tokens/X' contains a valid bearer token.")
}

#####################################
# OAuth and API Request Setup
#####################################

#' Construct OAuth headers for X (Twitter) API requests
#'
#' @return An httr configuration object with Authorization and User-Agent headers
bearer_oauth <- function() {
  if (!nzchar(bearer_token)) {
    stop("Bearer token is not set. Make sure the environment variable BEARER_TOKEN is defined.")
  }
  add_headers(Authorization = paste0("Bearer ", bearer_token),
              `User-Agent` = "v2TweetLookupR")
}

#####################################
# Create Search URL for Tweets
#####################################

#' Create the URL for querying recent tweets
#'
#' @param query Character string. Search query.
#' @param next_token Character. Token for pagination. Defaults to NULL.
#' @param max_results Integer. Max number of results (1-100).
#' @param start_time Character. Start of time window (ISO 8601 format).
#' @param end_time Character. End of time window (ISO 8601 format).
#' @param lang Character. Language code to filter tweets.
#' @param exclude_retweets Logical. If TRUE, excludes retweets.
#'
#' @details
#' Constructs the URL for the `recent search` endpoint of Twitter API v2.
#'
#' @return A character string representing the complete URL.
#' @export
create_url <- function(query, next_token = NULL, max_results, start_time, end_time, lang = NULL, exclude_retweets = TRUE) {
  
  if (!is.character(query) || !nzchar(query)) {
    stop("`query` must be a non-empty character string.")
  }
  
  if (!is.numeric(max_results) || max_results < 1 || max_results > 100) {
    stop("`max_results` must be between 1 and 100.")
  }
  
  # Tweet and user fields
  tweet_fields <- paste0("attachments,author_id,conversation_id,created_at,entities,geo,id,",
                         "in_reply_to_user_id,lang,public_metrics,referenced_tweets,source,text,possibly_sensitive")
  
  user_fields <- paste0("created_at,description,entities,id,location,most_recent_tweet_id,name,",
                        "pinned_tweet_id,profile_image_url,protected,public_metrics,url,username,verified,verified_type,withheld")
  
  base_url <- "https://api.twitter.com/2/tweets/search/recent?"
  
  # Exclude retweets if requested
  if (exclude_retweets) {
    query <- paste0(query, " -is:retweet")
  }
  
  # Filter by language if provided
  if (!is.null(lang)) {
    query <- paste0(query, " lang:", lang)
  }
  
  url <- paste0(base_url,
                "query=", URLencode(query),
                "&max_results=", max_results,
                "&start_time=", start_time,
                "&end_time=", end_time,
                "&tweet.fields=", tweet_fields,
                "&expansions=author_id",
                "&user.fields=", user_fields)
  
  if (!is.null(next_token)) {
    url <- paste0(url, "&next_token=", next_token)
  }
  
  return(url)
}

#####################################
# Connecting to the Endpoint
#####################################

#' Connect to a given endpoint URL
#'
#' @param url Character. The request URL.
#'
#' @return Parsed JSON content of the response.
#' @export
connect_to_endpoint <- function(url) {
  if (!is.character(url) || !nzchar(url)) {
    stop("`url` must be a non-empty character string.")
  }
  
  response <- GET(url, config = bearer_oauth())
  
  if (status_code(response) != 200) {
    stop("Request returned an error: ", status_code(response), " ", content(response, "text", encoding = "UTF-8"))
  }
  
  return(content(response, "parsed", encoding = "UTF-8"))
}

#####################################
# Main Search Function
#####################################

#' Search for Tweets within a specified time range
#'
#' @param query Character. The search query.
#' @param lang Character. Language code. NULL to ignore language filter.
#' @param exclude_retweets Logical. If TRUE, exclude retweets.
#' @param start_time Character. Start time in ISO 8601 format.
#' @param end_time Character. End time in ISO 8601 format.
#' @param max_results Integer. Maximum number of results to retrieve.
#' @param store_path Character. Optional. If provided, save the results to this file.
#' @param tibble Logical. If TRUE, return a tibble (not implemented here, kept for compatibility).
#'
#' @return A list (JSON structure) with tweets and users.
#' @export
search <- function(query, lang = NULL, exclude_retweets = TRUE, start_time, end_time, max_results, store_path = NULL, tibble = FALSE) {
  
  if (!is.character(query) || !nzchar(query)) {
    stop("`query` must be a non-empty character string.")
  }
  if (!is.character(start_time) || !nzchar(start_time)) {
    stop("`start_time` must be a non-empty character string (ISO 8601).")
  }
  if (!is.character(end_time) || !nzchar(end_time)) {
    stop("`end_time` must be a non-empty character string (ISO 8601).")
  }
  
  all_data <- list(tweets = list(), users = list())
  next_token <- NULL
  remaining <- max_results
  
  repeat {
    max_results_per_page <- min(100, remaining)
    message("Collecting: ", max_results_per_page, " tweets...")
    
    url <- create_url(query, next_token, max_results_per_page, start_time, end_time, lang, exclude_retweets)
    message("API Call URL:\n", url)
    
    json_response <- connect_to_endpoint(url)
    all_data$tweets <- append(all_data$tweets, json_response$data)
    
    if (!is.null(json_response$includes$users)) {
      all_data$users <- append(all_data$users, json_response$includes$users)
    }
    
    remaining <- remaining - max_results_per_page
    message("Still to collect: ", remaining, " tweets...")
    
    if (remaining <= 0) break
    
    if (!is.null(json_response$meta$next_token)) {
      next_token <- json_response$meta$next_token
      Sys.sleep(1) # To avoid hitting rate limits
    } else {
      break
    }
  }
  
  pool <- fromJSON(toJSON(all_data, pretty = TRUE))
  
  if (!is.null(store_path)) {
    save(pool, file = store_path, compress = TRUE)
  }
  
  return(pool)
}

#####################################
# Robust Search with Retry (429 Errors)
#####################################

#' Robust search that retries on 429 (rate limit) errors
#'
#' @param query Character. The search query.
#' @param max_results Integer. Maximum number of results desired.
#' @param l Unused parameter, kept for compatibility.
#' @param store_path Character. Optional. If provided, save the results to this file.
#' @param max_attempts Integer. Max number of retry attempts.
#' @param sleep Integer. Seconds to sleep before retry.
#'
#' @return Same structure as `search`.
#' @export
robust_search <- function(query, max_results, l = NULL, store_path = NULL, max_attempts = 100, sleep = 90) {
  attempt <- 1
  
  repeat {
    tryCatch({
      search_time <- get_valid_start.end_UTC_time(current_utc_time = get_utc_time())
      
      search.json <- search(
        query = query,
        lang = NULL,
        exclude_retweets = TRUE,
        start_time = search_time$start_time,
        end_time = search_time$end_time,
        max_results = max_results,
        tibble = FALSE,
        store_path = store_path
      )
      return(search.json)
    }, error = function(e) {
      if (grepl("429", e$message)) {
        if (attempt <= max_attempts) {
          message("Rate limit hit (429). Attempt ", attempt, " of ", max_attempts, ". Retrying in ", sleep, " seconds...")
          Sys.sleep(sleep)
          attempt <<- attempt + 1
        } else {
          stop("Maximum retry attempts reached. Unable to complete the search.")
        }
      } else {
        stop(e)
      }
    })
  }
}

#####################################
# Create User Timeline URL
#####################################

#' Create URL for a user's timeline
#'
#' @param user_id Character. The user's ID.
#' @param max_results Integer. Max results per request (5-100).
#' @param exclude_retweets Logical. If TRUE, excludes retweets.
#'
#' @return A character string with the user timeline URL.
#' @export
create_user_timeline_url <- function(user_id, max_results = 100, exclude_retweets = TRUE) {
  if (!nzchar(user_id)) {
    stop("`user_id` must be a non-empty character string.")
  }
  if (max_results < 5 || max_results > 100) {
    stop("`max_results` must be between 5 and 100 for user timeline requests.")
  }
  
  tweet_fields <- paste("attachments,author_id,conversation_id,created_at,entities,geo,id,in_reply_to_user_id,lang",
                        "public_metrics,referenced_tweets,source,text", sep = ",")
  
  base_url <- paste0("https://api.twitter.com/2/users/", user_id, "/tweets?")
  
  url <- paste0(base_url,
                "max_results=", max_results,
                "&tweet.fields=", tweet_fields)
  
  if (exclude_retweets) {
    url <- paste0(url, "&exclude=retweets")
  }
  
  return(url)
}

#####################################
# Get Trends from a Given URL (Trends24)
#####################################

#' Get Twitter trends from a given Trends24 URL
#'
#' @param url Character. The URL to Trends24 page.
#'
#' @details
#' Extracts the top trends from the first trend container on Trends24.
#'
#' @return A character vector of trends, or NULL if none found.
#' @export
get_trends <- function(url) {
  if (!is.character(url) || !nzchar(url)) {
    stop("`url` must be a non-empty character string.")
  }
  
  webpage <- tryCatch(read_html(url), error = function(e) {
    stop("Failed to read URL: ", url, ". Error: ", e$message)
  })
  
  trends <- webpage %>%
    html_nodes(".list-container:nth-child(1) .trend-link") %>%
    html_text(trim = FALSE)
  
  trends <- unique(trends)
  
  if (length(trends) == 0) {
    warning("No trends found. The website structure may have changed.")
    return(NULL)
  }
  
  return(trends)
}

#####################################
# Paginated User Timeline Extraction
#####################################

#' Get a user's tweets with pagination
#'
#' @param user_id Character. The user's ID.
#' @param max_results Integer. Maximum total tweets to retrieve.
#' @param store_path Character. If provided, save results to this path.
#'
#' @return A list of tweets in JSON format.
#' @export
get_user_tweets_paginated <- function(user_id, max_results = 1000, store_path = NULL) {
  if (!nzchar(user_id)) {
    stop("`user_id` must be a non-empty character string.")
  }
  if (!is.numeric(max_results) || max_results < 1) {
    stop("`max_results` must be a positive integer.")
  }
  
  all_tweets <- list()
  next_token <- NULL
  total_tweets <- 0
  
  repeat {
    tweets_left <- max_results - total_tweets
    if (tweets_left <= 0) break
    
    results_per_page <- min(100, max(5, tweets_left))
    url <- create_user_timeline_url(user_id, max_results = results_per_page, exclude_retweets = TRUE)
    
    if (!is.null(next_token)) {
      url <- paste0(url, "&pagination_token=", next_token)
    }
    
    json_response <- connect_to_endpoint(url)
    if (!is.null(json_response$data)) {
      num_new_tweets <- length(json_response$data)
      
      if (total_tweets + num_new_tweets > max_results) {
        num_tweets_to_add <- max_results - total_tweets
        all_tweets <- append(all_tweets, json_response$data[1:num_tweets_to_add])
        total_tweets <- total_tweets + num_tweets_to_add
        break
      } else {
        all_tweets <- append(all_tweets, json_response$data)
        total_tweets <- total_tweets + num_new_tweets
      }
    }
    
    if (!is.null(json_response$meta$next_token)) {
      next_token <- json_response$meta$next_token
    } else {
      break
    }
    
    Sys.sleep(1)
  }
  
  tweets <- fromJSON(toJSON(list(data = all_tweets), pretty = TRUE))
  
  if (!is.null(store_path)) {
    save(tweets, file = store_path, compress = TRUE)
  }
  
  return(tweets)
}

#####################################
# Robust Version of User Timeline Retrieval
#####################################

#' Robust retrieval of user tweets with retries
#'
#' @param user_id Character. User ID.
#' @param max_results Integer. Maximum tweets to retrieve.
#' @param store_path Character. Optional file path to save results.
#' @param max_retries Integer. Max number of retries if errors occur.
#' @param sleep Integer. Sleep time in seconds between retries.
#'
#' @return A list of tweets.
#' @export
robust_get_user_tweets <- function(user_id, max_results = 1000, store_path = NULL, max_retries = 100, sleep = 120) {
  
  if (!nzchar(user_id)) {
    stop("`user_id` must be a non-empty character string.")
  }
  
  retry_count <- 0
  success <- FALSE
  this_user_tweets <- NULL
  
  while (!success && retry_count < max_retries) {
    tryCatch({
      this_user_tweets <- get_user_tweets_paginated(user_id, max_results, store_path)
      success <- TRUE
    }, error = function(e) {
      message("Error occurred: ", e$message)
    })
    
    if (!success) {
      retry_count <- retry_count + 1
      if (retry_count < max_retries) {
        message("Attempt ", retry_count, " failed. Retrying in ", sleep, " seconds...")
        Sys.sleep(sleep)
      } else {
        stop("Failed to fetch tweets after ", max_retries, " retries.")
      }
    }
  }
  
  return(this_user_tweets)
}


