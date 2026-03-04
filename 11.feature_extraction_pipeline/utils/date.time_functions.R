# Load required libraries
library(lubridate)
library(httr)

#####################################
# Get UTC Time from a Reliable Source
#####################################

#' Fetch the current UTC time from timeapi.io, fallback to system time if unavailable.
#'
#' This function attempts to call the Time API (timeapi.io) to retrieve the current UTC time.
#' If that fails (non-200 status, parsing issues, etc.), it falls back to using the machine's
#' local system time. The returned format is ISO 8601 with 'Z' denoting UTC.
#'
#' @return A character string in "YYYY-MM-DDTHH:MM:SSZ" format.
#' @throws A warning if the Time API request fails, but system time is returned instead.
get_utc_time <- function() {
  api_url <- "https://timeapi.io/api/Time/current/zone?timeZone=Etc/UTC"
  
  response <- tryCatch(
    GET(api_url),
    error = function(e) NULL
  )
  
  if (is.null(response) || status_code(response) != 200) {
    warning("Failed to retrieve time from timeapi.io, falling back to system time.")
    return(format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  }
  
  data <- content(response, "parsed")
  
  if (is.null(data$dateTime)) {
    warning("No dateTime field returned by timeapi.io, falling back to system time.")
    return(format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  }
  
  # Remove fractional seconds from the returned datetime
  datetime_str <- sub("\\..+$", "", data$dateTime)
  
  # Parse the datetime without fractional seconds
  datetime <- as.POSIXct(datetime_str, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  
  if (is.na(datetime)) {
    warning("Failed to parse dateTime from timeapi.io, falling back to system time.")
    datetime <- Sys.time()
  }
  
  format(datetime, "%Y-%m-%dT%H:%M:%SZ")
}

######################################
# Extract Latest Date/Time from Names #
######################################

#' Extract the latest date/datetime from a set of filenames.
#'
#' @param filenames Character vector of filenames containing timestamps in "YYYY-MM-DD HH:MM:SS".
#' @param time Logical; if TRUE, return a POSIXct datetime, else return a Date.
#'
#' @return The latest date as a Date or POSIXct object. NA if none found.
extract_latest_date <- function(filenames, time = FALSE) {
  if (!is.character(filenames) || length(filenames) == 0) {
    stop("`filenames` must be a non-empty character vector.")
  }
  
  date_time_strings <- gsub(".*(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}).*", "\\1", filenames)
  date_times <- as.POSIXct(date_time_strings, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
  
  if (all(is.na(date_times))) {
    warning("No valid datetime strings found in filenames.")
    return(NA)
  }
  
  latest_date_time <- max(date_times, na.rm = TRUE)
  
  if (time) {
    latest_date_time
  } else {
    as.Date(latest_date_time)
  }
}

#########################################
# Get Valid Start and End UTC Timestamps #
#########################################

#' Compute valid start and end UTC timestamps within the 7-day window.
#'
#' @param current_utc_time Character string in "YYYY-MM-DDTHH:MM:SSZ" UTC format.
#' @param start_seconds_prior Integer. Seconds before `current_utc_time` for the start time.
#' @param end_seconds_prior Integer. Seconds before `current_utc_time` for the end time.
#'
#' @details
#' Given `current_utc_time`, this sets:
#' - `start_time` to ~7 days minus 10 hours before the current time,
#' - `end_time` to 10 seconds before the current time.
#'
#' Adjusting the start time well within the 7-day window avoids invalid request errors.
#'
#' @return A named list with `start_time` and `end_time` in ISO 8601 UTC format.
get_valid_start.end_UTC_time <- function(
    current_utc_time,
    start_seconds_prior = (60 * 60 * 24 * 7) - (60 * 60 * 10), # 7 days minus 10 hours
    end_seconds_prior = 10
) {
  if (!is.character(current_utc_time) || length(current_utc_time) != 1) {
    stop("`current_utc_time` must be a single character string in UTC ISO 8601 format.")
  }
  
  datetime <- as.POSIXct(current_utc_time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  if (is.na(datetime)) {
    stop("`current_utc_time` is not in a valid ISO 8601 UTC format.")
  }
  
  start_time <- format(datetime - start_seconds_prior, "%Y-%m-%dT%H:%M:%SZ")
  end_time   <- format(datetime - end_seconds_prior, "%Y-%m-%dT%H:%M:%SZ")
  
  list(start_time = start_time, end_time = end_time)
}

##############################
# Add Noise to a Given Time  #
##############################

#' Add random noise (±h hours) to a given time.
#'
#' @param date_str A character string in a valid UTC datetime format.
#' @param h Integer. Max number of hours in either direction to add as noise.
#'
#' @return A character string in "YYYY-MM-DDTHH:MM:SS.000Z" format after adding noise.
add_noise_to_time <- function(date_str, h = 12) {
  if (!is.character(date_str) || length(date_str) != 1) {
    stop("`date_str` must be a single character string.")
  }
  
  original_time <- ymd_hms(date_str, tz = "UTC")
  if (is.na(original_time)) {
    stop("`date_str` could not be parsed as a valid datetime.")
  }
  
  noise_seconds <- sample((-h * 3600):(h * 3600), 1)
  new_time <- original_time + dseconds(noise_seconds)
  
  format(new_time, "%Y-%m-%dT%H:%M:%S.000Z")
}
