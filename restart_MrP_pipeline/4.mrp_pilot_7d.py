"""7-day MrP pilot: one belief per process, adapted from MrP_pipeline/21.2.multi_belief_pipelineV2.py.

Usage (from restart_MrP_pipeline/):
    python 4.mrp_pilot_7d.py --belief GRASS --stage fit
    python 4.mrp_pilot_7d.py --belief GRASS --stage predict

"""
# imports
import argparse
import gc
import os
import pickle
import re
import shutil
import time

import geopandas as gpd
import networkx as nx
import numpy as np
import pandas as pd
from cmdstanpy import CmdStanModel
from libpysal import weights
from scipy.sparse import diags

parser = argparse.ArgumentParser(description="7-day MrP pilot for one belief")
parser.add_argument("--belief", required=True, help="belief id, e.g. GRASS, V241294x, CC24_440a")
parser.add_argument("--stage", choices=["fit", "predict", "all"], default="all")
parser.add_argument("--chains", type=int, default=16)
parser.add_argument("--warmup", type=int, default=1000)
parser.add_argument("--sampling", type=int, default=50)
parser.add_argument("--thin", type=int, default=4)
parser.add_argument("--max-windows", type=int, default=None, help="predict only the first N windows (testing)")
parser.add_argument("--run-name", default="pilot", help="subfolder name, keeps test runs apart")
args = parser.parse_args()

np.random.seed(123)

# input / output paths
HERE = os.path.dirname(os.path.abspath(__file__))
GENERATED_DIR = os.path.normpath(os.path.join(HERE, "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data"))
STRAT_FRAME_CSV = f"{GENERATED_DIR}/feature_extraction/state_LP_cleaned_sf.csv"
MRP_INPUT_PKL = f"{GENERATED_DIR}/feature_extraction/preprocessed_cleaned_all_result_7d.pkl"
SHAPEFILE = f"{GENERATED_DIR}/tl_2025_us_state/tl_2025_us_state.shp"
# raw CmdStan output, several GB per window: keep it out of Dropbox (D:/mrp_7d_work, or /mnt/d/... in WSL)
WORK_ROOT = os.path.normpath(os.path.join(HERE, "../../mrp_7d_work"))

belief = f"Belief_{args.belief}_Symbol"
base_dir = f"{GENERATED_DIR}/mrp_7d/{args.run_name}/{args.belief}"
work_dir = f"{WORK_ROOT}/{args.run_name}/{args.belief}"
global_model_dir = f"{work_dir}/fit"
os.makedirs(base_dir, exist_ok=True)
os.makedirs(global_model_dir, exist_ok=True)

# input files (belief-specific _LP columns are skipped: old slug names, not used here)
strat_frame = pd.read_csv(STRAT_FRAME_CSV, usecols=lambda c: not c.startswith("Belief_"), low_memory=False)
df = pd.read_pickle(MRP_INPUT_PKL)
assert f"{belief}_num" in df.columns, f"{belief}_num not in {MRP_INPUT_PKL}"

predictor_cols = [
    "Demo_sex_idx",
    "Demo_age_idx",
    "Demo_ethnicity_idx",
    "Demo_income_idx",
    "Demo_education_idx",
    "Demo_past_vote_idx",
    "state_cleaned_idx",
    "time_window_start",
]
df = df.dropna(subset=[f"{belief}_num"] + predictor_cols).copy()

