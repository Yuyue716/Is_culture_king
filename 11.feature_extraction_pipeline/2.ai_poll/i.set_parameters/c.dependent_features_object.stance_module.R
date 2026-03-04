# CAREFUL: 
# THESE SHOULD NOT COINTAIN BRACKETS IN THE HEADER OR THE IDENTIFIER
# EACH IDENTIFIER MUST BE TOTALLY DISTINCT
# NO FULL IDENTIFIER SHOULD BE A SUBSET OF ANY OTHER

dep.features.stance_module <- c(
  # IMMIGRATION - centre-point of the election, voters are likely to shift on this and further depending on who wins 
  # Questions comparable directly to GSS
  "OPINION ON THE NUMBER OF IMMIGRANTS IN AMERICA:
ImA1) The number of immigrants in the USA should be increased a lot
ImA2) The number of immigrants in the USA should be increased a little
ImA3) The number of immigrants in the USA should remain the same as it is
ImA4) The number of immigrants in the USA should be reduced a little
ImA5) The number of immigrants in the USA should be reduced a lot

",
  "OPINION ON THE STATEMENT << IMMIGRANTS INCREASE CRIME RATES >>:
ImB1) Strongly agree with the statment << Immigrants increase crime rates >>
ImB2) Somewhat agree with the statment << Immigrants increase crime rates >>
ImB3) Somewhat disagree with the statment << Immigrants increase crime rates >>
ImB4) Strongly disagree with the statment << Immigrants increase crime rates >>

",
  "OPINION ON THE STATEMENT << IMMIGRANTS TAKE JOBS AWAY FROM PEOPLE WHO WERE BORN IN THE USA >>:
ImC1) Strongly agree with the statment << Immigrants take jobs away from people who were born in the USA >>
ImC2) Somewhat agree with the statment << Immigrants take jobs away from people who were born in the USA >>
ImC3) Somewhat disagree with the statment << Immigrants take jobs away from people who were born in the USA >>
ImC4) Strongly disagree with the statment << Immigrants take jobs away from people who were born in the USA >>

",
  "OPINION ON WHAT SHOULD BE DONE WITH ILLEGAL IMMIGRANTS:
ImD1) Illegal immigrants should be allowed to become citizens, provided they meet certain requirements
ImD2) Illegal immigrantsshould be allowed to become permanent legal residents, but not citizens
ImD3) Illegal immigrants should be identified and deported

",
  # SOCIAL ISSUES - these are related to the `republicans are weird` narrative, JD Vance, Project 2025 etc. 
  # Divorce
  "OPINION ON WHETHER DIVORCE IN THE USA SHOULD BE EASIER OR MORE DIFFICULT TO OBTAIN THAN IT IS:
SoA1) Obtaining a divorce should be easier than it is
SoA2) Obtaining a divorce should be more difficult than it is
SoA3) Obtaining a divorce is the right level of difficulty as it is

",
  # Abortion
  "OPINION ON THE FOLLOWING STATEMENT << IT SHOULD BE ACCEPTABLE FOR A PREGNANT WOMAN TO OBTAIN A LEGAL ABORTION IF A WOMAN WANTS IT, FOR ANY REASON >>:
SoB1) Strongly agree with the statment << It should be acceptable for a pregnant woman to obtain a legal abortion if a woman wants it, for any reason >>
SoB2) Somewhat agree with the statment << It should be acceptable for a pregnant woman to obtain a legal abortion if a woman wants it, for any reason >>
SoB3) Somewhat disagree with the statment << It should be acceptable for a pregnant woman to obtain a legal abortion if a woman wants it, for any reason >>
SoB4) Strongly disagree with the statment << It should be acceptable for a pregnant woman to obtain a legal abortion if a woman wants it, for any reason >>

",
  # Gay Marriage
  "OPINION ON THE FOLLOWING STATEMENT << HOMOSEXUAL COUPLES SHOULD HAVE THE RIGHT TO MARRY ONE ANOTHER >>:
SoD1) Strongly agree with the statment << Homosexual couples should have the right to marry one another >>
SoD2) Somewhat agree with the statment << Homosexual couples should have the right to marry one another >>
SoD3) Somewhat disagree with the statment << Homosexual couples should have the right to marry one another >>
SoD4) Strongly disagree with the statment << Homosexual couples should have the right to marry one another >>

