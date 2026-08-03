
// function for ICAR prior
functions {
  real icar_normal_lpdf(vector phi, int N_edges,
                        array[] int node1, array[] int node2) {
    return -0.5 * dot_self(phi[node1] - phi[node2]);
  }
}

data {
  int<lower=1> N;               // number of survey respondents
  int<lower=2> K;               // number of belief categories
  array[N] int<lower=1, upper=K> y; //outcome variable(order 1..K)

  // levels for each variable
  int<lower=1> J_sex;           
  int<lower=1> J_age;
  int<lower=1> J_eth;
  int<lower=1> J_income;
  int<lower=1> J_education;
  int<lower=1> J_vote;
  int<lower=1> J_time;
  int<lower=1> N_states;

  // map each respondent to their demographic levels
  array[N] int<lower=1, upper=J_sex> sex_idx; 
  array[N] int<lower=1, upper=J_age> age_idx;
  array[N] int<lower=1, upper=J_eth> eth_idx;
  array[N] int<lower=1, upper=J_income> income_idx;
  array[N] int<lower=1, upper=J_education> education_idx;
  array[N] int<lower=1, upper=J_vote> vote_idx;
  array[N] int<lower=1, upper=J_time> time_idx;
  array[N] int<lower=1, upper=N_states> state_idx;

  // ICAR structure
  int<lower=1> N_edges;
  array[N_edges] int node1;
  array[N_edges] int node2;

  int<lower=1> k;                           // number of connected components
  array[k] int group_size;                  // size of each connected component
  array[N_states] int group_idx;           // component assignment for each state

  // state level fixed effects
  int<lower=1> P;
  matrix[N_states, P] LP;

  // Poststratification prediction rows

  int<lower=1> N_pred;
  array[N_pred] int<lower=1, upper=J_sex> pred_sex_idx;
  array[N_pred] int<lower=1, upper=J_age> pred_age_idx;
  array[N_pred] int<lower=1, upper=J_eth> pred_eth_idx;
  array[N_pred] int<lower=1, upper=J_income> pred_income_idx;
  array[N_pred] int<lower=1, upper=J_education> pred_education_idx;
  array[N_pred] int<lower=1, upper=J_vote> pred_vote_idx;
  array[N_pred] int<lower=1, upper=J_time> pred_time_idx;
  array[N_pred] int<lower=1, upper=N_states> pred_state_idx;
}

parameters {
  ordered[K-1] kappa;

  sum_to_zero_vector[J_sex] eta_sex; 
  sum_to_zero_vector[J_age] eta_age;             
  sum_to_zero_vector[J_eth] eta_eth;
  sum_to_zero_vector[J_income] eta_income; 
  sum_to_zero_vector[J_education] eta_education;     
  sum_to_zero_vector[J_vote] eta_vote;
  sum_to_zero_vector[J_time] eta_time;

  // Two-way interactions with time
  sum_to_zero_matrix[J_time, J_sex] eta_time_sex;
  sum_to_zero_matrix[J_time, J_age] eta_time_age;
  sum_to_zero_matrix[J_time, J_eth] eta_time_eth;
  sum_to_zero_matrix[J_time, J_income] eta_time_income;
  sum_to_zero_matrix[J_time, J_education] eta_time_education;
  sum_to_zero_matrix[J_time, J_vote] eta_time_vote;

  vector[N_states] eta_state_raw;
  vector[P] beta_LP;

  real<lower=0> sigma_sex;
  real<lower=0> sigma_age;
  real<lower=0> sigma_eth;
  real<lower=0> sigma_income;
  real<lower=0> sigma_education;
  real<lower=0> sigma_vote;
  real<lower=0> sigma_time;
  real<lower=0> sigma_state;

  // Interaction scales
  real<lower=0> sigma_time_sex;
  real<lower=0> sigma_time_age;
  real<lower=0> sigma_time_eth;
  real<lower=0> sigma_time_income;
  real<lower=0> sigma_time_education;
  real<lower=0> sigma_time_vote;
}

transformed parameters {
  vector[J_sex] eta_sex_star = eta_sex * sigma_sex;
  vector[J_age] eta_age_star = eta_age * sigma_age;
  vector[J_eth] eta_eth_star = eta_eth * sigma_eth;
  vector[J_income] eta_income_star = eta_income * sigma_income;
  vector[J_education] eta_education_star = eta_education * sigma_education;
  vector[J_vote] eta_vote_star = eta_vote * sigma_vote;
  vector[J_time] eta_time_star = eta_time * sigma_time;

  matrix[J_time, J_sex] eta_time_sex_star = eta_time_sex * sigma_time_sex;
  matrix[J_time, J_age] eta_time_age_star = eta_time_age * sigma_time_age;
  matrix[J_time, J_eth] eta_time_eth_star = eta_time_eth * sigma_time_eth;
  matrix[J_time, J_income] eta_time_income_star = eta_time_income * sigma_time_income;
  matrix[J_time, J_education] eta_time_education_star = eta_time_education * sigma_time_education;
  matrix[J_time, J_vote] eta_time_vote_star = eta_time_vote * sigma_time_vote;
  vector[N_states] mu_state_LP = LP * beta_LP;
  vector[N_states] eta_state = sigma_state * eta_state_raw;
}

