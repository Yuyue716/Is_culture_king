
# imports
import pandas as pd
import numpy as np
from cmdstanpy import CmdStanModel
import geopandas as gpd
from libpysal import weights
from sklearn.preprocessing import LabelEncoder
import networkx as nx
import re
import os
import pickle
import gc
from scipy.sparse import diags

# input files
strat_frame = pd.read_csv("../generated_data/feature_extraction/state_LP_cleaned_sf.csv")
df = pd.read_pickle('../generated_data/feature_extraction/preprocessed_cleaned_all_result.pkl')
belief_col = ['Belief_willingness_to_pay_higher_taxes_to_improve_the_level_of_health_care_for_all_people_in_the_united_states_Symbol',
             'Belief_opinion_on_the_following_statement_overall_vaccinations_do_more_harm_than_good_Symbol',
             'Belief_opinion_on_whether_courts_in_the_users_s_area_deal_too_harshly_or_not_harshly_enough_with_criminals_Symbol',
             'Belief_opinion_on_marijuana_legalisation_Symbol',
             'Belief_opinion_on_the_statement_a_person_should_require_a_police_permit_before_he_or_she_could_buy_a_gun_Symbol',
            'Belief_opinion_on_whether_white_people_benefit_from_societal_advantages_not_available_to_black_people_Symbol',
            'Belief_opinion_on_the_statement_the_us_should_provide_military_aid_to_israel_to_help_in_its_war_against_hamas_Symbol',
            'Belief_opinion_on_whether_the_us_has_a_responsibility_to_help_ukraine_defend_itself_from_russia_s_invasion_Symbol',
            'Belief_opinion_on_the_large_reduction_in_the_percentage_of_workers_represented_by_unions_Symbol'
            
            ]

predictor_cols = [
    "Demo_sex_Symbol",
    "Demo_age_Symbol",
    "Demo_ethnicity_Symbol",
    "Demo_income_Symbol",
    "Demo_education_Symbol",
    "Demo_past_vote_Symbol",
    "time_window_start",
    "state_cleaned"
]
df = df.dropna(subset=belief_col + predictor_cols)

# find all time windows
df['time_window_start'] = pd.to_datetime(df['time_window_start'])
time_window_sorted = df['time_window_start'].unique()
time_window_sorted = sorted(time_window_sorted)
time_window_map = {window: idx + 1 for idx, window in enumerate(time_window_sorted)}
df.loc[:, 'time_window_start_idx'] = df['time_window_start'].map(time_window_map)
time_window_mapping = df[['time_window_start', 'time_window_start_idx']].drop_duplicates().sort_values('time_window_start_idx')

# prepare spatial structure for ICAR
def edges_from_adjacency(W):
    all_edges = []
    n = W.shape[0]
    
    for i in range(n):
        neighbors = np.where(W[i, :] != 0)[0]
        for j in neighbors:
            if i < j:  
                all_edges.append({
                    'node1': i + 1,  
                    'node2': j + 1,
                    'weight': W[i, j]
                })
    
    return pd.DataFrame(all_edges)


def scale_c(C):
    N = C.shape[0]
    
    if hasattr(C, 'toarray'):
        C = C.toarray()
    C = np.asarray(C)
    
    row_sums = C.sum(axis=1).ravel()
    Q = diags(row_sums) - C
    
    Q_dense = Q.toarray() if hasattr(Q, 'toarray') else np.asarray(Q)
    max_diag = np.max(np.diag(Q_dense))
    jitter = max_diag * np.sqrt(np.finfo(float).eps)
    Q_pert = Q_dense + np.diag(np.ones(N) * jitter)
    
    Q_inv = np.linalg.pinv(Q_pert)
    
    variances = np.diag(Q_inv)
    scaling_factor = np.exp(np.mean(np.log(variances)))
    
    return scaling_factor