",
  # FEMINISM / WOMEN'S RIGHT / SOCIETAL PREFERENCES AROUND FAMILY FORMATION -- related to the Project 2025 narrative, + female Presidential candidate
  "OPINION ON THE STATEMENT << MEN ARE BETTER SUITED FOR POLITICS THAN ARE MOST WOMEN >>:
FeA1) Strongly agree with the statment << Men are better suited emotionally for politics than are most Women >>
FeA2) Somewhat agree with the statment << Men are better suited emotionally for politics than are most Women >>
FeA3) Somewhat disagree with the statment << Men are better suited emotionally for politics than are most Women >>
FeA4) Strongly disagree with the statment << Men are better suited emotionally for politics than are most Women >>

",
  "OPINION ON THE STATEMENT << IT IS MUCH BETTER FOR EVERYONE INVOLVED IF THE MAN IS THE ACHIEVER OUTSIDE THE HOME AND THE WOMAN TAKES CARE OF THE HOME AND FAMILY >>:
FeB1) Strongly agree with the statment << It is much better for everyone involved if the man is the achiever outside the home and the woman takes care of the home and family >>
FeB2) Somewhat agree with the statment << It is much better for everyone involved if the man is the achiever outside the home and the woman takes care of the home and family >>
FeB3) Somewhat disagree with the statment << It is much better for everyone involved if the man is the achiever outside the home and the woman takes care of the home and family >>
FeB4) Strongly disagree with the statment << It is much better for everyone involved if the man is the achiever outside the home and the woman takes care of the home and family >>

", 
  "OPINION ON EXPANDING THE CHILD TAX CREDIT:
FeE1) The reason to expand the child tax credit is to incentivise couples to have more children and combat low fertility rates 
FeE2) The reason to expand the child tax credit is to provide financial aid to working class and low-income parents 
FeE3) There is no valid reason to expand the child tax credit, as it should not be expanded

",
  # HEALTHCARE - This is not so relevant this election, but is generally in the back of voters' minds. RFK raised salience on alternative medicine and vaccines. 
  "WILLINGNESS TO PAY HIGHER TAXES TO IMPROVE THE LEVEL OF HEALTH CARE FOR ALL PEOPLE IN THE UNITED STATES:
HeA1) Very willing to pay higher taxes to improve the level of health care for all people in the United States
HeA2) Fairly willing to pay higher taxes to improve the level of health care for all people in the United States
HeA3) Fairly unwilling to pay higher taxes to improve the level of health care for all people in the United States
HeA4) Very unwilling to pay higher taxes to improve the level of health care for all people in the United States

",
  "OPINION ON THE FOLLOWING STATEMENT << OVERALL, VACCINATIONS DO MORE HARM THAN GOOD >>:
HeC1) Strongly agree with the statment << Overall, vaccinations do more harm than good >>
HeC2) Somewhat agree with the statment << Overall, vaccinations do more harm than good >>
HeC3) Somewhat disagree with the statment << Overall, vaccinations do more harm than good >>
HeC4) Strongly disagree with the statment << Overall, vaccinations do more harm than good >>

",
  # CRIME - important in this election, + defund the police narrative / Kamala is a cop narrative
  "OPINION ON WHETHER COURTS IN THE USERS'S AREA DEAL TOO HARSHLY OR NOT HARSHLY ENOUGH WITH CRIMINALS:
CrA1) The user thinks courts in their area deal with criminals too harshly
CrA2) The user thinks courts in their area do not deal with criminals harshly enough
CrA3) The user thinks courts in their area deal with criminals about right

",
  "OPINION ON FUNDING OF POLICE DEPARTMENTS:
CrC1) Funding of police departments in my community should be increased a lot
CrC2) Funding of police departments in my community should be increased a little
CrC3) Funding of police departments in my community should remain the same as it is
CrC4) Funding of police departments in my community should be reduced a little
CrC5) Funding of police departments in my community should be reduced a lot

",
  # DRUGS 
  "OPINION ON MARIJUANA LEGALISATION:
DrA1) Marijuana should be legal for medical and recriational use
DrA2) Marijuana should be legal for medical use only 
DrA3) Marijuana should not be legal

