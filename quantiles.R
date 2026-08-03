# install & load
install.packages("distfromq")
library(distfromq)

# example quantiles
ps <- c(0.10, 0.25, 0.50, 0.75, 0.90)
qs <- c(5,     7,     10,    15,    20)   # these are the quantile values

# build distribution functions
p_approx <- make_p_fn(ps = ps, qs = qs, tail_dist = "norm")
d_approx <- make_d_fn(ps = ps, qs = qs, tail_dist = "norm")
q_approx <- make_q_fn(ps = ps, qs = qs, tail_dist = "norm")
r_approx <- make_r_fn(ps = ps, qs = qs, tail_dist = "norm")

# evaluate the approx. CDF at some x
p_approx(c(8, 12, 18)) #percentage of population below certain value

# density at some points
d_approx(c(8, 12, 18)) #

# sample 1000 values from the reconstructed distribution
sim_samples <- r_approx(1000)

# get approximate quantiles
q_approx(c(0.01, 0.5, 0.99))