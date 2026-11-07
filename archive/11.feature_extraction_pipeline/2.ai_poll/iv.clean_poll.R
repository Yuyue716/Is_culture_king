# clean workspace
rm(list = ls())
# clean garbadge
gc()
# clear graphics device
# dev.off()
# set decimals to digits instead of scientific
options(scipen = 999)
# set timeout limit (laxed)
options(timeout = 10000)
# set work directory
setwd(dir = "~/Desktop/Mechanical Pollster - is Culture King ?/")

# load utils
library(data.table)
library(questionr)

# Sample function is useful but buggy -
# if you specify a single integer it returns a sequence up to that integer
sample = function(x, size, replace = F, prob = NULL) {
  if (length(x) == 1) return(x)
  base::sample(x, size = size, replace = replace, prob = prob)
}

# function to get only files from directory (and ignore folders)
get_files_from_dir <- 
  function(dir){
    # Get directory of pool files 
    all_items <- list.files(path = dir, full.names = TRUE)
    
    # Get the information about each item
    info <- file.info(all_items)
    
    # Filter out directories and keep only files
    files <- all_items[!info$isdir]
    
    # Return files names
    return(files)
  }

# useful for cleanup - extract everything before the first hyphen
extract_before_hyphen <- 
  function(text) {
    sub(" -.*", "", text)
    }

# useful combine function to deal with updates in code
combine.cols <- 
  function(x,name,f){
    x <- as.data.table(apply(x,1,f))
    names(x) <- name
    return(x)
  }

# wordcloud utils 
library(tm)
library(wordcloud)
library(RColorBrewer)

# majority class function for aggregating categorical variables 
majority_class <- function(x) {
  # Remove missing values
  non_missing <- x[!is.na(x)]
  
  # Check if all values are missing
  if (length(non_missing) == 0) {
    return(NA)
  }
  
  # Calculate the frequency of each class
  class_freq <- table(non_missing)
  
  # Find the class(es) with the maximum frequency
  max_classes <- names(class_freq)[class_freq == max(class_freq)]
  
  # If there is a tie, pick one class at random
  if (length(max_classes) > 1) {
    return(sample(max_classes, 1))
  }
  
  # Otherwise, return the majority class
  return(max_classes)
}

# load plot functions
# source(file = 'utils/plot_functions.R')

# STANCE MODULE ? 
STANCE_MODULE = TRUE

# get survey objects directory 
survey.files <- get_files_from_dir(dir = 'generated_data/survey_object')
# ignore clean file 
if(any(grepl('survey_object.clean.RData',survey.files))){
  survey.files <- survey.files[-which(survey.files=='generated_data/survey_object/survey_object.clean.RData')] 
}
# get survey objects directory 
survey.files <- get_files_from_dir(dir = 'generated_data/survey_object')
# ignore clean file 
if(any(grepl('survey_object.clean.RData',survey.files))){
  survey.files <- survey.files[-which(survey.files=='generated_data/survey_object/survey_object.clean.RData')] 
}
if(any(grepl('.csv',survey.files))){
  survey.files <- survey.files[-grep('.csv',survey.files)] 
}

ai.survey.list_raw <- data.table()

for(i in survey.files){
  # load users from subject pool
  load(file = i)
  if(any(duplicated(names(ai.survey)))){stop('stop - duplicate names in survey object')}
  # store which subject pool the user was from
  ai.survey$clean...pool <- trimws(gsub('twitter substantive talk','',gsub('\\_',' ',sub("generated_data/survey_object/(.*?)\\d{4}-\\d{2}-\\d{2}.*", "\\1", i))))
  ai.survey$clean...pool.date <- regmatches(i, regexpr("\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}", i))
  if(unique(as.Date(substr(ai.survey$clean...pool.date,1,10),"%Y-%m-%d"))<=as.Date("18/09/2024","%d/%m/%Y")){next}
  # bind in user list
  ai.survey.list_raw <- rbindlist(list(ai.survey.list_raw,ai.survey),fill = TRUE)
}


