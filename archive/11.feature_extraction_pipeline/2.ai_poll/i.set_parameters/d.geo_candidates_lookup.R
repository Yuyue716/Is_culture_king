library(data.table)
library(usmap)

### Function Definitions -------------------------------------------------------

#' Add ordinal suffix to numeric values (e.g., 1 -> 1st, 2 -> 2nd, etc.)
#'
#' @param numbers A vector of positive integers.
#' @return A character vector with ordinal suffixes appended.
ordinal_suffix_vectorized <- function(numbers) {
  last_digit <- numbers %% 10
  second_last_digit <- (numbers %% 100) %/% 10
  suffixes <- rep("th", length(numbers))
  
  suffixes[second_last_digit != 1 & last_digit == 1] <- "st"
  suffixes[second_last_digit != 1 & last_digit == 2] <- "nd"
  suffixes[second_last_digit != 1 & last_digit == 3] <- "rd"
  
  paste0(numbers, suffixes)
}

#' Extract state and district from Daily Kos district nomenclature.
#'
#' @param districts A character vector of district names.
#' @return A data.table with columns 'state' and 'district'.
extract_district_info <- function(districts) {
  state_names <- sub("'s?\\s+.*$", "", districts)
  district_numbers <- ifelse(grepl("At-Large", districts), 0, as.integer(gsub("[^0-9]", "", districts)))
  
  data.table(state = state_names, district = district_numbers)
}


### Data Preparation for geo3 --------------------------------------------------

# Load House district-level returns for 1976-2022
geo3_lookup <- fread('auxiliary_data/MIT Election Data and Science Lab/U.S House District-Level Returns 1976-2022/1976-2022-house.csv')

# Focus on 2020 and 2022
geo3_lookup <- geo3_lookup[year %in% c(2020, 2022)]

# Exclude write-ins
geo3_lookup <- geo3_lookup[writein != TRUE]

# Fix Maine 2nd district results for 2022
geo3_lookup[grepl('MAINE', state) & district == 2 & year == 2022, totalvotes := 316382]
geo3_lookup[grepl('MAINE', state) & district == 2 & candidate == 'BRUCE POLIQUIN' & year == 2022, candidatevotes := 141260]
geo3_lookup[grepl('MAINE', state) & district == 2 & candidate == 'JARED F GOLDEN' & year == 2022, candidatevotes := 153074]
geo3_lookup[grepl('MAINE', state) & district == 2 & candidate == 'TIFFANY BOND' & year == 2022, candidatevotes := 21655]
geo3_lookup[grepl('MAINE', state) & district == 2 & candidate == 'WRITEIN' & year == 2022, candidatevotes := 393]
geo3_lookup <- geo3_lookup[!(candidate == 'EXHAUSTED BALLOT' & state == 'MAINE' & year == 2022)]

# Add District of Columbia data
dc_2020 <- data.table(
  state = 'District of Columbia', state_po = 'DC', state_fips = 11, district = 0, year = 2020,
  candidate = c('Eleanor Holmes Norton','Nelson Rimensnyder','Barbara Washington Franklin','Omari Musa','Natale Lino Stracuzzi',
                'David Krucoff','Amir Lowery','John Cheeks'),
  party = c('DEMOCRAT','LIBERTARIAN','INDEPENDENT','SOCIALIST WORKERS','DC STATEHOOD - GREEN PARTY',
            'INDEPENDENT','INDEPENDENT','INDEPENDENT'),
  candidatevotes = c(281831,9678,7628,6702,5553,5017,5001,2914)
)

dc_2022 <- data.table(
  state = 'District of Columbia', state_po = 'DC', state_fips = 11, district = 0, year = 2022,
  candidate = c('Eleanor Holmes Norton','Nelson Rimensnyder','Natale Stracuzzi','Bruce Major'),
  party = c('DEMOCRAT','REPUBLICAN','DC STATEHOOD - GREEN PARTY','LIBERTARIAN'),
  candidatevotes = c(174238,11701,9867,4003)
)

geo3_lookup <- rbindlist(list(geo3_lookup, dc_2020, dc_2022), fill = TRUE)

# Normalize state and party names
geo3_lookup[, state := tolower(state)]
geo3_lookup[, party := fifelse(grepl('GREEN', party), 'GREEN', party)]