",  
  # GUNS
  "OPINION ON THE STATEMENT << A PERSON SHOULD REQUIRE A POLICE PERMIT BEFORE HE OR SHE COULD BUY A GUN >>
GuA1) Strongly agree with the statment << a person should require a police permit before he or she could buy a gun >>
GuA2) Somewhat agree with the statment << a person should require a police permit before he or she could buy a gun >>
GuA3) Somewhat disagree with the statment << a person should require a police permit before he or she could buy a gun >>
GuA4) Strongly disagree with the statment << a person should require a police permit before he or she could buy a gun >>

",
  # RACE - Some of this links to the affermative action debate 
  # https://www.pewresearch.org/politics/2024/06/06/racial-attitudes-and-the-2024-election/
  "OPINION ON THE STATEMENT << WHITE PEOPLE BENEFIT A GREAT DEAL FROM ADVANTAGES IN SOCIETY THAT BLACK PEOPLE DO NOT HAVE >>:
RaA1) Strongly agree with the statment << White people benefit a great deal from advantages in society that Black people do not have >>
RaA2) Somewhat agree with the statment << White people benefit a great deal from advantages in society that Black people do not have >>
RaA3) Somewhat disagree with the statment << White people benefit a great deal from advantages in society that Black people do not have >>
RaA4) Strongly disagree with the statment << White people benefit a great deal from advantages in society that Black people do not have >>

  ",
  "OPINION ON DECLINING SHARE OF WHITE PEOPLE IN AMERICA:
RaB1) A decline in the share of White people in the US is very good for society
RaB2) A decline in the share of White people in the US is somewhat good for society
RaB3) A decline in the share of White people in the US is neither good nor bad for society
RaB4) A decline in the share of White people in the US is somewhat bad for society
RaB5) A decline in the share of White people in the US is very bad for society

  ",
  "OPINION ON THE STATEMENT << BECAUSE OF PAST DISCRIMINATION, BLACK PEOPLE SHOULD BE GIVEN PREFERENCE IN HIRING AND PROMOTION >>:
RaC1) Strongly agree with the statment << Because of past discrimination, black people should be given preference in hiring and promotion >>
RaC2) Somewhat agree with the statment << Because of past discrimination, black people should be given preference in hiring and promotion >>
RaC3) Somewhat disagree with the statment << Because of past discrimination, black people should be given preference in hiring and promotion >>
RaC4) Strongly disagree with the statment << Because of past discrimination, black people should be given preference in hiring and promotion >>

",
  # FREE SPEECH - Musk, censorship, etc. 
  "OPINION ON THE STATEMENT << BOOKS EXPRESSING HARMFUL IDEAS SHOULD BE REMOVED FROM LIBRARIES IN MY COMMUNITY >>:
FrA1) Strongly agree with the statment << Books expressing harmful ideas should be removed from libraries in my community >>
FrA2) Somewhat agree with the statment << Books expressing harmful ideas should be removed from libraries in my community >>
FrA3) Somewhat disagree with the statment << Books expressing harmful ideas should be removed from libraries in my community >>
FrA4) Strongly disagree with the statment << Books expressing harmful ideas should be removed from libraries in my community >>

",
  "OPINION ON THE STATEMENT << IN MY COMMUNITY, PEOPLE SHOULD FEEL FREE TO EXPRESS SUPPORT FOR ARMED OR OTHERWISE VIOLENT POLITICAL MOVEMENTS >>:
FrB1) Strongly agree with the statment << in my community, people should feel free to express support for armed or otherwise violent political movements >>
FrB2) Somewhat agree with the statment << in my community, people should feel free to express support for armed or otherwise violent political movements >>
FrB3) Somewhat disagree with the statment << in my community, people should feel free to express support for armed or otherwise violent political movements >>
FrB4) Strongly disagree with the statment << in my community, people should feel free to express support for armed or otherwise violent political movements >>

",
  "OPINION ON THE STATEMENT << THE USE OF PUBERTY BLOCKERS AND OTHER GENDER-AFFERMING PROCEDURES FOR MINORS SHOULD BE ALLOWED >>:
FrC1) Strongly agree with the statment << the use of puberty blockers and other gender-afferming procedures for minors should be allowed >>
FrC2) Somewhat agree with the statment << the use of puberty blockers and other gender-afferming procedures for minors should be allowed >>
FrC3) Somewhat disagree with the statment << the use of puberty blockers and other gender-afferming procedures for minors should be allowed >>
FrC4) Strongly disagree with the statment << the use of puberty blockers and other gender-afferming procedures for minors should be allowed >>