def prep_icar_data_from_weights(w, N_states):
    C = np.zeros((N_states, N_states))
    for i in range(N_states):
        for j in w.neighbors[i]:
            C[i, j] = 1

    E = edges_from_adjacency(C)
    
    G = nx.Graph()
    G.add_nodes_from(range(N_states))
    for _, row in E.iterrows():
        G.add_edge(int(row['node1']) - 1, int(row['node2']) - 1)
    
    components = list(nx.connected_components(G))
    k = len(components)
    
    comp_id = np.zeros(N_states, dtype=int)
    for idx, component in enumerate(components):
        for node in component:
            comp_id[int(node)] = idx
    
    group_size = np.array([len(comp) for comp in components])
    
    group_idx = comp_id + 1

    
    return {
        'k': int(k),
        'group_size': group_size.tolist(),
        'N_edges': len(E),
        'node1': E['node1'].values.tolist(),
        'node2': E['node2'].values.tolist(),
        'group_idx': group_idx.tolist()
    }


def moran_coefficient(x, W, warn=True):
    row_sums = W.sum(axis=1)
    zero_idx = np.where(row_sums == 0)[0]
    
    if len(zero_idx) > 0:
        if warn:
            print(f"{len(zero_idx)} observations with no neighbors. Dropping from calculation.")
        keep_idx = row_sums > 0
        x = x[keep_idx]
        W = W[np.ix_(keep_idx, keep_idx)]
    
    n = len(x)
    xbar = np.mean(x)
    z = x - xbar
    z_tilde = W @ z
    A = np.sum(W)
    mc = (n / A) * (z @ z_tilde) / (z @ z)
    
    return np.round(mc, 3)

# Build spatial structure
shp = gpd.read_file("../generated_data/tl_2025_us_state/tl_2025_us_state.shp")
shp["STATE"] = shp["STUSPS"].str.upper()

shp = shp[~shp["STATE"].isin(["PR", "GU", "VI", "MP", "AS"])]

shp = shp.sort_values("STATE").reset_index(drop=True)

state_order = shp["STATE"].tolist()
N_states = len(state_order)

print(f"Shapefile states: {N_states}")

w = weights.Queen.from_dataframe(shp)

icar_data = prep_icar_data_from_weights(w, N_states)

print(f"\nICAR structure:")
print(f"  Connected components: {icar_data['k']}")
print(f"  Component sizes: {icar_data['group_size']}")
print(f"  Number of edges: {icar_data['N_edges']}")

# Stan code
stan_code = '''
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
'''

# Compile and Sample

with open('mrp.stan', 'w') as f:
    f.write(stan_code)

model = CmdStanModel(stan_file='mrp.stan')


# check all belief_cols
# for belief in belief_col:
#     belief_lp_col = f"{belief}_LP"
#     if belief_lp_col in strat_frame.columns:
#         print(strat_frame[belief_lp_col])
#     else:
#         print(f"Skipped missing column: {belief_lp_col}")

# prepare data for Stan

# idx = (time_idx - 1) * J_predictor + predictor_idx
J_sex = int(strat_frame['sex_idx'].nunique())
J_age = int(strat_frame['age_idx'].nunique())
J_eth = int(strat_frame['eth_idx'].nunique())
J_income = int(strat_frame['income_idx'].nunique())
J_vote = int(strat_frame['vote_idx'].nunique())
J_education = int(strat_frame['education_idx'].nunique())
J_time = int(df['time_window_start'].nunique())

time_idx_arr = df['time_window_start_idx'].astype(int)
sex_idx_arr = df['Demo_sex_idx'].astype(int)
age_idx_arr = df['Demo_age_idx'].astype(int)
eth_idx_arr = df['Demo_ethnicity_idx'].astype(int)
income_idx_arr = df['Demo_income_idx'].astype(int)
vote_idx_arr = df['Demo_past_vote_idx'].astype(int)
education_idx_arr = df['Demo_education_idx'].astype(int)
state_idx_arr = df['state_cleaned_idx'].astype(int)

