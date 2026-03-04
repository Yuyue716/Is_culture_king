library("assertthat")
library("httr")
library("jsonlite")
library("glue")

print_example_message <- function(){
  cat('
  message <- list(
    role = "user",
    content = list(
      list(
        type = "text",
        text = "Whats in this image?"
      ),
      list(
        type = "image_url",
        image_url = list(
          url = "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
        )
      )
    )
  )')
}


create_chat_completion <- function(
    model,
    messages = NULL,
    temperature = 1,
    top_p = 1,
    n = 1,
    stream = FALSE,
    stop = NULL,
    max_tokens = NULL,
    presence_penalty = 0,
    frequency_penalty = 0,
    logit_bias = NULL,
    user = NULL,
    openai_api_key = "sk-zmBakjNVbI9i1rMoT5FIIA",
    openai_organization = NULL
) {
  # Load required packages
  requireNamespace("assertthat")
  requireNamespace("httr")
  requireNamespace("jsonlite")
  requireNamespace("glue")
  
  # Define a helper function to check value bounds BEFORE it is used
  value_between <- function(x, lower, upper) x >= lower && x <= upper
  
  # Validate arguments (mirroring openai::create_chat_completion)
  assertthat::assert_that(assertthat::is.string(model), assertthat::noNA(model))
  if (!is.null(messages)) {
    assertthat::assert_that(is.list(messages))
  }
  assertthat::assert_that(assertthat::is.number(temperature), 
                          assertthat::noNA(temperature), value_between(temperature, 0, 2))
  assertthat::assert_that(assertthat::is.number(top_p), 
                          assertthat::noNA(top_p), value_between(top_p, 0, 1))
  
  both_specified <- function(x, y) !is.null(x) && !is.null(y) && x != 1 && y != 1
  if (both_specified(temperature, top_p)) {
    warning("It is recommended NOT to specify temperature and top_p at the same time.")
  }
  
  assertthat::assert_that(assertthat::is.count(n))
  assertthat::assert_that(assertthat::is.flag(stream), assertthat::noNA(stream), isFALSE(stream))
  if (!is.null(stop)) {
    length_between <- function(x, lower, upper) length(x) >= lower && length(x) <= upper
    assertthat::assert_that(is.character(stop), assertthat::noNA(stop), length_between(stop, 1, 4))
  }
  if (!is.null(max_tokens)) {
    assertthat::assert_that(assertthat::is.count(max_tokens))
  }
  assertthat::assert_that(assertthat::is.number(presence_penalty), 
                          assertthat::noNA(presence_penalty), value_between(presence_penalty, -2, 2))
  assertthat::assert_that(assertthat::is.number(frequency_penalty), 
                          assertthat::noNA(frequency_penalty), value_between(frequency_penalty, -2, 2))
  if (!is.null(logit_bias)) {
    assertthat::assert_that(is.list(logit_bias))
  }
  if (!is.null(user)) {
    assertthat::assert_that(assertthat::is.string(user), assertthat::noNA(user))
  }
  assertthat::assert_that(assertthat::is.string(openai_api_key), assertthat::noNA(openai_api_key))
  if (!is.null(openai_organization)) {
    assertthat::assert_that(assertthat::is.string(openai_organization), assertthat::noNA(openai_organization))
  }
  
  # Adapt this to the UvA Azure API endpoint
  task <- "chat/completions"
  base_url <- glue::glue("https://ai-research-proxy.azurewebsites.net/v1/{task}")
  
  headers <- c(
    Authorization = paste("Bearer", openai_api_key),
    `Content-Type` = "application/json"
  )
  
  if (!is.null(openai_organization)) {
    headers["OpenAI-Organization"] <- openai_organization
  }
  
  body <- list(
    model = model,
    messages = messages,
    temperature = temperature,
    top_p = top_p,
    n = n,
    stream = stream,
    stop = stop,
    max_tokens = max_tokens,
    presence_penalty = presence_penalty,
    frequency_penalty = frequency_penalty,
    logit_bias = logit_bias,
    user = user
  )
  
  response <- httr::POST(url = base_url, httr::add_headers(.headers = headers), 
                         body = body, encode = "json")
  
  verify_mime_type <- function(r) {
    ct <- httr::headers(r)[["content-type"]]
    if (!is.null(ct) && !grepl("application/json", ct, ignore.case = TRUE)) {
      warning("Response is not in JSON format.")
    }
  }
  verify_mime_type(response)
  
  parsed <- response %>% httr::content(as = "text", encoding = "UTF-8") %>% 
    jsonlite::fromJSON(flatten = TRUE)
  
  if (httr::http_error(response)) {
    stop(
      paste0("UvA API request failed [", httr::status_code(response), "]:\n\n", parsed$error$message), 
      call. = FALSE
    )
  }
  
  parsed
}