# find all time windows
df['time_window_start'] = pd.to_datetime(df['time_window_start'])
time_window_sorted = df['time_window_start'].unique()
time_window_sorted = sorted(time_window_sorted)
time_window_map = {window: idx + 1 for idx, window in enumerate(time_window_sorted)}
df.loc[:, 'time_window_start_idx'] = df['time_window_start'].map(time_window_map)
time_window_mapping = df[['time_window_start', 'time_window_start_idx']].drop_duplicates().sort_values('time_window_start_idx')
print(f"{belief}: N={len(df)}, users={df['id'].nunique()}, windows={len(time_window_mapping)}")

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
shp = gpd.read_file(SHAPEFILE)
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

  int<lower=0, upper=1> compute_pred;    // 0 while sampling, 1 in generate_quantities
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

  vector[compute_pred * N_pred] mu_pred;
  vector[compute_pred * N_pred] expected_y_pred;
  array[compute_pred * N_pred] simplex[K] prob_pred;

  for (i in 1:(compute_pred * N_pred)) {
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

# Compile: one copy per belief so parallel runs don't rebuild the same executable
stan_file = f"{work_dir}/mrp_7d.stan"
# rewrite only on change, so a rerun reuses the compiled executable
if not os.path.exists(stan_file) or open(stan_file).read() != stan_code:
    with open(stan_file, 'w') as f:
        f.write(stan_code)

model = CmdStanModel(stan_file=stan_file)

# prepare data for Stan
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

# respondent codes must fall inside the poststrat frame's levels (checked by hand on 2026-11-06)
for arr, J in [(sex_idx_arr, J_sex), (age_idx_arr, J_age), (eth_idx_arr, J_eth), (income_idx_arr, J_income),
               (vote_idx_arr, J_vote), (education_idx_arr, J_education), (state_idx_arr, N_states)]:
    assert arr.between(1, J).all(), (arr.name, J)

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
    "compute_pred": 0,
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
    belief_col
):
    n_cells = len(strat_frame)

    # Extract draws: shape (total_draws, n_cells); all posterior draws are kept
    expected_y_draws = gq.stan_variable('expected_y_pred')  # (draws, N_pred)
    prob_draws = gq.stan_variable('prob_pred')               # (draws, N_pred, K)

    n_draws = expected_y_draws.shape[0]
    K = prob_draws.shape[2]
    print(f"Using all {n_draws} posterior draws")
    
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
    
    return prediction_summary_df, expected_value_draws_df, prob_category_draws_df, K


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

# random sample weights draws should be same for each posterior draw


def national_draws_to_wide(national_draws, group_col="group"):
    wide = national_draws.set_index("draw")["expected_value"].to_frame().T
    wide.insert(0, group_col, "national")
    return wide
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
broad_cols = ['age_broad', 'eth_broad', 'education_broad', 'income_broad', 'vote_broad', 'sex_broad']
meta_cols = ['N_star.median'] + merge_cols + n_star_draws + broad_cols

# state level fixed effects: 2020 R-D vote margin only
LP_cols = ['pct.2020.votes.R-D_zscore']
LP_state = (
    strat_frame
    .assign(STATE=strat_frame["state_abbreviation"].str.upper())
    .groupby("STATE")[LP_cols]
    .mean()
)
LP_state = LP_state.reindex(state_order)
assert LP_state.notna().all().all()
LP_mat = LP_state.values

# Build one base data dict
stan_data_base = {
    **stan_data_common,
    "K": df[f"{belief}_cat"].cat.categories.size,
    "y": df[f"{belief}_num"].astype(int).tolist(),
    "P": LP_mat.shape[1],
    "LP": LP_mat.tolist(),
}
print(f"K={stan_data_base['K']}, J_time={J_time}, N_pred={N_pred}, LP_cols={LP_cols}")

fit_path = f"{global_model_dir}/fit_full_train.pkl"
summary_path = f"{base_dir}/mrp_summary.csv"
belief_done_path = f"{base_dir}/belief_done.ok"