# Prediction rows: one row per poststrat cell
N_pred = len(strat_frame)
pred_sex_idx_arr = strat_frame['sex_idx'].astype(int)
pred_age_idx_arr = strat_frame['age_idx'].astype(int)
pred_eth_idx_arr = strat_frame['eth_idx'].astype(int)
pred_income_idx_arr = strat_frame['income_idx'].astype(int)
pred_vote_idx_arr = strat_frame['vote_idx'].astype(int)
pred_education_idx_arr = strat_frame['education_idx'].astype(int)
pred_state_idx_arr = strat_frame['state_idx'].astype(int)

# general stan data form
stan_data_common = {
    "N": len(df),

    # Predictor dimensions
    "J_sex": J_sex,
    "J_age": J_age,
    "J_eth": J_eth,
    "J_income": J_income,
    "J_vote": J_vote,
    "J_education": J_education,
    "J_time": J_time,
    "N_states": N_states,

    # Training indices
    "sex_idx": sex_idx_arr.tolist(),
    "age_idx": age_idx_arr.tolist(),
    "eth_idx": eth_idx_arr.tolist(),
    "income_idx": income_idx_arr.tolist(),
    "vote_idx": vote_idx_arr.tolist(),
    "education_idx": education_idx_arr.tolist(),
    "state_idx": state_idx_arr.tolist(),
    "time_idx": time_idx_arr.tolist(),

    # Prediction indices
    "N_pred": N_pred,
    "pred_sex_idx": pred_sex_idx_arr.tolist(),
    "pred_age_idx": pred_age_idx_arr.tolist(),
    "pred_eth_idx": pred_eth_idx_arr.tolist(),
    "pred_income_idx": pred_income_idx_arr.tolist(),
    "pred_education_idx": pred_education_idx_arr.tolist(),
    "pred_vote_idx": pred_vote_idx_arr.tolist(),
    "pred_time_idx": np.ones(N_pred, dtype=int).tolist(),
    "pred_state_idx": pred_state_idx_arr.tolist(),

    # Spatial structure
    **icar_data,
}