",
  # DEMOCRACY IN THE USA # https://news.gallup.com/poll/548120/record-low-satisfied-democracy-working.aspx
  "SATISFACTION WITH THE WAY DEMOCRACY IS WORKING IN THE US:
DeA1) Very satisfied with the way democracy is working in the US 
DeA2) Somewhat satisfied with the way democracy is working in the US 
DeA3) Somewhat dissatisfied with the way democracy is working in the US 
DeA4) Very dissatisfied with the way democracy is working in the US 

",
  # Opinion on January 6th # https://maristpoll.marist.edu/wp-content/uploads/2022/07/NPR_PBS-NewsHour_Marist-Poll_Jan-6th_USA-NOS-and-Tables_202207191134.pdf
  "OPINION ON JANUARY 6th STORMING OF THE US CAPITOL:
DeB1) The storming of the capitol on January 6, 2021 was an insurrection and a threat to democracy
DeB2) The storming of the capitol on January 6, 2021 was a political protest protected under the first amendment
DeB3) The storming of the capitol on January 6, 2021 was an unfortunate event, but in the past, so no need to worry about it anymore

",  
  # Tech censorship # https://www.pewresearch.org/internet/2024/04/29/americans-views-of-technology-companies-2/
  "BELIEF ON LIKELIHOOD THAT SOCIAL MEDIA COMPANIES ARE INTENTIONALLY CENSORING POLITICAL VIEWS THEY OBJECT TO:
DeC1) Very likely that social media companies are intentionally censoring political views they object to 
DeC2) Somewhat likely that social media companies are intentionally censoring political views they object to 
DeC3) Somewhat unlikely that social media companies are intentionally censoring political views they object to 
DeC4) Very unlikely that social media companies are intentionally censoring political views they object to 

",  
  # https://www.pewresearch.org/short-reads/2022/10/27/u-s-adults-under-30-now-trust-information-from-social-media-almost-as-much-as-from-national-news-outlets/
  "TRUST IN THE INFORMATION THAT COMES FROM TRADITIONAL MEDIA:
DeD1) A lot of trust in the information that comes from Traditional Media
DeD2) Some trust in the information that comes from Traditional Media
DeD3) Not a lot of trust in the information that comes from Traditional Media
DeD4) No trust at all in the information that comes from Traditional Media

",
  "TRUST IN THE INFORMATION THAT COMES FROM NON-TRADITIONAL MEDIA, INCLUDING PODCASTS, BLOGS, SOCIAL-MEDIA, etc.:
DeE1) A lot of trust in the information that comes from Non-traditional Media, including podcasts, blogs, social-media, etc.
DeE2) Some trust in the information that comes from Non-traditional Media, including podcasts, blogs, social-media, etc.
DeE3) Not a lot of trust in the information that comes from Non-traditional Media, including podcasts, blogs, social-media, etc.
DeE4) No trust at all in the information that comes from Non-traditional Media, including podcasts, blogs, social-media, etc.

",
  # CLIMATE CHANGE  
  # https://www.pewresearch.org/science/2019/11/25/u-s-public-views-on-climate-and-energy/
  "OPINION ON INCREASING THE PRODUCTION, AVAILABILITY AND USAGE OF ENERGY FROM SOLAR POWER OR WIND TURBINE FARMS:
ClA1) Strongly agree with increasing the production, availability and usage of energy from solar power or wind turbine farms
ClA2) Somewhat agree with increasing the production, availability and usage of energy from solar power or wind turbine farms
ClA3) Somewhat disagree with increasing the production, availability and usage of energy from solar power or wind turbine farms
ClA4) Strongly disagree with increasing the production, availability and usage of energy from solar power or wind turbine farms

",
  "OPINION ON INCREASING THE PRODUCTION, AVAILABILITY AND USAGE OF ENERGY FROM NUCLEAR POWER PLANTS:
ClC1) Strongly agree with increasing the production, availability and usage of energy from nuclear power plants
ClC2) Somewhat agree with increasing the production, availability and usage of energy from nuclear power plants
ClC3) Somewhat disagree with increasing the production, availability and usage of energy from nuclear power plants
ClC4) Strongly disagree with increasing the production, availability and usage of energy from nuclear power plants

