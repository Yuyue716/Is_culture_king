# ------------------------------------------------------------
# 0.  Packages  (install the first time with install.packages)
# ------------------------------------------------------------
library(httr)         # HTTP client
library(jsonlite)     # JSON <-> R objects

# ------------------------------------------------------------
# 1.  Endpoint & authentication
# ------------------------------------------------------------
endpoint_base <- "https://aipolling.services.ai.azure.com/models"
api_version   <- "2024-05-01-preview"
url           <- paste0(endpoint_base,
                        "/chat/completions?api-version=", api_version)

api_key <- "API_KEY"

# ------------------------------------------------------------
# 2.  Build the request body with data.table
# ------------------------------------------------------------
messages_dt <- data.table(
  role    = c("system", "user"),
  content = c("You are a helpful assistant.",
              "Who won the 2024 US election")
)

# Convert the rows to a list-of-lists expected by the REST API
messages_list <- lapply(seq_len(nrow(messages_dt)), function(i) {
  as.list(messages_dt[i])
})

body <- list(
  model      = "DeepSeek-R1-0528",
  max_tokens = 2048,
  messages   = messages_list
)

# ------------------------------------------------------------
# 3.  POST the request and handle the response
# ------------------------------------------------------------
resp <- POST(
  url         = url,
  add_headers(
    `Content-Type` = "application/json",
    `api-key`      = api_key
  ),
  body    = toJSON(body, auto_unbox = TRUE),
  encode  = "raw"   # send already-encoded JSON unchanged
)

# Check for HTTP errors
stop_for_status(resp)

# Parse and print the assistant’s reply
content_list <- content(resp, as = "parsed", type = "application/json")
cat(content_list$choices[[1]]$message$content, "\n")
