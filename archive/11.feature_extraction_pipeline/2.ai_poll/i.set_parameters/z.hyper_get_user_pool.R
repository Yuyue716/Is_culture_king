# use trends button
USE_TRENDS <- TRUE

# define url from where to parse the latest trends from 
trends_url <- "https://trends24.in/united-states/"

# max results per trend
max_results_per_trend_query <- 10

# define terms for search query on X api
query <-
  list(
    economy = "(jobs OR economy OR economic OR inflation OR price OR child tax OR healthcare tax)",
    immigration = "(migrants OR immigrants OR foreign OR illegal aliens OR open borders OR border wall OR deport OR citizenship OR immigrant crime OR immigrant deportation OR immigrant jobs)",
    protectionism = "(outsourcing OR factories OR manufacturing OR unions OR unions membership)",
    crime = "(legal OR courts OR crime OR criminal OR sentence OR defund)",
    trad = "(divorce OR abortion OR reproductive freedom OR pro choice OR pro life OR gay marriage OR project 2025)",
    woke = "(homosexual OR trans OR LGBT OR queer OR woke OR gender affirming OR gender roles OR gender discrimination)",
    health = "(medicare OR healthcare OR obamacare OR affordable care OR vaccine OR vaccination OR vax)",
    drugs = "(fentanyl OR marijuana OR legalize OR drugs)",
    guns = "(guns OR semi-automatic OR rifle OR gun permit OR gun control)",
    race = "(white people OR black people OR hispanics OR asians OR discrimination OR affirmative action OR slavery OR white privilege OR black discrimination OR racial hiring preference)",
    frees_speech = "(book bans OR free speech OR harmful OR book censorship OR harmful ideas)",
    foreign_policy = "(hamas OR hezbollah OR israel OR ukraine OR russia OR ceasefire OR military aid)",
    radical = "(communist OR marxist OR terrorist OR radical OR political violence OR antifa)",
    democracy = "(democracy OR january 6th OR jan 6th OR storming OR insurrection OR capitol riot OR threat democracy)",
    media = "(censorship OR media OR podcasts OR media censorship OR trust media)",
    climate = "(climate OR solar OR nuclear OR fracking OR drilling OR coal OR renewable energy OR climate change OR wind power)",
    discourse = "(discourse OR violence OR smear OR insult OR insult politics OR smear politics OR aggressive rhetoric OR demeaning language OR political discourse OR violent rhetoric)"
  )

# define the number of queries we wish to interrogate on any given sampling effort
n.query <- length(query)

# subsample the ids of the queries if they are too many -- 
# this is project specific and needs to be tuned
qs <- 1:n.query 

# define max results per substantive query
max_results_per_substantive_query <- 10


