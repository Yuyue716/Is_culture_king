# ------------------------------------------------------------
# 0.  Packages ▸ Working Directory ▸ Options 
# ------------------------------------------------------------

rm(list = ls()); gc()                     # start fresh
options(scipen = 999, timeout = 1e4)      # nicer printing & long time-outs
setwd("~/Dropbox/is_culture_king/")       # adjust as needed

library(data.table)                       # core data manipulation engine
library(digest)                           # need to merge subjects with metadata on hashed id 

# ── helpers ────────────────────────────────────────────────────────────

## 0-a ▸ collapse any list-cell to one string ---------------------------
collapse_or_keep <- function(col, sep = ";") {
  if (!is.list(col)) return(col)              # already atomic → leave alone
  
  vapply(col, function(x) {
    if (length(x) == 0L) return(NA_character_)     # NULL / length-0 → NA
    
    vals <- unlist(x, recursive = TRUE, use.names = TRUE)
    
    nms  <- names(vals)                           # element names (can be NULL)
    parts <- if (is.null(nms)) {
      as.character(vals)
    } else {
      ifelse(nzchar(nms), paste0(nms, ".", vals), vals)
    }
    
    paste(parts, collapse = sep)                  # ↩︎ one string
  }, character(1))
}

# ------------------------------------------------------------
# 1.  Load subject pool of x profiles
# ------------------------------------------------------------

## loop through every saved “pool” file ---------------------------
pool_dir   <- "original_data/x_users_data/user_pool_profiles/"
pool_files <- list.files(pool_dir, full.names = TRUE)
pool_dt    <- data.table()                                   # accumulator

for (f in pool_files) {
  
  load(f)                               # object "pool" (with $users & $tweets)
  
  # ── sanity-check users & tweets objects ------------------------------
  users_ok  <- !is.null(pool$users)  && nrow(as.data.table(pool$users))  > 0L
  tweets_ok <- !is.null(pool$tweets) && nrow(as.data.table(pool$tweets)) > 0L
  
  if (!users_ok || !tweets_ok) {
    warning(sprintf("‘%s’ – users or tweets table is missing / empty; skipping file.",
                    basename(f)))
    next                              # ⤴︎ move on to the next pool file
  }
  
  # ── users ------------------------------------------------------------
  users_tmp <- as.data.table(pool$users)
  users_tmp[, (names(users_tmp)) := lapply(.SD, collapse_or_keep)]
  
  # ── tweets -----------------------------------------------------------
  tweets_tmp <- as.data.table(pool$tweets)
  tweets_tmp[, (names(tweets_tmp)) := lapply(.SD, collapse_or_keep)]
  tweets_tmp[, created_at :=
               as.POSIXct(created_at, format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")]
  
  # ── merge & annotate -------------------------------------------------
  pool_dt_tmp <- merge(
    users_tmp, tweets_tmp,
    by.x = "id", by.y = "author_id", all = TRUE
  )
  
  ## rename duplicate-resolution suffixes: .x → .users, .y → .tweets ----
  new_names <- 
    gsub("\\.x$",     ".users",
    gsub("\\.y$",     ".tweets",
    names(pool_dt_tmp))
    )
  setnames(pool_dt_tmp, new_names)  
  
  ## where did this pool come from?
  fname <- basename(f)
  pool_dt_tmp[, pool_type :=
                trimws(gsub("twitter substantive talk", "", gsub("_", " ", fname)))]
  
  # extract the first date(-time) pattern from the file name
  date_txt <- regmatches(
    fname,
    regexpr("\\d{4}-\\d{2}-\\d{2}(?:[ _]\\d{2}[:\\-]\\d{2}[:\\-]\\d{2})?", fname, perl = TRUE)
  )
  
  # normalise separators (underscores → space, dashes in time → colons)
  date_txt <- gsub("_", " ", date_txt, fixed = TRUE)
  date_txt <- sub("(\\d{2})-(\\d{2})-(\\d{2})$", "\\1:\\2:\\3", date_txt)  # 12-34-56 → 12:34:56
  
  # choose the right format string and parse straight to POSIXct
  fmt <- if (nchar(date_txt) == 10) "%Y-%m-%d" else "%Y-%m-%d %H:%M:%S"
  pool_dt_tmp[, sampling_date := as.POSIXct(date_txt, format = fmt, tz = "UTC")]
  
  pool_dt <- rbindlist(list(pool_dt, pool_dt_tmp), fill = TRUE)
}
# rename the plain text → sampling_tweet
setnames(pool_dt, "text", "sampling_tweet")

# save subject pool dataset as csv
fwrite(pool_dt,file = 'generated_data/subject_pool.csv')

# ------------------------------------------------------------
# 2.  Load x users for which we have a history of tweets
# ------------------------------------------------------------

## loop through every saved “user_tweets” file ---------------------------
tweets_dir   <- "original_data/x_users_data/user_tweets/"
tweets_files <- list.files(tweets_dir, full.names = TRUE,recursive = T)
tweets_dt    <- data.table()    

for (f in tweets_files) {
  
  load(f)   # loads full_user_object
  
  # ── sanity-check timeline exists & non-empty -----------------------------
  timeline_ok <- !is.null(full_user_object$timeline_tweets) &&
    nrow(as.data.table(full_user_object$timeline_tweets)) > 0L
  if (!timeline_ok) {
    warning(sprintf("‘%s’ – timeline missing / empty; skipping file.",
                    basename(f)))
    next
  }
  
  # turn timeline into a DT
  tweets_tmp <- as.data.table(full_user_object$timeline_tweets)
  
  # collapse any list‐columns
  tweets_tmp[, (names(tweets_tmp)) := lapply(.SD, collapse_or_keep)]
  
  # parse the timestamp
  tweets_tmp[, created_at := as.POSIXct(
    created_at,
    format = "%Y-%m-%dT%H:%M:%OS",
    tz     = "UTC"
  )]
  
  # bind into the main table
  tweets_dt <- rbindlist(list(tweets_dt, tweets_tmp), fill = TRUE)
  
}
# rename text → tweets_history
setnames(tweets_dt, "text", "tweets_historical")

# save tweets history dataset
fwrite(tweets_dt,file = 'generated_data/tweets_historical.csv')

# ------------------------------------------------------------
# 3.  Get merged dataset for users for whom we have full timeline 
# ------------------------------------------------------------

study_subjects <-
  merge(
    pool_dt,
    tweets_dt,
    all.y = TRUE,
    by.x = 'id',
    by.y = 'author_id',
    allow.cartesian=TRUE
    )
## rename duplicate-resolution suffixes: .x → .users, .y → .tweets ----
new_names <- 
  gsub("\\.x$",     ".subject_pool",
       gsub("\\.y$",     ".tweets_historical",
            names(study_subjects))
  )
setnames(study_subjects, new_names)  

# save study subjects dataset
fwrite(study_subjects,file = 'generated_data/subjects.csv')

# add metadata from early gpt screeing / quota samping 
sampling_metadata <- fread(file = 'original_data/x_users_data/sampling_metadata.csv')
study_subjects$gpt_id <- vapply(
  as.character(study_subjects$id),          
  FUN   = function(x) digest(x, algo="sha256"),
  FUN.VALUE = character(1)
)

study_subjects <-
  merge(
    study_subjects,
    sampling_metadata,
    by = 'gpt_id',
    allow.cartesian = TRUE
  )

# save the subjects + metadata file 
fwrite(study_subjects,file = 'generated_data/subjects_AND_sampling_metadata.csv')
dim(study_subjects)
