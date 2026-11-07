library(tools)
library(R.utils)
source('utils/UvA_LLM_endpoint_functions.R')

#' Attempt a single GPT call with timeout and error handling
#'
#' @param messages.list A list of messages to send to the model.
#' @param model Character. Name of the model to use.
#' @param temperature Numeric. Temperature parameter for generation.
#' @param max_tokens Integer. Maximum tokens for completion.
#' @param timeout Numeric. Timeout in seconds.
#'
#' @return A response object from `create_chat_completion_UvA`, or an error object.
attempt_gpt_call <- function(messages.list, 
                             model,     
                             temperature = 0,
                             timeout = 120,
                             max_tokens = 4096L) {
  tryCatch(
    withTimeout({
      gc()
      create_chat_completion(
        model = model,
        temperature = temperature,
        messages = messages.list,
        max_tokens = max_tokens
      )
    }, timeout = timeout),
    error = function(e) {
      message("Error during GPT call: ", e$message)
      return(e)
    }
  )
}

#' Call GPT with retries and fallback logic
#'
#' @param messages.list A list structured as required by the model endpoint (role/content).
#' @param model Character. Model name to be used.
#' @param temperature Numeric. Defaults to 0. 
#' @param timeout Numeric. Timeout in seconds, defaults to 120.
#' @param max_tokens Integer. Defaults to 4096.
#'
#' @details
#' The function attempts to call the GPT model using `create_chat_completion_UvA`.
#' On failure, it retries. If the error is related to an image, it tries falling back 
#' to a text-only prompt. It also checks if the returned response contains an immediate apology
#' ("I'm sorry"), and if so, treats it as an error and retries.
#'
#' @return The completion response object from GPT on success.
call_gpt <- function(
    messages.list,
    model,
    temperature = 0,
    timeout = 120,
    max_tokens = 4096
) {
  # Basic argument validation
  if (!is.list(messages.list) || length(messages.list) == 0) {
    stop("`messages.list` must be a non-empty list of messages.")
  }
  
  if (!is.character(model) || length(model) != 1) {
    stop("`model` must be a single character string.")
  }
  
  if (!is.numeric(temperature) || temperature < 0 || temperature > 2) {
    stop("`temperature` must be a numeric value between 0 and 2.")
  }
  
  # Helper for logging attempts
  log_prompt <- function(msg.list) {
    msg_contents <- lapply(msg.list[[1]]$content, function(x) {
      paste0(x$type, ": ", if (!is.null(x$text)) x$text else paste("URL:", x$image_url$url))
    })
    message("==== GPT CALL LOG ====",
            "\nModel: ", model,
            "\nTemperature: ", temperature,
            "\nUser Messages:\n", paste(msg_contents, collapse = "\n"))
  }
  
  # Initial call
  log_prompt(messages.list)
  gen <- attempt_gpt_call(messages.list, model, temperature, max_tokens, timeout)
  
  # Check for apology-based "error" from model
  if (is.list(gen) && !is.null(gen$choices)) {
    content <- gen$choices$message.content
    if (length(content) > 0 && grepl("I'm sorry", content, ignore.case = TRUE)) {
      message("Apology detected in response, treating as error and retrying...")
      gen <- structure(list(message = "Apology detected in response"), class = "error")
    }
  }
  
  # Handle image download errors
  if (inherits(gen, "error") && any(grepl('downloading', unlist(gen)))) {
    warning("ERROR WHILE DOWNLOADING IMAGE. Please ensure image format is correct (e.g. '_normal'). Returning error object.")
    return(gen)
  }
  
  # If invalid image, fallback to text-only
  if (inherits(gen, "error") && any(grepl('Invalid image.', unlist(gen)))) {
    message("Invalid image detected. Falling back to text-only prompt...")
    # Remove image content from the prompt
    messages.list[[1]]$content <- list(messages.list[[1]]$content[[1]])
    log_prompt(messages.list)
    gen <- attempt_gpt_call(messages.list, model, temperature, max_tokens, timeout)
  }
  
  # Retry logic for any remaining errors
  max_retries <- 3
  attempt <- 1
  while (inherits(gen, "error") && attempt <= max_retries) {
    message("GPT CALL FAILED (", toupper(gen$message), "). RETRYING... (Attempt ", attempt, " of ", max_retries, ")")
    log_prompt(messages.list)
    gen <- attempt_gpt_call(messages.list, model, temperature, max_tokens, timeout)
    attempt <- attempt + 1
  }
  
  # If still error after retries, propagate the error
  if (inherits(gen, "error")) {
    stop("Failed to get a successful response after multiple retries: ", gen$message)
  }
  
  return(gen)
}

#' Prepare a default GPT message structure
#'
#' @return A list containing a default user message.
prep_gpt_messages <- function() {
  list(
    list(
      "role" = "user",
      "content" = list(
        list("type" = "text", "text" = "")
      )
    )
  )
}

#' Prepare GPT image prompt content
#'
#' @param image_url Character. URL of the user's image.
#' @param X_size Optional size parameter to be removed from the URL pattern.
#'
#' @return A list containing either an image_url object or a text fallback.
prep_gpt_image <- function(image_url, X_size = NULL) {
  # Remove any specified size substring from the URL if provided
  if (!is.null(X_size)) {
    message("Resized X image by removing '", X_size, "' from the URL.")
    image_url <- gsub(X_size, "", image_url)
  }
  
  # Supported extensions
  supported_extensions <- c("png", "jpg", "jpeg", "gif", "webp")
  
  if (file_ext(image_url) %in% supported_extensions) {
    message("Image file extension is supported. Finalizing image object.")
    return(list('type' = "image_url", "image_url" = list("url" = image_url)))
  } else {
    warning("Image file extension is NOT supported. Using 'No-image' text in prompt.")
    return(list('type' = "text", 'text' = 'A profile picture is not available for this user.'))
  }
}

#' Append content to GPT messages
#'
#' @param gpt_messages The existing message list.
#' @param new_content The new content to append.
#'
#' @return The updated message list.
append_gpt_content <- function(gpt_messages, new_content) {
  gpt_messages[[1]]$content[[length(gpt_messages[[1]]$content) + 1]] <- new_content
  gpt_messages
}