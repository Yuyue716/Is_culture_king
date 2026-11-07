library(data.table)
library(bayestestR)

# Define key quota variables 
quota_features <- c('SEX', 'AGE', 'ETHNICITY', 'HOUSEHOLD INCOME BRACKET', 
                    'PAST VOTE - VOTE CHOICE IN THE 2020 PRESIDENTIAL ELECTION')

# Desired survey size
n <- 750

# Load stratification frame
load('generated_data/stratification_frame/SF_extended.RData')

### Clean and Rename Variables -------------------------------------------------

# Rename and relevel SEX variable
levels(SF_extended$gender)[grepl('M', levels(SF_extended$gender))] <- 'masculine sex - male'
levels(SF_extended$gender)[grepl('F', levels(SF_extended$gender))] <- 'feminine sex - female'
setnames(SF_extended, 'gender', 'SEX')

# Rename and relevel AGE variable
age_map <- list(
  '18-24' = '18 to 24 years old',
  '25-34' = '25 to 34 years old',
  '35-44' = '35 to 44 years old',
  '45-54' = '45 to 54 years old',
  '55-64' = '55 to 64 years old',
  '65+'   = '65 or older'
)
for (old_label in names(age_map)) {
  levels(SF_extended$age_bins)[grepl(old_label, levels(SF_extended$age_bins))] <- age_map[[old_label]]
}
setnames(SF_extended, 'age_bins', 'AGE')
levels(SF_extended$AGE) <- c(levels(SF_extended$AGE), 'under 18 years old')

# Rename and relevel ETHNICITY variable
ethnicity_relevels <- c(
  'Asian' = 'asian - individuals with origins in any of the original peoples of central or east asia, southeast asia, or south asia, including, for example, chinese, asian indian, filipino, vietnamese, korean, and japanese.',
  'Black' = 'black or african american - individuals with origins in any of the black racial groups of africa, including, for example, african american, jamaican, haitian, nigerian, ethiopian, and somali.',
  'Hispanic' = 'hispanic or latino - includes individuals of mexican, puerto rican, salvadoran, cuban, dominican, guatemalan, and other central or south american or spanish culture or origin.',
  'Mixed-race' = 'multiracial - individuals who identify explicitly as belonging to more than one of the racial and ethnic groups above.',
  'White' = 'white - individuals with origins in any of the original peoples of europe or the middle east or north africa.',
  'Native' = 'american indian or alaskan native or native hawaiian or pacific islander - individuals with origins in indigenous peoples of the americas, hawaii, guam, samoa, or other pacific islands.'
)
for (old_label in names(ethnicity_relevels)) {
  levels(SF_extended$ethnicity)[levels(SF_extended$ethnicity) == old_label] <- ethnicity_relevels[[old_label]]
}
SF_extended$ethnicity <- factor(as.character(SF_extended$ethnicity))
setnames(SF_extended, 'ethnicity', 'ETHNICITY')

# Rename and relevel HOUSEHOLD INCOME BRACKET variable
income_map <- c(
  '1.[min, 25000)' = 'up to 25000 USD per year',
  '2.[25000, 50000)' = 'between 25000 and 50000 USD per year',
  '3.[50000, 75000)' = 'between 50000 and 75000 USD per year',
  '4.[75000, 100000)' = 'between 75000 and 100000 USD per year',
  '5.[100000, max]' = 'more than 100000 USD per year'
)
for (old_label in names(income_map)) {
  levels(SF_extended$hh_income)[levels(SF_extended$hh_income) == old_label] <- income_map[[old_label]]
}
setnames(SF_extended, 'hh_income', 'HOUSEHOLD INCOME BRACKET')

# Rename and relevel PAST VOTE variable
SF_extended$vote2020 <- factor(SF_extended$vote2020)
vote2020_map <- c(
  'D' = 'voted for Joe Biden, the Democratic Party candidate, in the 2020 election for President in their state',
  'R' = 'voted for Donald Trump, the Republican Party candidate, in the 2020 election for President in their state',
  'OTHER' = 'voted for a candidate other than the Republican, Democrat, Libertarian, or Green Party candidates, in the 2020 election for President in their state',
  'L' = 'voted for Jo Jorgensen, the Libertarian Party candidate, in the 2020 election for President in their state',
  'G' = 'voted for Howie Hawkins, the Green Party candidate, in the 2020 election for President in their state',
  'stay home' = 'did not vote in the 2020 election for President in their state'
)
for (old_label in names(vote2020_map)) {
  levels(SF_extended$vote2020)[levels(SF_extended$vote2020) == old_label] <- vote2020_map[[old_label]]
}
setnames(SF_extended, 'vote2020', 'PAST VOTE - VOTE CHOICE IN THE 2020 PRESIDENTIAL ELECTION')

### Aggregate and Compute Survey Caps ------------------------------------------

# Aggregate counts by quota features
agg_cols <- names(SF_extended)[grepl('N_star', names(SF_extended))]
SF_extended <- SF_extended[, lapply(.SD, sum), by = quota_features, .SDcols = agg_cols]

# Compute expected counts in an n-sized survey using MAP estimate
SF_extended$survey_cap <- apply(
  SF_extended[, agg_cols, with = FALSE] / sum(SF_extended$N_star.1),
  1,
  function(x) map_estimate(x)$MAP_Estimate
)

# Introduce randomness into cell selection
SF_extended$survey_cap <- rmultinom(1, size = n, prob = SF_extended$survey_cap)

# Remove original weights and cells with zero cap
SF_extended <- SF_extended[, !grepl('N_star', names(SF_extended)), with = FALSE]
SF_extended <- SF_extended[survey_cap > 0]

# Add a quota label and initialize a counter
SF_extended$quota_lab <- apply(SF_extended[, quota_features, with = FALSE], 1, paste0, collapse = '_AND_')
SF_extended$counter <- 0

# Rename for final usage
counter <- SF_extended