# check quota counter progress
load(file = 'generated_data/quota_counter/2024-10-15 05:48:24.393116.RData')
frame <- counter
load(file = 'generated_data/quota_counter/2024-09-20 06:34:31.953443.RData')
frame <- rbindlist(list(frame,counter))
frame <- 
  frame[,lapply(.SD,function(x){sum(x)}),
        by = c('SEX','AGE','ETHNICITY','HOUSEHOLD INCOME BRACKET','PAST VOTE - VOTE CHOICE IN THE 2020 PRESIDENTIAL ELECTION','quota_lab'),
        .SDcols = c('survey_cap','counter')
        ]

# check how many we are missing
message('We still need to collect ',sum(counter$survey_cap)-sum(counter$counter),' respondents')

# generate xtable to check 
library(xtable)
counter.simple <- counter[,!'quota_lab']
counter.simple$simple.SEX <- gsub('feminine sex','female',gsub('masculine sex','male',extract_before_hyphen(counter.simple$SEX)))
counter.simple$simple.AGE <- gsub(' to ','-',gsub(' or older','+',gsub(' years old','',counter.simple$AGE)))
counter.simple$RACE.ETHNICITY <- extract_before_hyphen(counter.simple$ETHNICITY)
counter.simple$RACE.ETHNICITY[grepl('native',counter.simple$RACE.ETHNICITY )] <- 'native'
counter.simple$RACE.ETHNICITY <- gsub(' or latino','',counter.simple$RACE.ETHNICITY)
counter.simple$simple.RACE.ETHNICITY <- gsub(' or african american','',counter.simple$RACE.ETHNICITY)
counter.simple <- counter.simple[,!'ETHNICITY']
#counter.simple$COLLEGE.DEGREE <- ifelse(grepl('university',counter.simple$`HIGHEST EDUCATIONAL QUALIFICATION`),'Yes','No')
#counter.simple <- counter.simple[,!'HIGHEST EDUCATIONAL QUALIFICATION']
counter.simple$`simple.HOUSEHOLD INCOME`<- as.character(unlist(counter.simple$`HOUSEHOLD INCOME BRACKET`))
counter.simple$`simple.HOUSEHOLD INCOME`<-gsub(' and ','-',gsub('between ','',gsub(' USD per year','',counter.simple$`simple.HOUSEHOLD INCOME`)))
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('more than 100000','i>100k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('up to 25000','i<25k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('50000','50k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('25000','25k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('75000','75k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('100000','100k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('-','<i<',counter.simple$`simple.HOUSEHOLD INCOME`)

counter.simple$VOTE.2020 <- as.character(unlist(counter.simple$`PAST VOTE - VOTE CHOICE IN THE 2020 PRESIDENTIAL ELECTION`))
counter.simple$VOTE.2020[grepl('Republican',counter.simple$VOTE.2020)] <- 'R'
counter.simple$VOTE.2020[grepl('Democratic',counter.simple$VOTE.2020)] <- 'D'
counter.simple$VOTE.2020[grepl('did not vote',counter.simple$VOTE.2020)] <- 'stayed home'
counter.simple$VOTE.2020[grepl('Libertarian',counter.simple$VOTE.2020)] <- 'L'
counter.simple$VOTE.2020[grepl('Green',counter.simple$VOTE.2020)] <- 'G'
counter.simple$simple.VOTE.2020 <- counter.simple$VOTE.2020

counter.simple <- counter.simple[,!'PAST VOTE - VOTE CHOICE IN THE 2020 PRESIDENTIAL ELECTION']
names(counter.simple)[grepl('survey_cap',names(counter.simple))] <- 'quota'

counter.simple <- counter.simple[,grepl('simple|counter|quota',names(counter.simple)),with=F]

# print strat frame for quota 
if(any(grepl('.csv',survey.files))){
  survey.files <- survey.files[-grep('.csv',survey.files)] 
}

ai.survey.list_raw <- data.table()

for(i in survey.files){
  # load users from subject pool
  load(file = i)
  if(any(duplicated(names(ai.survey)))){stop('stop - duplicate names in survey object')}
  # store which subject pool the user was from
  ai.survey$clean...pool <- trimws(gsub('twitter substantive talk','',gsub('\\_',' ',sub("generated_data/survey_object/(.*?)\\d{4}-\\d{2}-\\d{2}.*", "\\1", i))))
  ai.survey$clean...pool.date <- regmatches(i, regexpr("\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}", i))
  if(unique(as.Date(substr(ai.survey$clean...pool.date,1,10),"%Y-%m-%d"))<=as.Date("18/09/2024","%d/%m/%Y")){next}
  # bind in user list
  ai.survey.list_raw <- rbindlist(list(ai.survey.list_raw,ai.survey),fill = TRUE)
}

# check quota counter progress
load(file = 'generated_data/quota_counter/2024-09-20 06:34:31.953443.RData')
message('We still need to collect ',sum(counter$survey_cap)-sum(counter$counter),' respondents')

library(xtable)
counter.simple <- counter[,!'quota_lab']
counter.simple$simple.SEX <- gsub('feminine sex','female',gsub('masculine sex','male',extract_before_hyphen(counter.simple$SEX)))
counter.simple$simple.AGE <- gsub(' to ','-',gsub(' or older','+',gsub(' years old','',counter.simple$AGE)))
counter.simple$RACE.ETHNICITY <- extract_before_hyphen(counter.simple$ETHNICITY)
counter.simple$RACE.ETHNICITY[grepl('native',counter.simple$RACE.ETHNICITY )] <- 'native'
counter.simple$RACE.ETHNICITY <- gsub(' or latino','',counter.simple$RACE.ETHNICITY)
counter.simple$simple.RACE.ETHNICITY <- gsub(' or african american','',counter.simple$RACE.ETHNICITY)
counter.simple <- counter.simple[,!'ETHNICITY']
#counter.simple$COLLEGE.DEGREE <- ifelse(grepl('university',counter.simple$`HIGHEST EDUCATIONAL QUALIFICATION`),'Yes','No')
#counter.simple <- counter.simple[,!'HIGHEST EDUCATIONAL QUALIFICATION']
counter.simple$`simple.HOUSEHOLD INCOME`<- as.character(unlist(counter.simple$`HOUSEHOLD INCOME BRACKET`))
counter.simple$`simple.HOUSEHOLD INCOME`<-gsub(' and ','-',gsub('between ','',gsub(' USD per year','',counter.simple$`simple.HOUSEHOLD INCOME`)))
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('more than 100000','i>100k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('up to 25000','i<25k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('50000','50k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('25000','25k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('75000','75k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('100000','100k',counter.simple$`simple.HOUSEHOLD INCOME`)
counter.simple$`simple.HOUSEHOLD INCOME` <- gsub('-','<i<',counter.simple$`simple.HOUSEHOLD INCOME`)

counter.simple$VOTE.2020 <- as.character(unlist(counter.simple$`PAST VOTE - VOTE CHOICE IN THE 2020 PRESIDENTIAL ELECTION`))
counter.simple$VOTE.2020[grepl('Republican',counter.simple$VOTE.2020)] <- 'R'
counter.simple$VOTE.2020[grepl('Democratic',counter.simple$VOTE.2020)] <- 'D'
counter.simple$VOTE.2020[grepl('did not vote',counter.simple$VOTE.2020)] <- 'stayed home'
counter.simple$VOTE.2020[grepl('Libertarian',counter.simple$VOTE.2020)] <- 'L'
counter.simple$VOTE.2020[grepl('Green',counter.simple$VOTE.2020)] <- 'G'
counter.simple$simple.VOTE.2020 <- counter.simple$VOTE.2020

counter.simple <- counter.simple[,!'PAST VOTE - VOTE CHOICE IN THE 2020 PRESIDENTIAL ELECTION']
names(counter.simple)[grepl('survey_cap',names(counter.simple))] <- 'quota'

counter.simple <- counter.simple[,grepl('simple|counter|quota',names(counter.simple)),with=F]

# print strat frame for quota 
print(
  xtable(
    data.table(
      cell = 1:dim(counter.simple)[1],
      counter.simple[,!c('quota','counter')],
      counter.simple[,c('quota','counter')]
      )[c(1:5,(dim(counter.simple)[1]-5):dim(counter.simple)[1])]
    ),
  include.rownames=FALSE
  )

# check marginal distribution of sampled profiles
vars <- names(counter.simple[,!c('quota','counter')])
pdf(file = 'generated_plots/sample/unfilled_comparison.pdf',width = 10,height = 6.5)
par(mfrow = c(2,3))
for(i in vars){
  y = prop.table(questionr::wtd.table(x = counter.simple[[i]],weights = counter.simple$quota ))
  y.sample = prop.table(questionr::wtd.table(x = counter.simple[[i]],weights = counter.simple$counter))
  y.nosample = prop.table(questionr::wtd.table(x = counter.simple[[i]],weights = counter.simple$quota - counter.simple$counter))
  
  lim.max <- max(c(y.sample,y.nosample))
  lim.min <- min(c(y.sample,y.nosample))
  
  plot(
    y = as.numeric(y), 
    x = as.numeric(y.sample),
    pch = NA,
    ylab = '',
    xlab = '',
    xaxt = 'n',
    yaxt = 'n',
    bty = 'n',
    ylim = c(0.9*lim.min,1.1*lim.max),
    xlim = c(0.9*lim.min,1.1*lim.max)
  )
  abline(
    h = seq(0,1,by = 0.05),
    v = seq(0,1,by = 0.05),
    col = adjustcolor('darkgrey',0.15)
  )
  par(new = TRUE)
  plot(
    y = as.numeric(y), 
    x = as.numeric(y.sample),
    pch = NA,
    ylim = c(0.9*lim.min,1.1*lim.max),
    xlim = c(0.9*lim.min,1.1*lim.max),
    ylab = 'target',
    xlab = 'counter',
    main = gsub('RACE ETHNICITY','RACE \\/ ETHNICITY',gsub('\\.',' ',gsub('simple\\.','',i)))
  )
  points(y = as.numeric(y),x = as.numeric(y.sample),pch = 17,col = adjustcolor('black',0.5))
  text(y = as.numeric(y),x = as.numeric(y.sample),labels = names(y), adj = 1, pos = 3,cex = 0.75,font = 2,srt = 45)
  points(y = as.numeric(y),x = as.numeric(y.nosample),pch = 16,col = adjustcolor('black',0.5))
  text(y = as.numeric(y),x = as.numeric(y.nosample),labels = names(y), adj = 1, pos = 3,cex = 0.75,font = 2,srt = 45)
  
  abline(0,1)
  legend('topleft',legend = c('sample','unfilled'),pch = c(17,16),cex = 0.9)
}
dev.off()

# check distribution of exclusion reasons 
print(sort(table(ai.survey.list_raw$EXCLUDED)))

# wordcloud for trends 
for(day in substr(unique(ai.survey.list_raw$clean...pool.date),1,10)){
# Create a Corpus
corpus <- Corpus(VectorSource(gsub('trends ','',gsub('"and" ','',ai.survey.list_raw[substr(clean...pool.date,1,10)==day & clean...pool!='candidates']$clean...pool))))
# Text preprocessing: Convert to lower case, remove punctuation, numbers, stopwords, and white spaces
corpus <- tm_map(corpus, content_transformer(tolower))
corpus <- tm_map(corpus, removePunctuation)
corpus <- tm_map(corpus, removeNumbers)
corpus <- tm_map(corpus, removeWords, stopwords("english"))
corpus <- tm_map(corpus, stripWhitespace)
dtm <- TermDocumentMatrix(corpus)
matrix <- as.matrix(dtm)
word_freqs <- sort(rowSums(matrix), decreasing = TRUE)
data <- data.frame(word = names(word_freqs), freq = word_freqs)

# Generate the word cloud
pdf(file = paste0('generated_plots/sample/trends_wordcloud_',day,'_candidates.pdf'),width = 7.5,height = 7.5)
wordcloud(words = data$word, freq = data$freq, 
          min.freq = 1,          # Minimum frequency of words to be included in the word cloud
          max.words = 1000,       # Maximum number of words to display
          random.order = FALSE,  # Words with higher frequency appear larger and in the center
          colors = brewer.pal(8, "Dark2")) # Use a color palette from RColorBrewer
dev.off()
}

# focus on non-excluded users
ai.survey.list <- ai.survey.list_raw[which(EXCLUDED == 'no')]

# wordcloud for trends 
for(day in substr(unique(ai.survey.list_raw$clean...pool.date),1,10)){
  # Create a Corpus
  corpus <- Corpus(VectorSource(gsub('trends ','',gsub('"and" ','',ai.survey.list[substr(clean...pool.date,1,10)==day & clean...pool!='candidates']$clean...pool))))
  # Text preprocessing: Convert to lower case, remove punctuation, numbers, stopwords, and white spaces
  corpus <- tm_map(corpus, content_transformer(tolower))
  corpus <- tm_map(corpus, removePunctuation)
  corpus <- tm_map(corpus, removeNumbers)
  corpus <- tm_map(corpus, removeWords, stopwords("english"))
  corpus <- tm_map(corpus, stripWhitespace)
  dtm <- TermDocumentMatrix(corpus)
  matrix <- as.matrix(dtm)
  word_freqs <- sort(rowSums(matrix), decreasing = TRUE)
  data <- data.frame(word = names(word_freqs), freq = word_freqs)
  
  # Generate the word cloud
  pdf(file = paste0('generated_plots/sample/trends_wordcloud_',day,'_accepted.pdf'),width = 7.5,height = 7.5)
  wordcloud(words = data$word, freq = data$freq, 
            min.freq = 1,          # Minimum frequency of words to be included in the word cloud
            max.words = 1000,       # Maximum number of words to display
            random.order = FALSE,  # Words with higher frequency appear larger and in the center
            colors = brewer.pal(8, "Dark2")) # Use a color palette from RColorBrewer
  dev.off()
}

# check extracted user timeline flag 
print(sort(table(ai.survey.list_raw$EXTRACTED_USER_TIMELINE)))

# check test proportions amongst survining records
ai.survey.list$clean...test <- ifelse(is.na(ai.survey.list$TEST),'no_test_was_conducted',ai.survey.list$TEST)
print(sort(table(ai.survey.list$TEST)))

# # # Inspect some of the extracted features, and consequent justification
cat(sample(ai.survey.list$gpt_DEMO,size = 1))

# # # BEGIN CLEANING

# user id
ai.survey.list$clean...gpt_id <- ai.survey.list$gpt_id

# a couple of users will be ran through mor ethan once - 
# this happens if they appear multiple times in the subject pool
# as a result of having writted multiple query-relevant tweets. 
# I leave these in to check within-user variance in labels.
sort(table(ai.survey.list$gpt_id))

# now for a specific poll, I will only use one trace per user, 
# so I sample at random for these
# ai.survey.list <- ai.survey.list[, .SD[sample(.N, 1)], by = gpt_id]

# date
ai.survey.list$clean...date <- as.Date(substr(ai.survey.list$date,1,10),'%Y-%m-%d')
ai.survey.list$clean...week.id <- ai.survey.list$week
ai.survey.list$clean...week.n.tweets <- ai.survey.list$n.tweets
#ai.survey.list <- ai.survey.list[clean...date>='2024-08-14']

# # geo2
ai.survey.list$clean...state_simple <- ai.survey.list$gpt_GEO2

# print areas for check
sort(table(ai.survey.list$clean...state_simple))

# some post-collection cleaning
ai.survey.list <- ai.survey.list[!grepl('Please provide the long-form response so I can extract the chosen attribute for you\\.',clean...state_simple)]
ai.survey.list <- ai.survey.list[!grepl('Private',clean...state_simple)]
ai.survey.list <- ai.survey.list[!grepl('GAG CITY',clean...state_simple)]
ai.survey.list <- ai.survey.list[!grepl('United Kingdom|Newsingland South',clean...state_simple)]
ai.survey.list <- ai.survey.list[!grepl('Uttar Pradesh',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Massachusetts, Florida',clean...state_simple),sample(c('Massachusetts','Florida'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Midwest',clean...state_simple),sample(c('Illinois','Indiana','Iowa','Kansas','Michigan','Minnesota','Missouri','Nebraska','North Dakota','Ohio','South Dakota','Wisconsin'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Washington State',clean...state_simple),'Washington',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('New York and New Jersey',clean...state_simple),sample(c('New York','New Jersey'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Massachusetts 7th',clean...state_simple),'Massachusetts',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('New England',clean...state_simple),sample(c('Connecticut','Maine','Massachusetts','New Hampshire','Rhode Island','Vermont'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Dunwoody, Georgia',clean...state_simple),'Georgia',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('District of Columbia.',clean...state_simple),'District of Columbia',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Idaho\\.',clean...state_simple),'Idaho',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Mississippi\\.',clean...state_simple),'Mississippi',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('New York\\.',clean...state_simple),'New York',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Rocky Mountains',clean...state_simple),sample(c('Colorado','Idaho','Montana','New Mexico','Utah','Wyoming'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Warren\\, MI',clean...state_simple),'Michigan',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Nevada, Illinois',clean...state_simple),sample(c('Nevada','Illinois'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('East Coast USA',clean...state_simple),sample(c('Connecticut','Delaware','Florida','Georgia','Maine','Maryland','Massachusetts','New Hampshire','New Jersey','New York','North Carolina','Rhode Island','South Carolina','Virginia','District of Columbia','Pennsylvania','Vermont','West Virginia'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('New England USA',clean...state_simple),sample(c('Connecticut','Maine','Massachusetts','New Hampshire','Rhode Island','Vermont'),size = 1),clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('USA\\.',clean...state_simple),'USA',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Maryland\\.',clean...state_simple),'Maryland',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('Louisiana\\.',clean...state_simple),'Louisiana',clean...state_simple)]
ai.survey.list[,clean...state_simple := ifelse(grepl('California, New York, Massachusetts',clean...state_simple),sample(c('California','New York','Massachusetts'),size = 1),clean...state_simple)]

# print check 
sort(table(ai.survey.list$clean...state_simple))

# geo3 
ai.survey.list$clean...geo3 <- ai.survey.list$gpt_GEO3_clean
ai.survey.list[,clean...geo3 := ifelse(grepl("Nebraska\\'s 2nd Congressional District",clean...geo3),'Nebraska 2nd',clean...geo3)]
ai.survey.list[,clean...geo3 := ifelse(grepl("Maine's 2nd Congressional District",clean...geo3),'Maine 2nd',clean...geo3)]

# electoral college constituency
ai.survey.list[,clean...state_electoral.college:=ifelse(clean...state_simple %in% c('Nebraska','Maine'),clean...geo3,clean...state_simple)] 

# print check 
sort(table(ai.survey.list$clean...state_electoral.college ))

valid.ec.areas <- c(usmap::fips_info()$full,'Nebraska 1st','Nebraska 2nd','Nebraska 3rd','Maine 1st','Maine 2nd','USA')
ai.survey.list <- ai.survey.list[clean...state_electoral.college %in% valid.ec.areas]
ai.survey.list$clean...state_electoral.college <- as.factor(ai.survey.list$clean...state_electoral.college)
ai.survey.list$clean...state_simple <- as.factor(ai.survey.list$clean...state_simple)

# augment with region - load area-level predictor (useful to augment raking vars)
load(file = 'generated_data/predictor/area_level.RData')

reg <- predictor_area_level[,grepl('region',names(predictor_area_level)),with=F]
predictor_area_level$clean...region <- 
  apply(reg,1,function(x){gsub('pct.region..','',names(reg))[which(x==1)]})
ai.survey.list <- 
  merge(
    ai.survey.list,
    unique(predictor_area_level[,c('state_simple','clean...region')]),
    by.x = c('clean...state_simple'),
    by.y = c('state_simple'),
    all.x = TRUE
    )

# save meta data 
fwrite(ai.survey.list,file = paste0('generated_data/survey_object/metadata.csv'))
table(ai.survey.list$clean...pool)