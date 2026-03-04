# Utility libraries
library(imguR)
library(pdftools)
library(magick)
library(jsonlite)
library(httr)
library(plumber)
library(utils)

##############################
# Authentication with Imgur  #
##############################

#' Obtain Imgur Authorization Code
#'
#' @param client_id Your Imgur application client ID.
#' @param client_secret Your Imgur application client secret.
#'
#' @details
#' This function helps obtain an authorization code from Imgur. It prints a URL 
#' that you must open in your browser. After authorizing the application, 
#' Imgur will redirect you with a code that you should paste into R.
#'
#' @return A character string containing the authorization code.
#' @export
get_imgur_auth <- function(client_id, client_secret) {
  if (!is.character(client_id) || !nzchar(client_id)) {
    stop("`client_id` must be a non-empty character string.")
  }
  if (!is.character(client_secret) || !nzchar(client_secret)) {
    stop("`client_secret` must be a non-empty character string.")
  }
  
  authorize_url <- "https://api.imgur.com/oauth2/authorize"
  params <- list(client_id = client_id, response_type = "code")
  authorize_link <- httr::modify_url(authorize_url, query = params)
  
  cat("Please go to the following URL and authorize the application:\n", authorize_link, "\n")
  auth_code <- readline(prompt = "Enter the code from the URL after authorization: ")
  
  return(auth_code)
}

#' Exchange Authorization Code for Access Token
#'
#' @param client_id Your Imgur application client ID.
#' @param client_secret Your Imgur application client secret.
#' @param auth_code The authorization code obtained from `get_imgur_auth`.
#'
#' @return A character string containing the access token.
#' @export
get_imgur_token <- function(client_id, client_secret, auth_code) {
  if (!is.character(auth_code) || !nzchar(auth_code)) {
    stop("`auth_code` must be a non-empty character string.")
  }
  
  token_url <- "https://api.imgur.com/oauth2/token"
  body <- list(
    client_id = client_id,
    client_secret = client_secret,
    grant_type = "authorization_code",
    code = auth_code
  )
  
  response <- POST(token_url, body = body, encode = "form")
  if (response$status_code != 200) {
    stop("Failed to exchange authorization code for token. Status code: ", response$status_code)
  }
  
  token <- content(response, as = "parsed", type = "application/json")
  if (is.null(token$access_token)) {
    stop("Access token not found in the response.")
  }
  
  return(token$access_token)
}

###########################
# Uploading Images to Imgur
###########################

#' Upload an Image to Imgur with Retry Logic
#'
#' @param image_path Character. Path to the image file to upload.
#' @param access_token Character. Valid Imgur OAuth access token.
#' @param verbose Logical. If TRUE, prints more detailed logs.
#'
#' @details
#' This function attempts to upload an image to Imgur. It includes retry logic 
#' for network-related issues (specifically `HTTP/2 stream was not closed cleanly`) 
#' and lexical errors. If the upload still fails after a set number of retries, 
#' it returns an error object.
#'
#' @return A list with success/failure details.
#' @export
upload_image <- function(image_path, access_token, verbose = FALSE) {
  if (!file.exists(image_path)) {
    stop("Image file does not exist: ", image_path)
  }
  if (!is.character(access_token) || !nzchar(access_token)) {
    stop("`access_token` must be a non-empty character string.")
  }
  
  imgur_upload_url <- "https://api.imgur.com/3/image"
  max_retries <- 100
  retry_delay <- 90
  attempts <- 0
  
  repeat {
    response <- tryCatch({
      POST(
        url = imgur_upload_url,
        add_headers(Authorization = paste("Bearer", access_token)),
        body = list(image = upload_file(image_path)),
        encode = "multipart"
      )
    }, error = function(e) {
      # Retry on the specific HTTP/2 error
      if (grepl("HTTP/2 stream 0 was not closed cleanly: STREAM_CLOSED", e$message)) {
        attempts <<- attempts + 1
        if (attempts >= max_retries) {
          return(list(
            status = NULL,
            success = FALSE,
            error = "Non-recoverable error after maximum retries: HTTP/2 stream issue."
          ))
        }
        Sys.sleep(retry_delay)
        return(NULL)
      } else {
        stop(e) # Other errors: rethrow
      }
    })
    
    # If response is NULL, we encountered the handled error and will retry
    if (is.null(response)) next
    
    # Check success status codes
    if (response$status_code >= 200 && response$status_code < 300) {
      # Parse JSON
      result <- tryCatch({
        content(response, as = "parsed", type = "application/json")
      }, error = function(e) {
        return(NULL)
      })
      
      if (!is.null(result) && isTRUE(result$success)) {
        return(result)
      } else {
        # If verbose, print raw response
        if (verbose) {
          print(content(response, "text", encoding = "UTF-8"))
        }
        return(list(
          status = response$status_code,
          success = FALSE,
          error = result
        ))
      }
    } else {
      if (verbose) {
        print(content(response, "text", encoding = "UTF-8"))
      }
    }
    
    # Check for lexical error in response
    content_text <- tryCatch({
      content(response, "text", encoding = "UTF-8")
    }, error = function(e) {
      ""
    })
    
    if (grepl("lexical error: invalid char in json text", content_text)) {
      attempts <- attempts + 1
      if (attempts >= max_retries) {
        return(list(
          status = response$status_code,
          success = FALSE,
          error = "Non-recoverable error after maximum retries due to lexical errors."
        ))
      }
      Sys.sleep(retry_delay)
    } else {
      # If no lexical error, break out of loop
      break
    }
  }
  
  return(list(
    status = response$status_code,
    success = FALSE,
    error = "Upload failed without a recoverable error."
  ))
}