model {
  // Priors
  kappa ~ normal(0, 3);
  beta_LP ~ normal(0, 1);

   // prior on the constrained vector 
  eta_sex ~ normal(0, 1);
  eta_eth ~ normal(0, 1);
  eta_vote ~ normal(0, 1);
  eta_education ~ normal(0, 1);

  // prior on the interaction terms
  to_vector(eta_time_sex) ~ normal(0, 1);
  to_vector(eta_time_age) ~ normal(0, 1);
  to_vector(eta_time_eth) ~ normal(0, 1);
  to_vector(eta_time_income) ~ normal(0, 1);
  to_vector(eta_time_education) ~ normal(0, 1);
  to_vector(eta_time_vote) ~ normal(0, 1);

  sigma_sex ~ normal(0, 1);
  sigma_age ~ normal(0, 1);
  sigma_eth ~ normal(0, 1);
  sigma_income ~ normal(0, 1);
  sigma_education ~ normal(0, 1);
  sigma_vote ~ normal(0, 1);
  sigma_time ~ normal(0, 1);
  sigma_state ~ normal(0, 1);

  sigma_time_sex ~ normal(0, 1);
  sigma_time_age ~ normal(0, 1);
  sigma_time_eth ~ normal(0, 1);
  sigma_time_income ~ normal(0, 1);
  sigma_time_education ~ normal(0, 1);
  sigma_time_vote ~ normal(0, 1);

  for (i in 2:J_age) {
    eta_age[i] ~ normal(eta_age[i-1], 1);
  }
  for (i in 2:J_income) {
    eta_income[i] ~ normal(eta_income[i-1], 1);
  }
  for (i in 2:J_time) {
    eta_time[i] ~ normal(eta_time[i-1], 1);
  }

  // ICAR prior on raw spatial effects
  target += icar_normal_lpdf(eta_state_raw | N_edges, node1, node2);
  
  // Sum-to-zero constraint per connected component (island can have free prior)
  for (j in 1:k) {
  if (group_size[j] > 1) {
    // Soft sum-to-zero constraint for proper ICAR within this component
    real component_sum = 0;
    for (i in 1:N_states) {
      if (group_idx[i] == j) {
        component_sum += eta_state_raw[i];
      }
    }
    target += normal_lpdf(component_sum | 0, 0.001 * group_size[j]);
  } else {
    // Island component: give the singleton node a proper iid prior
    for (i in 1:N_states) {
      if (group_idx[i] == j) {
        eta_state_raw[i] ~ normal(0, 1);
      }
    }
  }
}

  // Ordered logistic likelihood
  for (i in 1:N) {
    real mu = eta_sex_star[sex_idx[i]]
              + eta_age_star[age_idx[i]]
              + eta_eth_star[eth_idx[i]]
              + eta_income_star[income_idx[i]]
              + eta_vote_star[vote_idx[i]]
              + eta_education_star[education_idx[i]]
              + eta_time_star[time_idx[i]]
              + eta_time_sex_star[time_idx[i], sex_idx[i]]
              + eta_time_age_star[time_idx[i], age_idx[i]]
              + eta_time_eth_star[time_idx[i], eth_idx[i]]
              + eta_time_income_star[time_idx[i], income_idx[i]]
              + eta_time_education_star[time_idx[i], education_idx[i]]
              + eta_time_vote_star[time_idx[i], vote_idx[i]]
              + eta_state[state_idx[i]]
              + mu_state_LP[state_idx[i]];
    y[i] ~ ordered_logistic(mu, kappa);
  }
}

generated quantities {

  vector[N_pred] mu_pred;
  vector[N_pred] expected_y_pred;
  array[N_pred] simplex[K] prob_pred;

  for (i in 1:N_pred) {
    mu_pred[i] = eta_sex_star[pred_sex_idx[i]]
                 + eta_age_star[pred_age_idx[i]]
                 + eta_eth_star[pred_eth_idx[i]]
                 + eta_income_star[pred_income_idx[i]]
                 + eta_vote_star[pred_vote_idx[i]]
                 + eta_education_star[pred_education_idx[i]]
                 + eta_time_star[pred_time_idx[i]]
                 + eta_time_sex_star[pred_time_idx[i], pred_sex_idx[i]]
                 + eta_time_age_star[pred_time_idx[i], pred_age_idx[i]]
                 + eta_time_eth_star[pred_time_idx[i], pred_eth_idx[i]]
                 + eta_time_income_star[pred_time_idx[i], pred_income_idx[i]]
                 + eta_time_education_star[pred_time_idx[i], pred_education_idx[i]]
                 + eta_time_vote_star[pred_time_idx[i], pred_vote_idx[i]]
                 + eta_state[pred_state_idx[i]]
                 + mu_state_LP[pred_state_idx[i]];

    prob_pred[i, 1] = inv_logit(kappa[1] - mu_pred[i]);
    for (k_cat in 2:(K - 1)) {
      prob_pred[i, k_cat] = inv_logit(kappa[k_cat] - mu_pred[i]) - inv_logit(kappa[k_cat - 1] - mu_pred[i]);
    }
    prob_pred[i, K] = 1 - inv_logit(kappa[K - 1] - mu_pred[i]);

    expected_y_pred[i] = 0;
    for (k_cat in 1:K) {
      expected_y_pred[i] += k_cat * prob_pred[i, k_cat];
    }
  }
}