# Compute national-level aggregation
geo3_lookup_nat <- copy(geo3_lookup)
geo3_lookup_nat[, party := fifelse(party %in% c('DEMOCRAT','REPUBLICAN','LIBERTARIAN','GREEN'), party, 'OTHER MINOR PARTIES')]
geo3_lookup_nat <- geo3_lookup_nat[, .(candidatevotes = sum(candidatevotes)), by = .(party, year)]
geo3_lookup_nat[, `:=`(state = 'usa', district = 0, state_po = 'USA', state_fips = NA)]

geo3_lookup <- rbindlist(list(geo3_lookup, geo3_lookup_nat), fill = TRUE)
geo3_lookup[, state := tolower(state)]
geo3_lookup[, district := fifelse(state == 'usa', 0, district)]

### Add Voting Age Population (VAP) for geo3 -----------------------------------

# 2022 VAP
geo3_vap_2022 <- fread('auxiliary_data/Daily Kos/House and Senate 5-Year American Community Survey Racial Demographics by Citizenship Status - 118th House—2022.csv')
geo3_vap_2022 <- geo3_vap_2022[, grepl('District|Citizen Voting Age Population', geo3_vap_2022[1,]) & (grepl('District', geo3_vap_2022[1,]) | grepl('Total', geo3_vap_2022[2,])), with=FALSE]
setnames(geo3_vap_2022, c('district','voting.age.pop'))
geo3_vap_2022 <- geo3_vap_2022[-c(1:2)]
geo3_vap_2022 <- cbind(
  extract_district_info(geo3_vap_2022$district),
  voting.age.pop = as.numeric(gsub(',', '', geo3_vap_2022$voting.age.pop))
)
geo3_vap_2022 <- rbind(
  geo3_vap_2022,
  data.table(state = 'District of Columbia', district = 0, voting.age.pop = 547328)
)
geo3_vap_2022[, year := 2022]
geo3_vap_2022[, state_po := fips_info()[,'abbr'][match(state, fips_info()[,'full'])]]
geo3_vap_2022[, state_fips := as.numeric(fips_info()[,'fips'])[match(state, fips_info()[,'full'])]]
geo3_vap_2022[, state := tolower(state)]
geo3_vap_2022[state == 'nationwide', state := 'usa']
geo3_vap_2022[state == 'usa', `:=`(district = 0, state_po = 'USA', state_fips = NA)]

# 2020 VAP
geo3_vap_2020 <- fread('auxiliary_data/Daily Kos/House and Senate 5-Year American Community Survey Racial Demographics by Citizenship Status - 118th House—2020.csv')
geo3_vap_2020 <- geo3_vap_2020[, grepl('District|Citizen Voting Age Population', geo3_vap_2020[1,]) & (grepl('District', geo3_vap_2020[1,]) | grepl('Total', geo3_vap_2020[2,])), with=FALSE]
setnames(geo3_vap_2020, c('district','voting.age.pop'))
geo3_vap_2020 <- geo3_vap_2020[-c(1:2)]
geo3_vap_2020 <- cbind(
  extract_district_info(geo3_vap_2020$district),
  voting.age.pop = as.numeric(gsub(',', '', geo3_vap_2020$voting.age.pop))
)
geo3_vap_2020 <- rbind(
  geo3_vap_2020,
  data.table(state = 'District of Columbia', district = 0, voting.age.pop = 575161)
)
geo3_vap_2020[, state_po := fips_info()[,'abbr'][match(state, fips_info()[,'full'])]]
geo3_vap_2020[, state_fips := as.numeric(fips_info()[,'fips'])[match(state, fips_info()[,'full'])]]
geo3_vap_2020[, year := 2020]
geo3_vap_2020[, state := tolower(state)]
geo3_vap_2020[state == 'nationwide', state := 'usa']
geo3_vap_2020[state == 'usa', `:=`(district = 0, state_po = 'USA', state_fips = NA)]

# Combine 2020 & 2022 VAP
geo3_vap <- rbindlist(list(geo3_vap_2020, geo3_vap_2022), use.names = TRUE)

### Calculate Abstentions for geo3 ---------------------------------------------

