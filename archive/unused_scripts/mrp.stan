
functions {
  real icar_normal_lpdf(vector phi, int N_edges,
                        array[] int node1, array[] int node2) {
    return -0.5 * dot_self(phi[node1] - phi[node2]);
  }
}

data {
  int<lower=1> N;                   
  int<lower=2> K;                 
  array[N] int<lower=1, upper=K> y;

  int<lower=1> J_sex;
  int<lower=1> J_age;
  int<lower=1> J_eth;
  int<lower=1> J_income;
  int<lower=1> J_vote;
  int<lower=1> N_regions;

  array[N] int<lower=1, upper=J_sex> sex_idx;
  array[N] int<lower=1, upper=J_age> age_idx;
  array[N] int<lower=1, upper=J_eth> eth_idx;
  array[N] int<lower=1, upper=J_income> income_idx;
  array[N] int<lower=1, upper=J_vote> vote_idx;
  array[N] int<lower=1, upper=N_regions> state_idx;

  // ICAR structure
  int<lower=1> N_edges;
  array[N_edges] int node1;
  array[N_edges] int node2;

  int<lower=1> k;                           // number of connected components
  array[k] int group_size;                  // size of each connected component
  array[N_regions] int group_idx;           // component assignment for each region
  vector[k] inv_sqrt_scale_factor;          // ICAR variance scale adjustment

  // For handling disconnected components
  int<lower=0> m;                           // number of extra intercepts needed
  matrix[N_regions, m] A;                   // constraint matrix for multiple components

  // state level fixed effects
  int<lower=1> P;                           // number of state-level predictors
  matrix[N_regions, P] LP;                  // state-level predictor matrix
}

parameters {
  real alpha;
  ordered[K-1] kappa;

  vector[J_sex-1] eta_sex_tilde;
  vector[J_age-1] eta_age_raw;             
  vector[J_eth-1] eta_eth_tilde;
  vector[J_income-1] eta_income_raw;      
  vector[J_vote-1] eta_vote_tilde;
  vector[N_regions] eta_state_raw;
  vector[P] beta_LP;

  real<lower=0> sigma_sex;
  real<lower=0> sigma_age;
  real<lower=0> sigma_eth;
  real<lower=0> sigma_income;
  real<lower=0> sigma_vote;
  real<lower=0> sigma_state;

  vector[m] alpha_component;                // Extra intercepts for disconnected components
}

transformed parameters {
  vector[J_sex] eta_sex;
  vector[J_age] eta_age;
  vector[J_eth] eta_eth;
  vector[J_income] eta_income;
  vector[J_vote] eta_vote;
  vector[N_regions] eta_state;
  vector[N_regions] mu_state = LP * beta_LP;

  // Hard sum-to-zero constraints for sex, ethnicity, and vote
  for (i in 1:(J_sex-1)) eta_sex[i] = sigma_sex * eta_sex_tilde[i];
  eta_sex[J_sex] = -sum(eta_sex[1:(J_sex-1)]);

  for (i in 1:(J_eth-1)) eta_eth[i] = sigma_eth * eta_eth_tilde[i];
  eta_eth[J_eth] = -sum(eta_eth[1:(J_eth-1)]);

  for (i in 1:(J_vote-1)) eta_vote[i] = sigma_vote * eta_vote_tilde[i];
  eta_vote[J_vote] = -sum(eta_vote[1:(J_vote-1)]);

  // Random walk with hard sum-to-zero for age
  eta_age[1] = sigma_age * eta_age_raw[1];
  for (i in 2:(J_age-1)) {
    eta_age[i] = eta_age[i-1] + sigma_age * eta_age_raw[i];
  }
  // Last category forced to sum to zero
  eta_age[J_age] = -sum(eta_age[1:(J_age-1)]);

  // Random walk with hard sum-to-zero for income
  eta_income[1] = sigma_income * eta_income_raw[1];
  for (i in 2:(J_income-1)) {
    eta_income[i] = eta_income[i-1] + sigma_income * eta_income_raw[i];
  }
  eta_income[J_income] = -sum(eta_income[1:(J_income-1)]);

  // ICAR spatial effects with proper scaling
  for (i in 1:N_regions) {
    int component = group_idx[i];
    eta_state[i] = sigma_state * inv_sqrt_scale_factor[component] * eta_state_raw[i];
  }

  // allows disconnected geographic regions to have different baseline levels
  if (m > 0) {
    eta_state = eta_state + A * alpha_component;
  }
}

model {
  // Priors
  alpha ~ normal(0, 2);
  kappa ~ normal(0, 3);

  // Sum-to-zero effects
  eta_sex_tilde ~ normal(0, 1);
  eta_eth_tilde ~ normal(0, 1);
  eta_vote_tilde ~ normal(0, 1);

  // Random walk priors 
  eta_age_raw ~ normal(0, 1);
  eta_income_raw ~ normal(0, 1);

  sigma_sex ~ normal(0, 1);
  sigma_age ~ normal(0, 1);
  sigma_eth ~ normal(0, 1);
  sigma_income ~ normal(0, 1);
  sigma_vote ~ normal(0, 1);
  sigma_state ~ normal(0, 1);

  // ICAR prior on raw spatial effects
  target += icar_normal_lpdf(eta_state_raw | N_edges, node1, node2);

  // Sum-to-zero constraint per connected component
  for (j in 1:k) {
    real component_sum = 0;
    for (i in 1:N_regions) {
      if (group_idx[i] == j) {
        component_sum += eta_state_raw[i];
      }
    }
    target += normal_lpdf(component_sum | 0, 0.001 * group_size[j]);
  }

  // Prior on component intercepts
  if (m > 0) {
    alpha_component ~ normal(0, 1);
  }

  // Ordered logistic
  for (i in 1:N) {
    real mu = alpha
              + eta_sex[sex_idx[i]]
              + eta_age[age_idx[i]]
              + eta_eth[eth_idx[i]]
              + eta_income[income_idx[i]]
              + eta_vote[vote_idx[i]]
              + eta_state[state_idx[i]]
              + mu_state[state_idx[i]];
    y[i] ~ ordered_logistic(mu, kappa);
  }
}

generated quantities {
  vector[N] mu;
  vector[N] log_lik;

  for (i in 1:N) {
    mu[i] = alpha
            + eta_sex[sex_idx[i]]
            + eta_age[age_idx[i]]
            + eta_eth[eth_idx[i]]
            + eta_income[income_idx[i]]
            + eta_vote[vote_idx[i]]
            + eta_state[state_idx[i]]
            + mu_state[state_idx[i]];
    log_lik[i] = ordered_logistic_lpmf(y[i] | mu[i], kappa);
  }
}