# some functions for predictions
def generate_cell_level_predictions_from_gq(
    gq,
    strat_frame,
    belief_col,
    n_keep_draws=250
):
    n_cells = len(strat_frame)
    
    # Extract draws: shape (total_draws, n_cells)
    expected_y_draws = gq.stan_variable('expected_y_pred')  # (draws, N_pred)
    prob_draws = gq.stan_variable('prob_pred')               # (draws, N_pred, K)
    
    n_draws_total = expected_y_draws.shape[0]
    K = prob_draws.shape[2]
    
    # Subsample draws
    draw_indices = np.sort(np.random.choice(n_draws_total, size=min(n_keep_draws, n_draws_total), replace=False))
    n_draws = len(draw_indices)
    
    expected_y_draws = expected_y_draws[draw_indices, :]   # (n_draws, n_cells)
    prob_draws = prob_draws[draw_indices, :, :]             # (n_draws, n_cells, K)
    
    print(f"Subsampling draws: using {n_draws} out of {n_draws_total} posterior draws")
    
    cell_id = np.arange(n_cells, dtype=int)
    
    # Transpose for percentile calcs: (n_cells, n_draws)
    ev = expected_y_draws.T
    pr = prob_draws.transpose(1, 0, 2)  # (n_cells, n_draws, K)
    
    # --- Summary stats for expected value ---
    prediction_summary_df = pd.DataFrame({
        'cell_id': cell_id,
        f'{belief_col}_pred_mean':     np.mean(ev, axis=1),
        f'{belief_col}_pred_median':   np.median(ev, axis=1),
        f'{belief_col}_pred_sd':       np.std(ev, axis=1),
        f'{belief_col}_pred_lower_95': np.percentile(ev, 2.5, axis=1),
        f'{belief_col}_pred_upper_95': np.percentile(ev, 97.5, axis=1),
        f'{belief_col}_pred_lower_90': np.percentile(ev, 5, axis=1),
        f'{belief_col}_pred_upper_90': np.percentile(ev, 95, axis=1),
        f'{belief_col}_pred_lower_80': np.percentile(ev, 10, axis=1),
        f'{belief_col}_pred_upper_80': np.percentile(ev, 90, axis=1),
        f'{belief_col}_pred_lower_68': np.percentile(ev, 16, axis=1),
        f'{belief_col}_pred_upper_68': np.percentile(ev, 84, axis=1),
    })
    
    # --- Per-category summary stats ---
    for k in range(K):
        pk = pr[:, :, k]  # (n_cells, n_draws)
        cat = k + 1
        prediction_summary_df[f'{belief_col}_prob_cat_mean_{cat}']     = np.mean(pk, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_median_{cat}']   = np.median(pk, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_sd_{cat}']       = np.std(pk, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_lower_95_{cat}'] = np.percentile(pk, 2.5, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_upper_95_{cat}'] = np.percentile(pk, 97.5, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_lower_90_{cat}'] = np.percentile(pk, 5, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_upper_90_{cat}'] = np.percentile(pk, 95, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_lower_80_{cat}'] = np.percentile(pk, 10, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_upper_80_{cat}'] = np.percentile(pk, 90, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_lower_68_{cat}'] = np.percentile(pk, 16, axis=1)
        prediction_summary_df[f'{belief_col}_prob_cat_upper_68_{cat}'] = np.percentile(pk, 84, axis=1)
    
    # --- Expected value draws df ---
    expected_value_draws_df = pd.DataFrame(
        ev,  # (n_cells, n_draws)
        columns=[f'draw_{i+1}' for i in range(n_draws)]
    )
    expected_value_draws_df.insert(0, 'cell_id', cell_id)
    
    # --- Category probability draws df ---
    prob_draw_cols = []
    prob_draw_blocks = []
    for k in range(K):
        cols_k = [f'prob_cat_{k+1}_draw_{i+1}' for i in range(n_draws)]
        prob_draw_cols.extend(cols_k)
        prob_draw_blocks.append(pr[:, :, k])  # (n_cells, n_draws)
    
    prob_category_draws_df = pd.DataFrame(
        np.concatenate(prob_draw_blocks, axis=1),
        columns=prob_draw_cols
    )
    prob_category_draws_df.insert(0, 'cell_id', cell_id)
    
    return prediction_summary_df, expected_value_draws_df, prob_category_draws_df, K, draw_indices


# weighted group means and summaries

def aggregate_draws_by_group(draws_df, group_col):
    """
    Aggregate expected value draws by a single group column with posterior weight draws.
    - For each weight draw, compute weighted aggregate of belief draws
    - Average the aggregated results across all weight draws
    """
    draw_cols = [c for c in draws_df.columns if c.startswith('draw_')]
    if not draw_cols:
        raise ValueError("No draw_* columns found in draws_df.")

    # Check for posterior weight draws (N_star.1, N_star.2, ..., N_star.104)
    n_star_cols = [c for c in draws_df.columns if c.startswith('N_star.')]
    n_star_draws = sorted([c for c in n_star_cols if re.match(r'N_star\.\d+$', c)])
    
    print(f"Using {len(n_star_draws)} posterior weight draws for aggregation")
    all_results = []
        
    weight_indices = np.random.choice(len(n_star_draws), size = len(draw_cols))
    selected_weights = [n_star_draws[idx] for idx in weight_indices]

    for draw_col, weight_col in zip(draw_cols, selected_weights):
        w = draws_df[weight_col].astype(float)
        weighted_draw = draws_df[draw_col] * w
        num = weighted_draw.groupby(draws_df[group_col]).sum() #the sum for the expected belief value in the demographic group
        den = w.groupby(draws_df[group_col]).sum() # the sum of weights in one demographic group
        group_result = (num/den).reset_index()
        group_result.columns = [group_col, draw_col]
        group_result.set_index(group_col, inplace=True)  # Set group_col as index for proper concatenation
        all_results.append(group_result)
    
    # Concatenate along axis=1 and reset index to get the group column back
    group_draws = pd.concat(all_results, axis=1).reset_index()

    return group_draws #(row = n_groups, columns = group_col + draw_cols)

def summarize_group_draws(group_draws_df, group_col):
    draw_cols = [c for c in group_draws_df.columns if c.startswith('draw_')]
    vals = group_draws_df[draw_cols]
    out = pd.DataFrame({group_col: group_draws_df[group_col]})
    out['pred_mean'] = vals.mean(axis=1)
    out['pred_median'] = vals.median(axis=1)
    out['pred_lower_95'] = vals.quantile(0.025, axis=1)
    out['pred_upper_95'] = vals.quantile(0.975, axis=1)
    out['pred_lower_90'] = vals.quantile(0.05, axis=1)
    out['pred_upper_90'] = vals.quantile(0.95, axis=1)
    out['pred_lower_80'] = vals.quantile(0.10, axis=1)
    out['pred_upper_80'] = vals.quantile(0.90, axis=1)
    out['pred_lower_68'] = vals.quantile(0.16, axis=1)
    out['pred_upper_68'] = vals.quantile(0.84, axis=1)
    out['pred_sd'] = vals.std(axis=1)
    return out # (row = n_groups, columns = group_col + 5 summary stats)

# compute group-level category probabilities from cell-level predictions
def compute_group_category_probabilities(pred_df, belief_col, group_col):
    """
    - For each weight draw, compute weighted group category probabilities
    - Average results across all 104 weight draws
    """
    cat_cols = [c for c in pred_df.columns if c.startswith(f"{belief_col}_prob_cat_mean_")]
    K = max(sorted(int(c.split('_')[-1]) for c in cat_cols)) #number of categories

    n_star_cols = [c for c in pred_df.columns if c.startswith('N_star.')]
    n_star_draws = sorted([c for c in n_star_cols if re.match(r'N_star\.\d+$', c)])
    
    # Randomly sample one weight for each category
    weight_indices = np.random.choice(len(n_star_draws), size=K)
    selected_weights = [n_star_draws[idx] for idx in weight_indices]
    
    # Compute weighted means per category using randomly selected weights
    out_rows = []
    for k in range(1, K+1):
        col_k = f"{belief_col}_prob_cat_mean_{k}"
        if col_k not in pred_df.columns:
            continue
        
        # Use randomly selected weight for this category
        w_col = selected_weights[k-1]
        w = pred_df[w_col].astype(float)
        
        # Compute weighted aggregation
        num_by_group = (pred_df[col_k] * w).groupby(pred_df[group_col]).sum()
        denom_by_group = w.groupby(pred_df[group_col]).sum()
        prob_by_group = (num_by_group / denom_by_group).reset_index()
        prob_by_group.columns = [group_col, 'prob_mean']
        prob_by_group['category'] = k
        out_rows.append(prob_by_group)
    
    if not out_rows:
        raise ValueError(f"No results generated during aggregation. Check that belief column '{belief_col}' and weight columns are present in pred_df.")
    
    final_result = pd.concat(out_rows, ignore_index=True)
    
    return final_result # (row = n_groups * K, columns = group_col, category, prob_mean)

def compute_national_draws(draws_df, seed=123):
    draw_cols = [c for c in draws_df.columns if c.startswith("draw_")]
    n_star_draws = sorted([c for c in draws_df.columns if re.match(r"N_star\.\d+$", c)])
    if not draw_cols:
        raise ValueError("No draw_* columns found for national aggregation.")
    if not n_star_draws:
        raise ValueError("No N_star.* columns found for national aggregation.")

    rng = np.random.default_rng(seed)
    weight_indices = rng.choice(len(n_star_draws), size=len(draw_cols), replace=True)
    selected_weights = [n_star_draws[i] for i in weight_indices]

    rows = []
    for draw_col, w_col in zip(draw_cols, selected_weights):
        w = draws_df[w_col].astype(float)
        num = (draws_df[draw_col] * w).sum()
        den = w.sum()
        rows.append({
            "draw": draw_col,
            "expected_value": num / den,
            "weight_col": w_col
        })

    return pd.DataFrame(rows)


def national_draws_to_wide(national_draws, group_col="group"):
    wide = national_draws.set_index("draw")["expected_value"].to_frame().T
    wide.insert(0, group_col, "national")
    return wide

# ----- Generate window-specific predictions from same posterior -----
# time_window_mapping = (
#     df[['time_window_start', 'time_window_start_idx']]
#     .drop_duplicates()
#     .sort_values('time_window_start_idx')
# )
# Group mapping for consolidation
group_map = [
    ('state_simple', 'state'),
    ('state_idx', 'state_idx'),
    ('sex_idx', 'sex'),
    ('age_idx', 'age'),
    ('eth_idx', 'eth'),
    ('income_idx', 'income'),
    ('vote_idx', 'vote'),
    ('education_idx', 'education')
]
# columns needed only for downstream aggregation / weighting
n_star_cols = [c for c in strat_frame.columns if c.startswith('N_star.')]
n_star_draws = sorted([c for c in n_star_cols if re.match(r'N_star\.\d+$', c)])
merge_cols = ['state_simple', 'state_idx', 'sex_idx', 'age_idx', 'eth_idx', 'income_idx', 'vote_idx', 'education_idx']
# merge_cols = [c for c in merge_cols if c in strat_frame.columns]
broad_cols = ['age_broad', 'eth_broad', 'education_broad', 'income_broad', 'vote_broad', 'sex_broad']
meta_cols = ['N_star.median'] + merge_cols + n_star_draws + broad_cols
# Startup progress overview for resume runs
import gc


total_windows = len(time_window_mapping)
print("\n===== Resume Progress Overview =====")
for belief in belief_col:
    base_dir = f"../generated_data/{belief}"
    belief_done_path = f"{base_dir}/belief_done.ok"
    completed_windows = 0

    for window in time_window_mapping['time_window_start']:
        window_label = pd.Timestamp(window).strftime('%Y-%m-%d')
        model_dir = f"{base_dir}/{belief}_{window_label}_stan_output"
        window_done_path = f"{model_dir}/window_done.ok"
        if os.path.exists(window_done_path):
            completed_windows += 1

    if os.path.exists(belief_done_path):
        status = "DONE"
    elif completed_windows > 0:
        status = "IN PROGRESS"
    else:
        status = "NOT STARTED"

    print(f"- {belief}: {completed_windows}/{total_windows} windows completed [{status}]")
print("===================================\n")

for belief in belief_col:
    # state level fixed effects
    base_lp_col = 'pct.2020.votes.R-D_zscore'
    belief_lp_candidates = [f'{belief}_LP', f'{belief}_LP_2']

    LP_cols = [base_lp_col] + [c for c in belief_lp_candidates if c in strat_frame.columns]
    print(f"Available LP columns for belief '{belief}': {LP_cols}")
    LP_state = (
        strat_frame
        .assign(STATE=strat_frame["state_abbreviation"].str.upper())
        .groupby("STATE")[LP_cols]
        .mean()
    )
    LP_state = LP_state.reindex(state_order)

    LP_mat = LP_state.values
    P = LP_mat.shape[1]

    print("LP_cols:", LP_cols)
    print("LP_mat shape:", LP_mat.shape)
    print(LP_mat)
    LP_df = pd.DataFrame(
        LP_mat,
        index=[s.upper() for s in state_order],
        columns=LP_cols
    )

    # Build one base data dict
    stan_data_base = {
        **stan_data_common,
        "K": df[f"{belief}_cat"].cat.categories.size,
        "y": df[f"{belief}_num"].astype(int).tolist(),
        "P": LP_mat.shape[1],
        "LP": LP_mat.tolist(),
    }

    base_dir = f"../generated_data/{belief}"
    os.makedirs(base_dir, exist_ok=True)

    global_model_dir = f"{base_dir}/all_time_train_stan_output"
    os.makedirs(global_model_dir, exist_ok=True)

    # Belief-level resume markers
    fit_path = f"{global_model_dir}/fit_full_train.pkl"
    summary_path = f"{global_model_dir}/mrp_summary.csv"
    belief_done_path = f"{base_dir}/belief_done.ok"

    # If this belief is already fully completed, skip it directly
    if os.path.exists(belief_done_path):
        print(f"Belief already completed, skipping: {belief}")
        continue

    # ----- Fit on full training data (resume if available) -----
    if os.path.exists(fit_path):
        print(f"Loading existing fit for belief: {belief}")
        with open(fit_path, "rb") as f:
            fit = pickle.load(f)
    else:
        print(f"Fitting full model once: N={len(df)}, J_time={J_time}")
        fit = model.sample(
            data=stan_data_base,
            chains=8,
            parallel_chains=8,
            iter_warmup=2000,
            iter_sampling=1000,
            adapt_delta=0.995,
            max_treedepth=13,
            thin=32,
            sig_figs=18,
            show_console=True,
            output_dir=global_model_dir
        )

        summary_df = fit.summary()
        summary_df.to_csv(summary_path, index=True)
        with open(fit_path, "wb") as f:
            pickle.dump(fit, f)
        print(f"Saved full-training fit to: {global_model_dir}")


    for i, row in enumerate(time_window_mapping.itertuples(index=False), start=1):
        window = row.time_window_start
        current_time_idx = int(row.time_window_start_idx)

        window_label = pd.Timestamp(window).strftime('%Y-%m-%d')
        model_dir = f"{base_dir}/{belief}_{window_label}_stan_output"
        os.makedirs(model_dir, exist_ok=True)

        # Window-level resume marker
        window_done_path = f"{model_dir}/window_done.ok"

        if os.path.exists(window_done_path):
            print(f"[{i}/{len(time_window_mapping)}] Window already done, skipping: {window_label}")
            continue

        pred_time_idx_arr = np.full(N_pred, current_time_idx, dtype=int)

        stan_data_pred = dict(stan_data_base)
        stan_data_pred.update({
            "pred_time_idx": pred_time_idx_arr.tolist()
        })

        print(f"[{i}/{len(time_window_mapping)}] Generating predictions for window={window_label} (time_idx={current_time_idx})")
        gq = model.generate_quantities(
            data=stan_data_pred,
            previous_fit=fit
        )

        prediction_summary_df, expected_value_draws_df, prob_category_draws_df, K, draw_indices = generate_cell_level_predictions_from_gq(
            gq,
            strat_frame,
            belief,
            n_keep_draws=250
        )

        # Free gq immediately after extracting draws
        del gq
        gc.collect()

        # Stratification rows must exactly match generated cell-level rows
        n_cells_expected = len(strat_frame)
        if (
            len(prediction_summary_df) != n_cells_expected
            or len(expected_value_draws_df) != n_cells_expected
            or len(prob_category_draws_df) != n_cells_expected
        ):
            warning_msg = (
                "WARNING: Length mismatch detected between stratification frame and cell-level outputs. "
                "Stopping execution with no fallback."
            )
            print(warning_msg)
            raise ValueError(warning_msg)

        # Save compact cell-level outputs
        prediction_summary_df.to_csv(f"{model_dir}/cell_level_predictions.csv", index=False)

        # Save selected draw indices
        pd.Series(draw_indices, name='draw_index').to_csv(f"{model_dir}/selected_draw_indices.csv", index=False)

        # Build merge-ready metadata frame (stable key + original order)
        merge_meta = strat_frame.reset_index(drop=True).loc[:, meta_cols].copy()
        merge_meta.insert(0, 'cell_id', np.arange(len(merge_meta), dtype=int))

        # Temporary frames for weighted aggregation only
        draws_for_agg = expected_value_draws_df.merge(merge_meta, on='cell_id', how='left')
        pred_for_agg = prediction_summary_df.merge(merge_meta, on='cell_id', how='left')

        # Free draws df after merge - no longer needed raw
        del expected_value_draws_df, prob_category_draws_df, prediction_summary_df, merge_meta
        gc.collect()

        # State-level aggregation and save (expected value draws)
        state_group_col = 'state_simple' if 'state_simple' in draws_for_agg.columns else ('state_idx' if 'state_idx' in draws_for_agg.columns else None)
        if state_group_col is not None:
            state_all_draws = aggregate_draws_by_group(draws_for_agg, state_group_col)
            state_preds = summarize_group_draws(state_all_draws, state_group_col)
            state_all_draws.to_csv(f"{model_dir}/group_state_all_draws.csv", index=False)
            state_preds.to_csv(f"{model_dir}/group_state_predictions.csv", index=False)
            del state_all_draws, state_preds 
        else:
            print("Warning: no state column found; skipping state-level aggregation.")

        # Demographic group aggregations and save (expected value draws)
        demo_group_map = [
            ('sex_broad', 'sex'),
            ('age_broad', 'age'),
            ('eth_broad', 'eth'),
            ('income_broad', 'income'),
            ('vote_broad', 'vote'),
            ('education_broad', 'education'),
        ]
        for gcol, gname in demo_group_map:
            if gcol in draws_for_agg.columns:
                grp_draws = aggregate_draws_by_group(draws_for_agg, gcol)
                grp_preds = summarize_group_draws(grp_draws, gcol)
                grp_draws.to_csv(f"{model_dir}/group_{gname}_all_draws.csv", index=False)
                grp_preds.to_csv(f"{model_dir}/group_{gname}_predictions.csv", index=False)
                del grp_draws, grp_preds 
            else:
                print(f"Note: column '{gcol}' not found; skipping group '{gname}'.")

        # National aggregation (per draw)
        national_draws = compute_national_draws(draws_for_agg, seed=123)
        national_draws["time_window_start"] = window
        national_draws.to_csv(f"{model_dir}/national_all_draws.csv", index=False)

        national_draws_wide = national_draws_to_wide(national_draws, group_col="group")
        national_summary = summarize_group_draws(national_draws_wide, "group")
        national_summary.insert(0, "time_window_start", window)
        national_summary.to_csv(f"{model_dir}/national_predictions.csv", index=False)
        
        # Free draws_for_agg after all draw-based aggregations are done
        del draws_for_agg
        gc.collect()

        # stream category probs directly to disk, no accumulator dict
        print("  Computing category probabilities ...")
        for gcol, gname in group_map:
            if gcol not in pred_for_agg.columns:
                continue
            try:
                grp_cat = compute_group_category_probabilities(pred_for_agg, belief, gcol)
                grp_cat['time_window_start'] = window
                grp_cat.to_csv(f"{model_dir}/group_{gname}_category_probs.csv", index=False)

                ts_path = f"{base_dir}/group_{gname}_category_probs_timeseries.csv"
                write_header = not os.path.exists(ts_path)
                grp_cat.to_csv(ts_path, mode='a', header=write_header, index=False)

                del grp_cat  # FIX 1
                gc.collect()
            except Exception as e:
                print(f"    Warning: failed to compute {gname} category probs: {e}")

        del pred_for_agg
        gc.collect()

        # Mark this window completed only after all outputs are successfully written
        with open(window_done_path, "w") as f:
            f.write("ok\n")

        print(f"  Successfully generated all predictions for window {window}\\n")

    print("All time windows processed!")


    # Cleanup: remove specified txt and csv files
    print(f"Cleaning up files in {global_model_dir}")
    for filename in os.listdir(global_model_dir):
        file_path = os.path.join(global_model_dir, filename)
        try:
            if filename.endswith(".txt"):
                if os.path.exists(file_path):
                    print(f"Removing txt file: {filename}")
                    os.remove(file_path)
            elif filename.startswith("mrp-") and filename.endswith(".csv"):
                if os.path.exists(file_path):
                    print(f"Removing csv file: {filename}")
                    os.remove(file_path)
        except OSError as e:
            print(f"Error removing file {file_path}: {e}")

    # Mark this belief as fully completed after all windows + consolidation finish
    with open(belief_done_path, "w") as f:
        f.write("ok\n")

    del fit
    gc.collect()