geo3_lookup_abst <- geo3_lookup[, .(candidatevotes = sum(candidatevotes)), by = .(state, district, year)]
geo3_lookup_abst <- merge(geo3_lookup_abst, geo3_vap, by = c('state','district','year'), all = TRUE)
geo3_lookup_abst <- geo3_lookup_abst[complete.cases(geo3_lookup_abst)]
geo3_lookup_abst[, party := 'ABSTAINED / DID NOT VOTE / STAYED HOME']
geo3_lookup_abst[, candidatevotes := voting.age.pop - candidatevotes]

geo3_lookup <- rbindlist(list(geo3_lookup, geo3_lookup_abst[, !'voting.age.pop']), fill = TRUE)
geo3_lookup[is.na(candidate), candidate := '']

# Convert votes to percentages by state/district/year group
geo3_lookup[, candidatevotes := round(100 * candidatevotes / sum(candidatevotes), 2), 
            by = .(state, state_po, state_fips, district, year)]
geo3_lookup[, candidatevotes := paste0(candidatevotes, ' %')]


### Data Preparation for geo2 (State-Level Presidential) -----------------------

vote2020_state <- fread('auxiliary_data/MIT Election Data and Science Lab/U.S President State-Level Returns 1976-2020/1976-2020-president.csv')
vote2020_state <- vote2020_state[year == 2020]
setnames(vote2020_state, 'party_detailed', 'party')

# Normalize state name: Title case
vote2020_state[, state := tolower(state)]
vote2020_state[, state := gsub("\\b([a-z])", "\\U\\1", state, perl = TRUE)]
vote2020_state[state == 'District Of Columbia', state := 'District of Columbia']

geo2_lookup <- vote2020_state[
  , .(candidatevotes = sum(candidatevotes)), 
  by = .(candidate, party, state, state_po, state_fips, year)
]

# Compute national-level for geo2
geo2_lookup_nat <- copy(geo2_lookup)
geo2_lookup_nat[, candidate := fifelse(candidate %in% c('BIDEN, JOSEPH R. JR','TRUMP, DONALD J.','JORGENSEN, JO','HAWKINS, HOWIE'),
                                       candidate, 'OTHER MINOR CANDIDATES')]

geo2_lookup_nat[, party := fifelse(candidate == 'OTHER MINOR CANDIDATES', 'OTHER MINOR PARTIES', party)]
geo2_lookup_nat[, party := fifelse(candidate == 'HAWKINS, HOWIE', 'GREEN', party)]
geo2_lookup_nat[, party := fifelse(candidate == 'JORGENSEN, JO', 'LIBERTARIAN', party)]
geo2_lookup_nat[, party := fifelse(party %in% c('DC STATEHOOD GREEN','GREEN-RAINBOW','PACIFIC GREEN'), 'GREEN', party)]

geo2_lookup_nat <- geo2_lookup_nat[
  , .(candidatevotes = sum(candidatevotes)), by = .(candidate, party, year)
]
geo2_lookup_nat[, `:=`(state = 'usa', state_po = 'USA', state_fips = NA)]

geo2_lookup <- rbindlist(list(geo2_lookup, geo2_lookup_nat), fill = TRUE)
geo2_lookup[, state := tolower(state)]

# Add VAP for states (geo2)
geo2_vap <- geo3_vap[
  , .(voting.age.pop = sum(voting.age.pop)), by = .(state, state_po, state_fips, year)
]
geo2_vap <- geo2_vap[year == 2020]

geo2_lookup_abst <- geo2_lookup[
  , .(candidatevotes = sum(candidatevotes)), by = .(state, year)
]

geo2_lookup_abst <- merge(geo2_lookup_abst, geo2_vap, by = c('state','year'), all = TRUE)
geo2_lookup_abst <- geo2_lookup_abst[complete.cases(geo2_lookup_abst)]
geo2_lookup_abst[, party := 'VOTING AGE PEOPLE WHO ABSTAINED / DID NOT VOTE / STAYED HOME']
geo2_lookup_abst[, candidatevotes := voting.age.pop - candidatevotes]

geo2_lookup <- rbindlist(list(geo2_lookup, geo2_lookup_abst[, !'voting.age.pop']), fill = TRUE)
geo2_lookup[is.na(candidate), candidate := '']

# Convert votes to percentages by state/year group
geo2_lookup[, candidatevotes := round(100 * candidatevotes / sum(candidatevotes), 2), 
            by = .(state, state_po, state_fips, year)]
geo2_lookup[, candidatevotes := paste0(candidatevotes, ' %')]