###################################
# Robust File Download with Retries
###################################

#' Download a File with Multiple Retries
#'
#' @param input_url Character. The URL of the file to download.
#' @param dest_path Character. The path where the downloaded file should be saved.
#' @param max_retries Integer. Maximum number of retry attempts.
#'
#' @details
#' This function attempts to download a file repeatedly if it fails. After 
#' `max_retries`, it stops and throws an error.
#'
#' @return The path of the successfully downloaded file.
#' @export
download_with_retry <- function(input_url, dest_path, max_retries = 100) {
  if (!is.character(input_url) || !nzchar(input_url)) {
    stop("`input_url` must be a non-empty character string.")
  }
  if (!is.character(dest_path) || !nzchar(dest_path)) {
    stop("`dest_path` must be a non-empty character string.")
  }
  
  retry_count <- 0
  success <- FALSE
  error_message <- NULL
  
  while (retry_count < max_retries && !success) {
    tryCatch({
      download.file(
        url = input_url, 
        destfile = dest_path, 
        mode = "wb",
        quiet = TRUE
      )
      success <- TRUE
    }, error = function(e) {
      retry_count <<- retry_count + 1
      error_message <<- conditionMessage(e)
      if (retry_count < max_retries) {
        message("Download failed, retrying (", retry_count, "/", max_retries, ")...")
        message("Error message: ", error_message)
      } else {
        message("Unrecoverable error after ", max_retries, " attempts.")
        message("Error message: ", error_message)
      }
    })
  }
  
  if (success) {
    return(dest_path)
  } else {
    stop("Failed to download the file after ", max_retries, " attempts. Error message: ", error_message)
  }
}

######################################
# Convert PDF to Image and Upload it  #
######################################

#' Convert a PDF page to an image and Upload to Imgur
#'
#' @param input.url Character. Optional. If provided, the PDF will be downloaded from this URL.
#' @param pdf.path Character. Path to the PDF file.
#' @param page Integer. Page number to render. Defaults to 1.
#' @param dpi Integer. DPI for PDF rendering. Defaults to 300.
#' @param resize.factor Numeric. Resize factor for the image (e.g., 1/3).
#' @param format Character. Image format to convert to, defaults to 'png'.
#'
#' @details
#' - Downloads PDF if `input.url` is provided.
#' - Converts the specified page of the PDF to an image.
#' - Resizes the image.
#' - Attempts to upload the image to Imgur with retry logic.
#'
#' @return A list (JSON-like) from Imgur containing links and success info.
#' @export
pdf_to_url <- function(
    input.url = NULL,
    pdf.path,
    page = 1, 
    dpi = 300,
    resize.factor = 1/3,
    format = 'png',
    access_token
) {
  if (!is.null(input.url)) {
    message("Downloading PDF from: ", input.url)
    download_with_retry(input.url, pdf.path)
  }
  
  if (!file.exists(pdf.path)) {
    stop("PDF file not found: ", pdf.path)
  }
  
  message("Rendering PDF from: ", pdf.path)
  pdf_page <- pdf_render_page(pdf.path, page = page, dpi = dpi)
  
  image <- image_read(pdf_page)
  
  message("Resizing image...")
  info <- image_info(image)
  original_width <- info$width
  original_height <- info$height
  aspect_ratio <- original_width / original_height
  new_width <- original_width * resize.factor
  new_height <- round(new_width / aspect_ratio)
  
  image <- image_resize(image, paste0(new_width, "x", new_height))
  
  output_path <- gsub('pdf$', format, pdf.path)
  message("Saving ", format, " to: ", output_path)
  image_write(image, path = output_path, format = format)
  
  message("Starting image upload to Imgur...")
  
  wait_time <- 90
  retries <- 100
  attempt <- 0
  success <- FALSE
  
  while (attempt <= retries && !success) {
    attempt <- attempt + 1
    message("Upload attempt: ", attempt)
    
    imgur_upload <- upload_image(image_path = output_path, access_token = access_token)
    success <- isTRUE(imgur_upload$success)
    
    if (success) {
      message("Upload successful on attempt ", attempt)
    } else {
      # Handle error and retry after waiting
      message("Error on attempt ", attempt, ": ", imgur_upload$error)
      if (attempt < retries) {
        message("Waiting ", wait_time, " seconds before retrying...")
        Sys.sleep(wait_time)
      }
    }
  }
  
  if (!success) {
    stop("Failed to upload the image after ", retries, " attempts.")
  }
  
  return(imgur_upload)
}