",
  "OPINION ON INCREASING THE PRODUCTION, AVAILABILITY AND USAGE OF ENERGY FROM HYDRAULIC FRACTURING - ALSO KNOWN AS FRACKING: 
ClD1) Strongly agree with increasing the production, availability and usage of energy from hydraulic fracturing - also known as fracking
ClD2) Somewhat agree with increasing the production, availability and usage of energy from hydraulic fracturing - also known as fracking
ClD3) Somewhat disagree with increasing the production, availability and usage of energy from hydraulic fracturing - also known as fracking
ClD4) Strongly disagree with increasing the production, availability and usage of energy from hydraulic fracturing - also known as fracking

",
  "OPINION ON INCREASING THE PRODUCTION, AVAILABILITY AND USAGE OF ENERGY FROM OFFSHORE OIL AND GAS DRILLING:
ClE1) Strongly agree with increasing the production, availability and usage of energy from offshore oil and gas drilling
ClE2) Somewhat agree with increasing the production, availability and usage of energy from offshore oil and gas drilling
ClE3) Somewhat disagree with increasing the production, availability and usage of energy from offshore oil and gas drilling
ClE4) Strongly disagree with increasing the production, availability and usage of energy from offshore oil and gas drilling

",
  "OPINION ON INCREASING THE PRODUCTION, AVAILABILITY AND USAGE OF ENERGY FROM COAL MINING:
ClF1) Strongly agree with increasing the production, availability and usage of energy from coal mining
ClF2) Somewhat agree with increasing the production, availability and usage of energy from coal mining
ClF3) Somewhat disagree with increasing the production, availability and usage of energy from coal mining
ClF4) Strongly disagree with increasing the production, availability and usage of energy from coal mining

",
  # https://www.pewresearch.org/short-reads/2023/08/09/what-the-data-says-about-americans-views-of-climate-change/
  "OPINION ON THE STATEMENT << CLIMATE CHANGE IS A MAJOR THREAT TO THE UNITED STATES >>:
ClG1) Strongly agree with the statement << Climate change is a major threat to the United States >>
ClG2) Somewhat agree with the statement << Climate change is a major threat to the United States >>
ClG3) Somewhat disagree with the statement << Climate change is a major threat to the United States >>
ClG4) Strongly disagree with the statement << Climate change is a major threat to the United States >>

",
  # ISRAEL / PALESTINE 
  # https://www.pewresearch.org/2024/03/21/majority-in-u-s-say-israel-has-valid-reasons-for-fighting-fewer-say-the-same-about-hamas/
"OPINION ON WHICH SIDE HAS MORE VALID REASONS IN THE ISRAEL-HAMAS WAR:
IsA1) Israel has much more valid reasons for waging war against Hamas than Hamas has for waging war against Israel
IsA2) Israel has somewhat more valid reasons for waging war against Hamas than Hamas has for waging war against Israel
IsA3) Israel's reasons for waging war against Hamas and Hamas' reasons for waging war against Israel are equally valid
IsA4) Hamas has somewhat more valid reasons for waging war against Israel than Israel has for waging war against Hamas
IsA5) Hamas has much more valid reasons for waging war against Israel than Israel has for waging war against Hamas

", 
  "OPINION ON THE STATEMENT << THE US SHOULD STOP PROVIDING MILITARY AID TO ISRAEL, AND PUSH FOR AN IMMEDIATE CEASEFIRE IN THE ISRAEL-HAMAS WAR >>:
IsC1) Strongly agree with << The US should stop providing military aid to Israel, and push for an immediate ceasefire in the Israel-Hamas war >>
IsC2) Somewhat agree with << The US should stop providing military aid to Israel, and push for an immediate ceasefire in the Israel-Hamas war >>
IsC3) Somewhat disagree with << The US should stop providing military aid to Israel, and push for an immediate ceasefire in the Israel-Hamas war >>
IsC4) Strongly disagree with << The US should stop providing military aid to Israel, and push for an immediate ceasefire in the Israel-Hamas war >>

",
  # UKRAINE / RUSSIA 