# ----- Fit on full training data (resume if available) -----
if args.stage in ("fit", "all"):
    if os.path.exists(fit_path):
        print(f"Fit already exists, skipping sampling: {fit_path}")
    else:
        print(f"Fitting full model once: N={len(df)}, J_time={J_time}, "
              f"{args.chains} chains x {args.warmup} warmup / {args.sampling} sampling, thin={args.thin}")
        t0 = time.time()
        fit = model.sample(
            data=stan_data_base,
            chains=args.chains,
            parallel_chains=args.chains,
            iter_warmup=args.warmup,
            iter_sampling=args.sampling,
            adapt_delta=0.995,
            max_treedepth=13,
            thin=args.thin,
            sig_figs=18,
            show_console=True,
            refresh=10,
            output_dir=global_model_dir
        )
        print(f"Sampling took {(time.time() - t0) / 60:.1f} min")

        summary_df = fit.summary()
        summary_df.to_csv(summary_path, index=True)
        # CmdStan's diagnose.exe is blocked by Windows app control here; report its checks from the draws
        mv = fit.method_variables()   # each (draws, chains)
        energy = mv["energy__"]
        ebfmi = (np.diff(energy, axis=0) ** 2).sum(axis=0) / ((energy - energy.mean(axis=0)) ** 2).sum(axis=0)
        with open(f"{base_dir}/diagnose.txt", "w") as f:
            f.write(f"divergent transitions: {int(mv['divergent__'].sum())} of {mv['divergent__'].size}\n")
            f.write(f"draws at max treedepth (13): {int((mv['treedepth__'] >= 13).sum())}\n")
            f.write(f"treedepth per chain (max): {mv['treedepth__'].max(axis=0).astype(int).tolist()}\n")
            f.write(f"stepsize per chain: {np.round(mv['stepsize__'][0], 5).tolist()}\n")
            f.write(f"E-BFMI per chain (< 0.3 is a problem): {np.round(ebfmi, 3).tolist()}\n")
        with open(fit_path, "wb") as f:
            pickle.dump(fit, f)
        print(f"Saved fit to {global_model_dir}, summary to {summary_path}")
        print("Largest R-hat:", summary_df["R_hat"].max().round(3), "| smallest ESS_bulk:", summary_df["ESS_bulk"].min().round(0))
        del fit
        gc.collect()

if args.stage == "fit":
    raise SystemExit(0)

# ----- Generate window-specific predictions from same posterior -----
assert os.path.exists(fit_path), f"No fit yet, run --stage fit first: {fit_path}"
with open(fit_path, "rb") as f:
    fit = pickle.load(f)

windows_to_run = time_window_mapping if args.max_windows is None else time_window_mapping.head(args.max_windows)
for i, row in enumerate(windows_to_run.itertuples(index=False), start=1):
    window = row.time_window_start
    current_time_idx = int(row.time_window_start_idx)

    window_label = pd.Timestamp(window).strftime('%Y-%m-%d')
    model_dir = f"{base_dir}/{belief}_{window_label}_stan_output"
    os.makedirs(model_dir, exist_ok=True)

    # Window-level resume marker
    window_done_path = f"{model_dir}/window_done.ok"

    if os.path.exists(window_done_path):
        print(f"[{i}/{len(windows_to_run)}] Window already done, skipping: {window_label}")
        continue

    pred_time_idx_arr = np.full(N_pred, current_time_idx, dtype=int)

    stan_data_pred = dict(stan_data_base)
    stan_data_pred.update({
        "compute_pred": 1,
        "pred_time_idx": pred_time_idx_arr.tolist()
    })

    print(f"[{i}/{len(windows_to_run)}] Generating predictions for window={window_label} (time_idx={current_time_idx})")
    t0 = time.time()
    gq_dir = f"{work_dir}/gq_{window_label}"
    gq = model.generate_quantities(
        data=stan_data_pred,
        previous_fit=fit,
        gq_output_dir=gq_dir
    )

    prediction_summary_df, expected_value_draws_df, prob_category_draws_df, K = generate_cell_level_predictions_from_gq(
        gq,
        strat_frame,
        belief
    )

    # Free gq and its multi-GB CSVs immediately after extracting draws
    del gq
    gc.collect()
    shutil.rmtree(gq_dir, ignore_errors=True)

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
    print(f"  Window took {(time.time() - t0) / 60:.1f} min")

print("All requested time windows processed!")

# Mark this belief as fully completed only when every window was run
if args.max_windows is None:
    with open(belief_done_path, "w") as f:
        f.write("ok\n")