"OPINION ON WHICH SIDE HAS MORE VALID REASONS IN THE RUSSIA-UKRAINE WAR:
UkA1) Russia has much more valid reasons for invading Ukraine than Ukraine and its Western allies have for opposing the Russian invasion
UkA2) Russia has somehwat more valid reasons for invading Ukraine than Ukraine and its Western allies have for opposing the Russian invasion
UkA3) Russia's reasons for invading Ukraine, and Ukraine's reasons for opposing the Russian invasion with the help of western allies, are equally valid
UkA4) Ukraine and its western allies have somewhat more valid reasons for opposing the Russian invasion than Russia has for invading Ukraine
UkA5) Ukraine and its western allies have much more valid reasons reasons for opposing the Russian invasion than Russia has for invading Ukraine

", 
  "OPINION ON THE STATEMENT << THE US SHOULD STOP PROVIDING MILITARY AID TO UKRAINE, AND PUSH FOR AN IMMEDIATE CEASEFIRE IN THE RUSSIA-UKRAINE WAR >>:
UkC1) Strongly agree with << The US should stop providing military aid to Ukraine, and push for an immediate ceasefire in the Russia-Ukraine war >>
UkC2) Somewhat agree with << The US should stop providing military aid to Ukraine, and push for an immediate ceasefire in the Russia-Ukraine war >>
UkC3) Somewhat disagree with << The US should stop providing military aid to Ukraine, and push for an immediate ceasefire in the Russia-Ukraine war >>
UkC4) Strongly disagree with << The US should stop providing military aid to Ukraine, and push for an immediate ceasefire in the Russia-Ukraine war >>

",
  # Protectionsim 
  # https://www.pewresearch.org/short-reads/2024/03/12/majorities-of-adults-see-decline-of-union-membership-as-bad-for-the-us-and-working-people/
  "OPINION ON THE LARGE REDUCTION IN THE PERCENTAGE OF WORKERS REPRESENTED BY UNIONS:
PrA1) The large drop in union membership has been very bad for working people
PrA2) The large drop in union membership has been somewhat bad for working people
PrA3) The large drop in union membership has made no difference to working people
PrA4) The large drop in union membership has been somewhat good for working people
PrA5) The large drop in union membership has been very good for working people

",
  # Protect workers from foreign competition / offshoring 
  # https://www.pewresearch.org/social-trends/2016/10/06/the-state-of-american-jobs/#:~:text=The%20public%20sees%20threats%20to,the%20U.S.%20has%20been%20harmful.
  "OPINION ON THE STATEMENT << OUTSOURCING JOBS TO OTHER COUNTRIES HARMS US WORKERS >>:
PrB1) Strongly agree with the statement << Outsourcing jobs to other countries harms US workers >>
PrB2) Somewhat agree with the statement << Outsourcing jobs to other countries harms US workers >>
PrB4) Somewhat disagree with the statement << Outsourcing jobs to other countries harms US workers >>
PrB5) Strongly disagree with the statement << Outsourcing jobs to other countries harms US workers >>

",
  # Political discourse style
  # https://www.pewresearch.org/politics/2019/06/19/public-highly-critical-of-state-of-political-discourse-in-the-u-s/
  "OPINION ON THE STATEMENT << THE TONE OF POLITICAL DISCOURSE IN THE U.S. HAS BECOME MORE NEGATIVE >>:
DiA1) Strongly agree with the statement << The tone of political discourse in the U.S. has become more negative >>
DiA2) Somewhat agree with the statement << The tone of political discourse in the U.S. has become more negative >>
DiA3) Somewhat disagree with the statement << The tone of political discourse in the U.S. has become more negative >>
DiA4) Strongly disagree with the statement << The tone of political discourse in the U.S. has become more negative >>

",
  "OPINION ON THE STATEMENT << HEATED RHETORIC BY POLITICIANS INCREASES THE RISK OF POLITICAL VIOLENCE >>:
DiB1) Strongly agree with the statement << Heated rhetoric by politicians increases the risk of political violence >>
DiB2) Somewhat agree with the statement << Heated rhetoric by politicians increases the risk of political violence >>
DiB3) Somewhat disagree with the statement << Heated rhetoric by politicians increases the risk of political violence >>
DiB4) Strongly disagree with the statement << Heated rhetoric by politicians increases the risk of political violence >>

"
)
