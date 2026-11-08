"""Seven-day MrP pilot with the validated optimized Stan model.

Place this file in the original script's directory; input paths are relative
to this file, not the shell's working directory. Run, for example:
    python 4.mrp_pilot_7d.py --belief GRASS
    python 4.mrp_pilot_7d.py --belief GRASS --stage predict

This script embeds one Stan model: the vectorized ordered-logistic likelihood
with exact RW1 and soft-centered ICAR whitening. It retains the earlier fixes:
  - Shared population weights across categories, with draw-level aggregation.
  - Aligned posterior/population draws across every time window and group.
  - Verified fit/data provenance, atomic output writes, and safe resumption.

The default run folder is pilot_optimized. Use a fresh --run-name when changing
the model, training inputs, or sampler settings. Legacy unverified fit caches
are rejected. Keep each saved fit and its chain files in place.

Sampling keeps every iteration (thin=1) so divergence, treedepth and E-BFMI
diagnostics see consecutive transitions. Before generated quantities, each
chain's CSV is copied with only every --predict-every-th draw (default 4), so
prediction cost and output size match the old thin=4 setup. State indices in the
poststrat frame and the survey are checked against the shapefile order. The model was validated with CmdStan
2.40.0; the full script uses the original project's Python dependencies and
input files. No separate Stan file or comparison bundle is needed.

Prediction outputs are in <base_dir>/<prediction-subdir> (corrected_predictions
by default). draw_plan.csv records the shared posterior/population pairing.
Pairing assumes independently fitted outcome/population posteriors and one
static population frame. Use a fresh --prediction-subdir when only prediction
settings or population inputs change.
"""

import argparse
from contextlib import contextmanager
from datetime import date, datetime, timezone
import gc
import hashlib
import json
import os
from pathlib import Path
import pickle
import re
import shutil
import tempfile
import time
import uuid

import numpy as np
import pandas as pd


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="7-day MrP pilot for one belief")
    parser.add_argument("--belief", required=True, help="belief id, e.g. GRASS, V241294x, CC24_440a")
    parser.add_argument("--stage", choices=["fit", "predict", "all"], default="all")
    parser.add_argument("--chains", type=int, default=16)
    parser.add_argument("--warmup", type=int, default=1000)
    parser.add_argument("--sampling", type=int, default=50)
    parser.add_argument("--thin", type=int, default=1,
                        help="keep 1 for valid diagnostics; subsample for prediction with --predict-every")
    parser.add_argument("--adapt-delta", type=float, default=0.8,
                        help="NUTS target acceptance (Stan default 0.8; the first pilot used 0.995)")
    parser.add_argument("--max-treedepth", type=int, default=10,
                        help="NUTS maximum tree depth (Stan default 10; the first pilot used 13)")
    parser.add_argument("--predict-every", type=int, default=4,
                        help="use every k-th saved draw per chain for generated quantities")
    parser.add_argument("--max-windows", type=int, default=None, help="predict only the first N windows (testing)")
    parser.add_argument("--run-name", default="pilot_optimized", help="subfolder name, keeps independent fits apart")
    parser.add_argument("--prediction-subdir", default="corrected_predictions",
                        help="fresh prediction folder when only prediction settings/inputs change")
    parser.add_argument("--draw-seed", type=int, default=123, help="seed for the shared prediction draw plan")
    parser.add_argument("--export-stan-data", type=Path, default=None,
                        help="write the assembled Stan input JSON and exit before fitting")
    args = parser.parse_args(argv)
    if not 0.1 <= args.adapt_delta < 1:
        parser.error("--adapt-delta must be in [0.1, 1)")
    for name in ("chains", "sampling", "thin", "predict_every", "max_treedepth"):
        if getattr(args, name) < 1:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    if args.warmup < 0 or (args.max_windows is not None and args.max_windows < 0):
        parser.error("--warmup and --max-windows must be nonnegative")
    if args.draw_seed < 0:
        parser.error("--draw-seed must be nonnegative")
    subdir = Path(args.prediction_subdir)
    if subdir.is_absolute() or '..' in subdir.parts or not subdir.parts:
        parser.error("--prediction-subdir must name a fresh relative subfolder")
    return args


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
    from scipy.sparse import diags

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
    import networkx as nx

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

stan_code = r"""// Vectorized likelihood with exact RW1 and soft-centered ICAR whitening.
functions {
  // Independent RW1 increments, with the original exact zero-sum constraint.
  vector zero_sum_rw1(vector delta) {
    int J = num_elements(delta) + 1;
    vector[J] eta;
    eta[1] = 0;
    for (j in 2:J)
      eta[j] = eta[j - 1] + delta[j - 1];
    return eta - mean(eta);
  }

  // Orthonormal columns spanning the subspace orthogonal to the constant vector.
  matrix zero_sum_basis(int n) {
    matrix[n, n - 1] H = rep_matrix(0, n, n - 1);
    for (column in 1:(n - 1)) {
      real denominator = sqrt(column * (column + 1.0));
      for (row in 1:column)
        H[row, column] = 1 / denominator;
      H[column + 1, column] = -column / denominator;
    }
    return H;
  }

  // W maps iid standard normals to the ORIGINAL proper soft-centered ICAR.
  // Its component mean SD remains 0.001; singletons retain variance one.
  matrix soft_icar_whitener(int n_states, array[] int group_size,
                           array[] int group_idx,
                           array[] int node1, array[] int node2) {
    int n_components = size(group_size);
    int column_start = 1;
    array[n_components] int observed_size = rep_array(0, n_components);
    matrix[n_states, n_states] Q = rep_matrix(0, n_states, n_states);
    matrix[n_states, n_states] W = rep_matrix(0, n_states, n_states);

    if (size(group_idx) != n_states || size(node1) != size(node2))
      reject("Invalid spatial array dimensions");
    for (state in 1:n_states) {
      if (group_idx[state] < 1 || group_idx[state] > n_components)
        reject("Invalid connected-component index");
      observed_size[group_idx[state]] += 1;
    }
    for (component in 1:n_components) {
      if (group_size[component] < 1
          || observed_size[component] != group_size[component])
        reject("Component membership does not match group_size");
    }
    for (edge in 1:size(node1)) {
      int a = node1[edge];
      int b = node2[edge];
      if (a < 1 || a > n_states || b < 1 || b > n_states)
        reject("Spatial edge index out of bounds");
      if (group_idx[a] != group_idx[b])
        reject("Spatial edge crosses declared connected components");
      Q[a, a] += 1;
      Q[b, b] += 1;
      Q[a, b] -= 1;
      Q[b, a] -= 1;
    }
    for (component in 1:n_components) {
      int n = group_size[component];
      int position = 1;
      array[n] int nodes = rep_array(1, n);
      for (state in 1:n_states) {
        if (group_idx[state] == component) {
          nodes[position] = state;
          position += 1;
        }
      }
      if (n == 1) {
        W[nodes[1], column_start] = 1;
      } else {
        matrix[n, n - 1] H = zero_sum_basis(n);
        matrix[n, n] component_Q = Q[nodes, nodes];
        matrix[n - 1, n - 1] L = cholesky_decompose(H' * component_Q * H);
        matrix[n, n - 1] B = mdivide_left_tri_low(L, H')';
        for (row in 1:n) {
          for (column in 1:(n - 1))
            W[nodes[row], column_start + column - 1] = B[row, column];
          W[nodes[row], column_start + n - 1] = 0.001;
        }
      }
      column_start += n;
    }
    return W;
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

transformed data {
  array[N] int time_sex_flat_idx;
  array[N] int time_age_flat_idx;
  array[N] int time_eth_flat_idx;
  array[N] int time_income_flat_idx;
  array[N] int time_education_flat_idx;
  array[N] int time_vote_flat_idx;
  matrix[N_states, N_states] state_whitener =
      soft_icar_whitener(N_states, group_size, group_idx, node1, node2);
  for (i in 1:N) {
    time_sex_flat_idx[i] = time_idx[i] + (sex_idx[i] - 1) * J_time;
    time_age_flat_idx[i] = time_idx[i] + (age_idx[i] - 1) * J_time;
    time_eth_flat_idx[i] = time_idx[i] + (eth_idx[i] - 1) * J_time;
    time_income_flat_idx[i] = time_idx[i] + (income_idx[i] - 1) * J_time;
    time_education_flat_idx[i] = time_idx[i] + (education_idx[i] - 1) * J_time;
    time_vote_flat_idx[i] = time_idx[i] + (vote_idx[i] - 1) * J_time;
  }
}

parameters {
  ordered[K-1] kappa;

  sum_to_zero_vector[J_sex] eta_sex; 
  vector[J_age - 1] delta_age;
  sum_to_zero_vector[J_eth] eta_eth;
  vector[J_income - 1] delta_income;
  sum_to_zero_vector[J_education] eta_education;     
  sum_to_zero_vector[J_vote] eta_vote;
  vector[J_time - 1] delta_time;

  // Two-way interactions with time
  sum_to_zero_matrix[J_time, J_sex] eta_time_sex;
  sum_to_zero_matrix[J_time, J_age] eta_time_age;
  sum_to_zero_matrix[J_time, J_eth] eta_time_eth;
  sum_to_zero_matrix[J_time, J_income] eta_time_income;
  sum_to_zero_matrix[J_time, J_education] eta_time_education;
  sum_to_zero_matrix[J_time, J_vote] eta_time_vote;

  vector[N_states] z_state;
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
  vector[J_age] eta_age = zero_sum_rw1(delta_age);
  vector[J_income] eta_income = zero_sum_rw1(delta_income);
  vector[J_time] eta_time = zero_sum_rw1(delta_time);
  vector[N_states] eta_state_raw = state_whitener * z_state;
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

  // Exact Gaussian prior reparameterizations. The omitted Jacobians and
  // normalizing constants depend only on data, never on model parameters.
  delta_age ~ std_normal();
  delta_income ~ std_normal();
  delta_time ~ std_normal();
  z_state ~ std_normal();

  // Same likelihood, with vectorized indexing and a single probability call.
  {
    vector[J_time * J_sex] time_sex_flat = to_vector(eta_time_sex_star);
    vector[J_time * J_age] time_age_flat = to_vector(eta_time_age_star);
    vector[J_time * J_eth] time_eth_flat = to_vector(eta_time_eth_star);
    vector[J_time * J_income] time_income_flat = to_vector(eta_time_income_star);
    vector[J_time * J_education] time_education_flat = to_vector(eta_time_education_star);
    vector[J_time * J_vote] time_vote_flat = to_vector(eta_time_vote_star);
    vector[N] mu = eta_sex_star[sex_idx]
                   + eta_age_star[age_idx]
                   + eta_eth_star[eth_idx]
                   + eta_income_star[income_idx]
                   + eta_vote_star[vote_idx]
                   + eta_education_star[education_idx]
                   + eta_time_star[time_idx]
                   + time_sex_flat[time_sex_flat_idx]
                   + time_age_flat[time_age_flat_idx]
                   + time_eth_flat[time_eth_flat_idx]
                   + time_income_flat[time_income_flat_idx]
                   + time_education_flat[time_education_flat_idx]
                   + time_vote_flat[time_vote_flat_idx]
                   + eta_state[state_idx]
                   + mu_state_LP[state_idx];
    y ~ ordered_logistic(mu, kappa);
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
"""


def _json_default(value):
    """Convert the NumPy/pandas values used in model input and metadata."""
    if isinstance(value, np.datetime64):
        value = pd.Timestamp(value)
    if isinstance(value, (pd.Timestamp, datetime, date)):
        if pd.isna(value):
            raise ValueError("Missing timestamps cannot be fingerprinted.")
        return value.isoformat()
    if value is pd.NaT or value is pd.NA:
        raise ValueError("Missing scalar values cannot be fingerprinted.")
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, Path):
        return str(value)
    raise TypeError(f"Unsupported metadata value: {type(value).__name__}")

def stable_json_hash(value):
    """Hash deterministic, finite JSON without building a second large string."""
    encoder = json.JSONEncoder(
        sort_keys=True, separators=(",", ":"), allow_nan=False,
        default=_json_default,
    )
    digest = hashlib.sha256()
    for chunk in encoder.iterencode(value):
        digest.update(chunk.encode("utf-8"))
    return digest.hexdigest()

def build_fit_signature(stan_code, stan_data_base, semantic_mappings):
    """Identify the exact model, training inputs and meanings of index codes.

    Prediction rows are excluded because they do not determine the posterior.
    The full Stan source is included conservatively: comments or a change only
    to generated quantities also change this signature.
    """
    training_data = {
        key: value for key, value in stan_data_base.items()
        if key not in {"compute_pred", "N_pred"} and not key.startswith("pred_")
    }
    return stable_json_hash({
        "stan_code": stan_code,
        "training_data": training_data,
        "semantic_mappings": semantic_mappings,
    })

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def _retry_on_lock(action, *args, attempts=10):
    """Dropbox / antivirus briefly open new files; Windows then refuses rename/delete (WinError 32)."""
    for attempt in range(attempts):
        try:
            return action(*args)
        except PermissionError:
            if attempt == attempts - 1:
                raise
            time.sleep(min(0.5 * 2 ** attempt, 5))

@contextmanager
def _atomic_output(path, binary=False):
    """Write beside the destination, replacing it only after a complete write."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        options = {} if binary else {"encoding": "utf-8", "newline": ""}
        with os.fdopen(fd, "wb" if binary else "w", **options) as stream:
            yield stream
            stream.flush()
            os.fsync(stream.fileno())
        _retry_on_lock(os.replace, temporary_path, path)
    finally:
        if os.path.exists(temporary_path):
            try:
                _retry_on_lock(os.unlink, temporary_path)
            except PermissionError:
                pass   # don't mask the real error if cleanup still fails

def atomic_write_json(path, data):
    with _atomic_output(path) as stream:
        json.dump(data, stream, sort_keys=True, indent=2,
                  allow_nan=False, default=_json_default)
        stream.write("\n")

def atomic_write_pickle(path, value):
    with _atomic_output(path, binary=True) as stream:
        pickle.dump(value, stream, protocol=pickle.HIGHEST_PROTOCOL)

def atomic_write_csv(path, frame, **kwargs):
    kwargs.setdefault("index", False)
    with _atomic_output(path) as stream:
        frame.to_csv(stream, **kwargs)

def convergence_text(summary_df):
    """R-hat / ESS lines for diagnose.txt and the terminal."""
    rhat, ess_bulk, ess_tail = summary_df["R_hat"], summary_df["ESS_bulk"], summary_df["ESS_tail"]
    return (
        f"max R-hat: {rhat.max():.3f} ({rhat.idxmax()})\n"
        f"R-hat > 1.01: {int((rhat > 1.01).sum())} of {len(rhat)} | > 1.05: {int((rhat > 1.05).sum())}\n"
        f"min ESS_bulk: {ess_bulk.min():.0f} ({ess_bulk.idxmin()}) | "
        f"min ESS_tail: {ess_tail.min():.0f} ({ess_tail.idxmin()})\n"
    )

def validate_fit_csv_files(fit):
    """Ensure the sampler CSV files needed by generated quantities still exist."""
    paths = list(fit.runset.csv_files)
    if not paths:
        raise RuntimeError("The fitted model has no sampler CSV files.")
    missing = [str(path) for path in paths if not Path(path).is_file()]
    if missing:
        raise RuntimeError(
            "Sampler CSV files needed for prediction are missing: "
            + ", ".join(missing)
            + ". Restore the original files or use a new --run-name to refit."
        )
    return paths

_THIN_LINE = re.compile(r"^(#\s*thin\s*=\s*)(\d+)(.*)$")

def write_prediction_subset(csv_paths, out_dir, every):
    """Copy each chain CSV keeping draw rows 0, every, 2*every, ... (subset before GQ).

    The header's thin is rewritten to `every`, so each copy is exactly what CmdStan
    would have written with thin=every and passes cmdstanpy's CSV validation.
    Returns (subset paths, kept 1-based sampling iterations per chain).
    """
    csv_paths = [str(path) for path in csv_paths]
    if every == 1:
        return csv_paths, None
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    subset_paths, kept_iterations = [], None
    for path in csv_paths:
        with open(path, "r", encoding="utf-8") as stream:
            lines = stream.read().splitlines(keepends=True)
        output, header_seen, draw_number, kept, thin_seen = [], False, 0, [], False
        for line in lines:
            if line.startswith("#"):
                match = _THIN_LINE.match(line.rstrip("\r\n"))
                if match and not thin_seen:
                    if int(match.group(2)) != 1:
                        raise ValueError(f"{path}: --predict-every needs a fit sampled with thin=1.")
                    line = f"{match.group(1)}{every}\n"
                    thin_seen = True
                output.append(line)
            elif not header_seen:
                header_seen = True
                output.append(line)
            elif line.strip():
                if draw_number % every == 0:
                    output.append(line)
                    kept.append(draw_number + 1)
                draw_number += 1
        if not thin_seen or not header_seen:
            raise ValueError(f"{path}: could not find the CSV header or thin setting.")
        if kept_iterations is None:
            kept_iterations = kept
        elif kept != kept_iterations:
            raise ValueError("Chains have different numbers of saved draws.")
        target = out_dir / Path(path).name
        with _atomic_output(target) as stream:
            stream.writelines(output)
        subset_paths.append(str(target))
    return subset_paths, kept_iterations

def save_verified_fit(fit, fit_path, metadata_path, fit_signature,
                      sampling_settings, software_versions=None):
    """Save a fit and its provenance; incomplete saves cannot be reused silently.

    The manifest is written last. It binds the model/data signature to the
    pickle and to the sampler CSVs actually consumed by generated quantities.
    """
    csv_paths = validate_fit_csv_files(fit)
    csv_records = [
        {"path": str(Path(path).resolve()), "sha256": sha256_file(path)}
        for path in csv_paths
    ]
    atomic_write_pickle(fit_path, fit)
    metadata = {
        "schema_version": 1,
        "fit_id": uuid.uuid4().hex,
        "fit_signature": fit_signature,
        "pickle_sha256": sha256_file(fit_path),
        "sampler_csv_files": csv_records,
        "sampling_settings": sampling_settings,
        "software_versions": software_versions or {},
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    atomic_write_json(metadata_path, metadata)
    return metadata

def validate_fit_cache(fit_path, metadata_path, expected_signature,
                       stage, sampling_settings=None):
    """Return verified metadata, or None when there is no saved fit.

    Call this before either the fitting or prediction branch. Sampler options
    are checked for fit/all only; prediction does not request new sampling.
    Keep each run's model, inputs and fitted files immutable on resume.
    """
    if stage not in {"fit", "predict", "all"}:
        raise ValueError(f"Unknown stage: {stage}")
    fit_exists = Path(fit_path).is_file()
    metadata_exists = Path(metadata_path).is_file()
    if not fit_exists and not metadata_exists:
        return None

    remedy = " Use a new --run-name and rerun --stage all."
    if not fit_exists:
        raise RuntimeError("Fit metadata exists but the saved fit is missing." + remedy)
    if not metadata_exists:
        raise RuntimeError(
            "The existing fit has no provenance metadata; it cannot be verified."
            + remedy
        )
    try:
        with open(metadata_path, encoding="utf-8") as stream:
            metadata = json.load(stream)
    except (OSError, ValueError) as error:
        raise RuntimeError("Could not read the fit metadata." + remedy) from error
    if not isinstance(metadata, dict):
        raise RuntimeError("Fit metadata must be a JSON object." + remedy)
    required = {"fit_id", "fit_signature", "pickle_sha256", "sampler_csv_files",
                "sampling_settings"}
    if metadata.get("schema_version") != 1 or not required.issubset(metadata):
        raise RuntimeError("Fit metadata is incomplete or unsupported." + remedy)
    if not isinstance(metadata["fit_id"], str) or not metadata["fit_id"]:
        raise RuntimeError("Fit metadata contains no valid fit identity." + remedy)
    if metadata["fit_signature"] != expected_signature:
        raise RuntimeError("The saved fit does not match the current model or training inputs." + remedy)
    if stage in {"fit", "all"}:
        if sampling_settings is None:
            raise ValueError("Sampling settings are required when validating fit/all.")
        if stable_json_hash(metadata["sampling_settings"]) != stable_json_hash(sampling_settings):
            raise RuntimeError("The saved fit used different sampling settings." + remedy)
    if sha256_file(fit_path) != metadata["pickle_sha256"]:
        raise RuntimeError("The saved fit file differs from its provenance metadata." + remedy)
    csv_records = metadata["sampler_csv_files"]
    if not isinstance(csv_records, list) or not csv_records:
        raise RuntimeError("Fit metadata contains no sampler CSV records." + remedy)
    for record in csv_records:
        if (not isinstance(record, dict) or not isinstance(record.get("path"), str)
                or not isinstance(record.get("sha256"), str)):
            raise RuntimeError("Invalid sampler CSV record in fit metadata." + remedy)
        path = Path(record["path"])
        if not path.is_file():
            raise RuntimeError(f"The fitted sampler CSV is missing: {path}." + remedy)
        if sha256_file(path) != record["sha256"]:
            raise RuntimeError(f"The fitted sampler CSV has changed: {path}." + remedy)
    return metadata

def make_prediction_draw_plan(n_total_draws, weight_cols, seed=123):
    """Keep every posterior row and pair each with one population draw, once.

    The pairing assumes independently fitted belief and population posteriors.
    Reuse the complete plan for every week, group, and outcome category. For a
    jointly fitted population/outcome model, retain its original joint pairing.
    """
    if (isinstance(n_total_draws, (bool, np.bool_))
            or not isinstance(n_total_draws, (int, np.integer)) or n_total_draws < 1):
        raise ValueError("n_total_draws must be a positive integer.")
    weight_cols = list(weight_cols)
    if not weight_cols or len(set(weight_cols)) != len(weight_cols):
        raise ValueError("Population weight columns must be nonempty and unique.")
    if not all(isinstance(col, str) and col for col in weight_cols):
        raise ValueError("Population weight column names must be nonempty strings.")

    rng = np.random.default_rng(seed)
    indices = np.arange(n_total_draws)   # all posterior draws are kept
    return pd.DataFrame({
        "draw_col": [f"draw_{idx + 1}" for idx in indices],
        "posterior_draw_index": indices,
        "weight_col": rng.choice(weight_cols, size=len(indices), replace=True),
    })

def _validate_prediction_draw_plan(draw_plan, n_total_draws=None):
    required = {"draw_col", "posterior_draw_index", "weight_col"}
    if not draw_plan.columns.is_unique or not required.issubset(draw_plan.columns):
        raise ValueError("Draw plan must contain unique draw_col, posterior_draw_index, and weight_col columns.")
    if draw_plan.empty or draw_plan[list(required)].isna().any().any():
        raise ValueError("Draw plan must be nonempty and have no missing entries.")
    indices = draw_plan["posterior_draw_index"].to_numpy()
    if (not np.issubdtype(indices.dtype, np.integer)
            or np.any(indices < 0) or len(np.unique(indices)) != len(indices)):
        raise ValueError("Posterior draw indices must be unique nonnegative integers.")
    if n_total_draws is not None and np.any(indices >= n_total_draws):
        raise ValueError("Posterior draw index is outside the fitted draw count.")
    draw_cols = draw_plan["draw_col"].tolist()
    if draw_cols != [f"draw_{idx + 1}" for idx in indices]:
        raise ValueError("Draw names do not identify their original posterior rows.")
    if not all(isinstance(col, str) and col for col in draw_plan["weight_col"]):
        raise ValueError("Population weight column names must be nonempty strings.")
    return indices, draw_cols

def _prediction_summary_values(values, ddof=0):
    """Summarize rows of draws using the original interval conventions."""
    values = np.asarray(values, dtype=float)
    if values.ndim != 2 or values.shape[1] == 0 or not np.isfinite(values).all():
        raise ValueError("Summary input must be a finite two-dimensional array with draws.")
    percentiles = np.percentile(values, [2.5, 97.5, 5, 95, 10, 90, 16, 84], axis=1)
    sd = (np.std(values, axis=1, ddof=ddof) if values.shape[1] > ddof
          else np.full(values.shape[0], np.nan))
    result = {
        "mean": np.mean(values, axis=1),
        "median": np.median(values, axis=1),
        "sd": sd,
    }
    for index, interval in enumerate((95, 90, 80, 68)):
        result[f"lower_{interval}"] = percentiles[2 * index]
        result[f"upper_{interval}"] = percentiles[2 * index + 1]
    return result

def _check_probability_values(probabilities):
    if not np.isfinite(probabilities).all():
        raise ValueError("Category probability draws contain nonfinite values.")
    if np.any(probabilities < 0) or np.any(probabilities > 1):
        raise ValueError("Category probabilities must lie between zero and one.")
    # Tolerate decimal rounding in existing generated-quantities CSV files.
    if not np.allclose(probabilities.sum(axis=-1), 1.0, rtol=0, atol=1e-5):
        raise ValueError("Cell category probabilities do not sum to one.")

def extract_cell_predictions(gq, strat_frame, belief_col, draw_plan, n_total_draws):
    """Extract the same fitted rows in each window, retaining their original IDs.

    Returns cell summaries, expected-score draws, and an array of selected
    category probabilities with shape (draws, cells, categories).
    """
    indices, draw_cols = _validate_prediction_draw_plan(draw_plan, n_total_draws)
    n_cells = len(strat_frame)
    if n_cells == 0:
        raise ValueError("The poststratification frame has no cells.")

    expected_full = gq.stan_variable("expected_y_pred")
    if expected_full.shape != (n_total_draws, n_cells):
        raise ValueError("Expected-score draw shape differs from the fitted posterior or cell frame.")
    expected_draws = expected_full[indices, :]
    del expected_full

    probabilities_full = gq.stan_variable("prob_pred")
    if (probabilities_full.ndim != 3
            or probabilities_full.shape[:2] != (n_total_draws, n_cells)
            or probabilities_full.shape[2] < 2):
        raise ValueError("Category probability shape differs from the fitted posterior or cell frame.")
    probabilities = probabilities_full[indices, :, :]
    del probabilities_full
    _check_probability_values(probabilities)

    cell_id = np.arange(n_cells, dtype=int)
    values = expected_draws.T
    # Cell-level file keeps only the expected-score summary, as float32 (written as
    # parquet). Per-category cell summaries were ~11*K columns x 190k cells per window;
    # group category probabilities come from group_*_category_* (draw-wise, correct).
    summary_columns = {"cell_id": cell_id.astype(np.int32)}
    for name, stats in _prediction_summary_values(values).items():
        summary_columns[f"{belief_col}_pred_{name}"] = np.asarray(stats, dtype=np.float32)
    summary = pd.DataFrame(summary_columns)
    expected_frame = pd.DataFrame(values, columns=draw_cols)
    expected_frame.insert(0, "cell_id", cell_id)
    print(f"Using {len(indices)} fixed posterior draws out of {n_total_draws} for this window")
    return summary, expected_frame, probabilities

def _prediction_group_codes(frame, group_col):
    if not frame.columns.is_unique or group_col not in frame:
        raise ValueError(f"Missing group column or duplicate columns: {group_col}")
    if frame.empty:
        raise ValueError("Cannot aggregate an empty poststratification frame.")
    codes, groups = pd.factorize(frame[group_col], sort=False)
    if np.any(codes < 0):
        raise ValueError(f"Group column {group_col!r} contains missing labels.")
    return codes, groups

def _prediction_weights(frame, weight_col):
    if weight_col not in frame:
        raise ValueError(f"Population weight column {weight_col!r} is missing.")
    weights = frame[weight_col].to_numpy(dtype=float)
    if not np.isfinite(weights).all() or np.any(weights < 0):
        raise ValueError(f"Population weights in {weight_col!r} must be finite and nonnegative.")
    return weights

def _prediction_group_totals(codes, groups, weights, weight_col):
    totals = np.bincount(codes, weights=weights, minlength=len(groups))
    if not np.isfinite(totals).all() or np.any(totals <= 0):
        raise ValueError(f"Population draw {weight_col!r} has a nonpositive or nonfinite group total.")
    return totals

def _expected_draw_columns(draws_df, weight_by_draw):
    if not draws_df.columns.is_unique:
        raise ValueError("Expected-score input has duplicate column names.")
    draw_cols = [col for col in draws_df if isinstance(col, str) and col.startswith("draw_")]
    if not draw_cols or set(draw_cols) != set(weight_by_draw):
        raise ValueError("Expected-score draw columns do not match the shared population pairing.")
    return list(weight_by_draw)

def aggregate_draws_by_group(draws_df, group_col, weight_by_draw):
    """Aggregate each expected-score draw with its fixed paired population draw."""
    draw_cols = _expected_draw_columns(draws_df, weight_by_draw)
    codes, groups = _prediction_group_codes(draws_df, group_col)
    output = {group_col: groups}
    for draw_col in draw_cols:
        values = draws_df[draw_col].to_numpy(dtype=float)
        if not np.isfinite(values).all():
            raise ValueError(f"Expected-score draw {draw_col!r} contains nonfinite values.")
        weight_col = weight_by_draw[draw_col]
        weights = _prediction_weights(draws_df, weight_col)
        totals = _prediction_group_totals(codes, groups, weights, weight_col)
        output[draw_col] = np.bincount(codes, weights=values * weights, minlength=len(groups)) / totals
    return pd.DataFrame(output)

def summarize_group_draws(group_draws_df, group_col):
    draw_cols = [col for col in group_draws_df if isinstance(col, str) and col.startswith("draw_")]
    values = group_draws_df[draw_cols].to_numpy(dtype=float)
    result = {group_col: group_draws_df[group_col].to_numpy()}
    for name, stats in _prediction_summary_values(values, ddof=1).items():
        result[f"pred_{name}"] = stats
    return pd.DataFrame(result)

def compute_national_draws(draws_df, weight_by_draw):
    """Use the same draw/population pairing as every subgroup and time window."""
    draw_cols = _expected_draw_columns(draws_df, weight_by_draw)
    rows = []
    for draw_col in draw_cols:
        values = draws_df[draw_col].to_numpy(dtype=float)
        if not np.isfinite(values).all():
            raise ValueError(f"Expected-score draw {draw_col!r} contains nonfinite values.")
        weight_col = weight_by_draw[draw_col]
        weights = _prediction_weights(draws_df, weight_col)
        total = weights.sum()
        if not np.isfinite(total) or total <= 0:
            raise ValueError(f"Population draw {weight_col!r} has a nonpositive or nonfinite national total.")
        rows.append({
            "draw": draw_col,
            "expected_value": np.dot(values, weights) / total,
            "weight_col": weight_col,
        })
    return pd.DataFrame(rows)

def national_draws_to_wide(national_draws, group_col="group"):
    if national_draws["draw"].duplicated().any():
        raise ValueError("National draw IDs must be unique.")
    wide = national_draws.set_index("draw")["expected_value"].to_frame().T
    wide.insert(0, group_col, "national")
    return wide

def aggregate_category_probability_draws(prob_draws, strat_frame, group_col, draw_plan):
    """Poststratify raw category draws with a common population draw across K.

    Rows are (group, category), followed by the original posterior draw columns.
    No cell-level posterior means are substituted for posterior draws here.
    """
    _, draw_cols = _validate_prediction_draw_plan(draw_plan)
    prob_draws = np.asarray(prob_draws)
    if (prob_draws.ndim != 3
            or prob_draws.shape[:2] != (len(draw_cols), len(strat_frame))
            or prob_draws.shape[2] < 2):
        raise ValueError("Probability draw shape does not match the shared draw plan and cell frame.")
    codes, groups = _prediction_group_codes(strat_frame, group_col)
    n_categories = prob_draws.shape[2]
    output = {
        group_col: np.repeat(np.asarray(groups), n_categories),
        "category": np.tile(np.arange(1, n_categories + 1), len(groups)),
    }
    for position, (draw_col, weight_col) in enumerate(zip(draw_cols, draw_plan["weight_col"])):
        cell_probabilities = prob_draws[position]
        _check_probability_values(cell_probabilities)
        weights = _prediction_weights(strat_frame, weight_col)
        totals = _prediction_group_totals(codes, groups, weights, weight_col)
        group_probabilities = np.empty((len(groups), n_categories))
        for category in range(n_categories):
            group_probabilities[:, category] = np.bincount(
                codes, weights=weights * cell_probabilities[:, category], minlength=len(groups)
            ) / totals
        output[draw_col] = group_probabilities.reshape(-1)
    return pd.DataFrame(output)

def summarize_category_probability_draws(group_draws, group_col):
    """Summarize probabilities after draw-wise poststratification."""
    draw_cols = [col for col in group_draws if isinstance(col, str) and col.startswith("draw_")]
    result = {
        group_col: group_draws[group_col].to_numpy(),
        "category": group_draws["category"].to_numpy(),
    }
    for name, stats in _prediction_summary_values(group_draws[draw_cols].to_numpy(), ddof=1).items():
        result[f"prob_{name}"] = stats
    return pd.DataFrame(result)

PREDICTION_PIPELINE_VERSION = "mrp-python-fixes-1-2-4-v2-ev-parquet"
GQ_ATTEMPTS = 5   # retries a window whose GQ chains crash at process startup on Windows

def dataframe_signature(frame):
    """Fingerprint the loaded cell frame, including row order, labels and weights."""
    digest = hashlib.sha256()
    digest.update(stable_json_hash({
        "columns": list(frame.columns),
        "dtypes": [str(dtype) for dtype in frame.dtypes],
    }).encode("ascii"))
    for start in range(0, len(frame), 10000):
        row_hashes = pd.util.hash_pandas_object(frame.iloc[start:start + 10000], index=False)
        digest.update(row_hashes.to_numpy(dtype="<u8").tobytes())
    return digest.hexdigest()

def prepare_prediction_cache(prediction_dir, identity, draw_plan):
    """Reject stale/legacy prediction folders before inspecting completion markers."""
    prediction_dir = Path(prediction_dir)
    prediction_dir.mkdir(parents=True, exist_ok=True)
    metadata_path = prediction_dir / "prediction_metadata.json"
    plan_path = prediction_dir / "draw_plan.csv"
    signature = stable_json_hash(identity)
    if metadata_path.exists():
        with open(metadata_path, encoding="utf-8") as stream:
            saved = json.load(stream)
        if not isinstance(saved, dict) or saved.get("prediction_signature") != signature:
            raise RuntimeError(
                "Prediction inputs, fitted posterior, or draw plan changed. "
                "Use a new --prediction-subdir to regenerate predictions. "
                "If the model/training inputs changed, use a new --run-name instead."
            )
        if not plan_path.is_file() or not pd.read_csv(plan_path).equals(draw_plan):
            raise RuntimeError(
                "The saved prediction draw plan is missing or changed. "
                "Use a new --prediction-subdir."
            )
    else:
        if any(prediction_dir.iterdir()):
            raise RuntimeError(
                "The prediction folder contains outputs without matching provenance. "
                "Choose a fresh --prediction-subdir; old completion markers cannot be reused."
            )
        atomic_write_csv(plan_path, draw_plan)
        atomic_write_json(metadata_path, {
            "schema_version": 1,
            "prediction_signature": signature,
            "identity": identity,
        })
    return signature

def window_outputs_complete(window_dir, signature, window_label, required_files):
    """A marker is valid only for this prediction run and complete output set."""
    window_dir = Path(window_dir)
    marker = window_dir / "window_done.ok"
    try:
        with open(marker, encoding="utf-8") as stream:
            record = json.load(stream)
        if (not isinstance(record, dict)
                or record.get("prediction_signature") != signature
                or record.get("window_label") != window_label
                or not isinstance(record.get("files"), dict)
                or set(record["files"]) != set(required_files)):
            return False
        return all(
            (window_dir / filename).is_file()
            and (window_dir / filename).stat().st_size == record["files"][filename]
            and record["files"][filename] > 0
            for filename in required_files
        )
    except (OSError, ValueError, TypeError):
        return False

def record_complete_window(window_dir, signature, window_label, required_files):
    window_dir = Path(window_dir)
    sizes = {filename: (window_dir / filename).stat().st_size for filename in required_files}
    if any(size <= 0 for size in sizes.values()):
        raise RuntimeError("A required prediction output is empty; window not marked complete.")
    atomic_write_json(window_dir / "window_done.ok", {
        "prediction_signature": signature,
        "window_label": window_label,
        "files": sizes,
    })

def run_predictions(model, fit, stan_data_base, strat_frame, belief, base_dir,
                    work_dir, time_window_mapping, fit_metadata, args,
                    meta_cols, n_star_draws, group_map):
    """Predict from one verified fit, with a shared plan and resumable outputs."""
    validate_fit_csv_files(fit)
    loaded_csv_paths = [str(Path(path).resolve()) for path in fit.runset.csv_files]
    verified_csv_paths = [record["path"] for record in fit_metadata["sampler_csv_files"]]
    if loaded_csv_paths != verified_csv_paths:
        raise RuntimeError("Loaded fit CSV order differs from verified metadata. Use a new --run-name.")

    # Subset the saved draws BEFORE generated quantities: GQ runs on every draw it is
    # given, and its output (N_pred x (K+1) values per draw) is what costs disk and RAM.
    subset_paths, kept_iterations = write_prediction_subset(
        loaded_csv_paths, Path(work_dir) / f"predict_subset_every{args.predict_every}",
        args.predict_every,
    )
    draws_per_chain = (fit.num_draws_sampling if kept_iterations is None
                       else len(kept_iterations))
    if kept_iterations is None:
        kept_iterations = list(range(1, draws_per_chain + 1))
    n_total_draws = draws_per_chain * fit.chains
    print(f"Prediction subset: every {args.predict_every} draw(s) -> "
          f"{draws_per_chain} per chain x {fit.chains} chains = {n_total_draws} "
          f"of {fit.num_draws_sampling * fit.chains} saved draws")
    draw_plan = make_prediction_draw_plan(
        n_total_draws, n_star_draws, seed=args.draw_seed
    )
    # GQ draws are chain-major; record which saved iteration each draw_k came from.
    draw_plan["chain"] = draw_plan["posterior_draw_index"] // draws_per_chain + 1
    draw_plan["saved_iteration"] = [kept_iterations[i % draws_per_chain]
                                    for i in draw_plan["posterior_draw_index"]]
    weight_by_draw = dict(zip(draw_plan["draw_col"], draw_plan["weight_col"]))
    prediction_dir = Path(base_dir) / args.prediction_subdir
    identity = {
        "pipeline_version": PREDICTION_PIPELINE_VERSION,
        # Python-only processing edits can reuse the fit, but not old outputs.
        "python_source_sha256": sha256_file(__file__),
        "fit_id": fit_metadata["fit_id"],
        "fit_signature": fit_metadata["fit_signature"],
        "fit_pickle_sha256": fit_metadata["pickle_sha256"],
        "poststrat_frame_signature": dataframe_signature(strat_frame),
        "belief": belief,
        "total_posterior_draws": n_total_draws,
        "predict_every": args.predict_every,
        "prediction_subset_sha256": [sha256_file(path) for path in subset_paths],
        "draw_plan": draw_plan.to_dict(orient="records"),
        "time_windows": time_window_mapping.to_dict(orient="records"),
    }
    prediction_signature = prepare_prediction_cache(prediction_dir, identity, draw_plan)
    belief_done_path = prediction_dir / "belief_done.ok"
    belief_done_path.unlink(missing_ok=True)
    print(f"Prediction outputs: {prediction_dir}")

    # Preserve the original script's state and demographic group definitions.
    state_group_col = "state_simple" if "state_simple" in strat_frame else "state_idx"
    expected_groups = [(state_group_col, "state")]
    expected_groups += [
        (column, name) for column, name in [
            ("sex_broad", "sex"), ("age_broad", "age"),
            ("eth_broad", "eth"), ("income_broad", "income"),
            ("vote_broad", "vote"), ("education_broad", "education"),
        ] if column in strat_frame
    ]
    category_groups = [(column, name) for column, name in group_map if column in strat_frame]
    required_files = [
        "cell_level_predictions.parquet",
        "national_all_draws.csv", "national_predictions.csv",
    ]
    for _, name in expected_groups:
        required_files += [f"group_{name}_all_draws.csv", f"group_{name}_predictions.csv"]
    for _, name in category_groups:
        required_files += [f"group_{name}_category_all_draws.csv", f"group_{name}_category_probs.csv"]
    if len(required_files) != len(set(required_files)):
        raise ValueError("Prediction group names produce duplicate output filenames.")

    merge_meta = strat_frame.reset_index(drop=True).loc[:, meta_cols].copy()
    merge_meta.insert(0, "cell_id", np.arange(len(merge_meta), dtype=int))
    windows_to_run = (time_window_mapping if args.max_windows is None
                      else time_window_mapping.head(args.max_windows))
    for index, row in enumerate(windows_to_run.itertuples(index=False), start=1):
        window = row.time_window_start
        current_time_idx = int(row.time_window_start_idx)
        window_label = pd.Timestamp(window).strftime("%Y-%m-%d")
        window_dir = prediction_dir / f"{belief}_{window_label}_stan_output"
        if window_outputs_complete(window_dir, prediction_signature, window_label, required_files):
            print(f"[{index}/{len(windows_to_run)}] Verified window already complete: {window_label}")
            continue
        window_dir.mkdir(parents=True, exist_ok=True)
        (window_dir / "window_done.ok").unlink(missing_ok=True)

        stan_data_pred = dict(stan_data_base)
        stan_data_pred.update({
            "compute_pred": 1,
            "pred_time_idx": np.full(len(strat_frame), current_time_idx, dtype=int).tolist(),
        })
        print(f"[{index}/{len(windows_to_run)}] Generating predictions for {window_label}")
        started = time.time()
        gq = None
        for attempt in range(1, GQ_ATTEMPTS + 1):
            # Each call owns its scratch CSV directory, including after failed runs.
            gq_dir = Path(work_dir) / f"gq_{window_label}_{uuid.uuid4().hex[:12]}"
            gq_dir.mkdir(parents=True, exist_ok=False)
            try:
                gq = model.generate_quantities(
                    data=stan_data_pred, previous_fit=subset_paths,
                    gq_output_dir=str(gq_dir), sig_figs=18,
                )
                cell_summary, expected_draws, probability_draws = extract_cell_predictions(
                    gq, strat_frame, belief, draw_plan, n_total_draws
                )
                break
            except (RuntimeError, ValueError) as error:
                # On Windows a chain process occasionally dies at startup (0xC0000005,
                # empty console output) while the other chains finish normally.
                if attempt == GQ_ATTEMPTS:
                    raise
                print(f"  GQ attempt {attempt} failed ({type(error).__name__}); retrying window")
            finally:
                gq = None
                gc.collect()
                shutil.rmtree(gq_dir, ignore_errors=True)

        with _atomic_output(window_dir / "cell_level_predictions.parquet", binary=True) as stream:
            cell_summary.to_parquet(stream, engine="pyarrow", compression="zstd", index=False)
        draws_for_agg = expected_draws.merge(merge_meta, on="cell_id", how="left", validate="one_to_one")
        del cell_summary, expected_draws

        for group_col, name in expected_groups:
            group_draws = aggregate_draws_by_group(draws_for_agg, group_col, weight_by_draw)
            group_summary = summarize_group_draws(group_draws, group_col)
            atomic_write_csv(window_dir / f"group_{name}_all_draws.csv", group_draws)
            atomic_write_csv(window_dir / f"group_{name}_predictions.csv", group_summary)
            del group_draws, group_summary

        national_draws = compute_national_draws(draws_for_agg, weight_by_draw)
        national_draws["time_window_start"] = window
        national_summary = summarize_group_draws(national_draws_to_wide(national_draws), "group")
        national_summary.insert(0, "time_window_start", window)
        atomic_write_csv(window_dir / "national_all_draws.csv", national_draws)
        atomic_write_csv(window_dir / "national_predictions.csv", national_summary)
        del draws_for_agg, national_draws, national_summary

        # Aggregate raw category probabilities before taking posterior summaries.
        # Every category uses the same population draw as the expected score.
        for group_col, name in category_groups:
            category_draws = aggregate_category_probability_draws(
                probability_draws, strat_frame, group_col, draw_plan
            )
            category_summary = summarize_category_probability_draws(category_draws, group_col)
            category_draws["time_window_start"] = window
            category_summary["time_window_start"] = window
            atomic_write_csv(window_dir / f"group_{name}_category_all_draws.csv", category_draws)
            atomic_write_csv(window_dir / f"group_{name}_category_probs.csv", category_summary)
            del category_draws, category_summary
        del probability_draws
        gc.collect()
        record_complete_window(window_dir, prediction_signature, window_label, required_files)
        print(f"  Completed {window_label} in {(time.time() - started) / 60:.1f} min")

    # Rebuild time series from verified windows. An interrupted run can be resumed
    # without duplicate appends, even if it stopped after a window marker write.
    completed_dirs = []
    for row in time_window_mapping.itertuples(index=False):
        label = pd.Timestamp(row.time_window_start).strftime("%Y-%m-%d")
        directory = prediction_dir / f"{belief}_{label}_stan_output"
        if window_outputs_complete(directory, prediction_signature, label, required_files):
            completed_dirs.append(directory)
    for _, name in category_groups:
        time_series_path = prediction_dir / f"group_{name}_category_probs_timeseries.csv"
        if completed_dirs:
            series = pd.concat([
                pd.read_csv(directory / f"group_{name}_category_probs.csv")
                for directory in completed_dirs
            ], ignore_index=True)
            atomic_write_csv(time_series_path, series)
        else:
            time_series_path.unlink(missing_ok=True)
    if len(completed_dirs) == len(time_window_mapping):
        atomic_write_json(belief_done_path, {
            "prediction_signature": prediction_signature,
            "completed_windows": len(completed_dirs),
        })
    print(f"Verified complete windows: {len(completed_dirs)}/{len(time_window_mapping)}")

def main(argv=None):
    args = parse_args(argv)
    # Delay runtime-only dependencies so helpers and --help can be inspected alone.
    import geopandas as gpd
    import cmdstanpy
    from cmdstanpy import CmdStanModel
    from libpysal import weights

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

    # Build spatial structure
    shp = gpd.read_file(SHAPEFILE)
    shp["STATE"] = shp["STUSPS"].str.upper()

    shp = shp[~shp["STATE"].isin(["PR", "GU", "VI", "MP", "AS"])]

    shp = shp.sort_values("STATE").reset_index(drop=True)

    state_order = shp["STATE"].tolist()
    N_states = len(state_order)

    # ICAR adjacency and LP are built in state_order; Stan indexes both with state_idx,
    # so strat_frame's state_idx k must be state_order[k-1], and every state must be present.
    frame_states = (
        strat_frame[["state_idx", "state_abbreviation"]]
        .assign(state_idx=lambda d: d["state_idx"].astype(int),
                state_abbreviation=lambda d: d["state_abbreviation"].str.upper())
        .drop_duplicates()
    )
    if frame_states["state_idx"].duplicated().any() or frame_states["state_abbreviation"].duplicated().any():
        raise ValueError("strat_frame state_idx <-> state_abbreviation is not one-to-one:\n"
                         + frame_states.sort_values("state_idx").to_string(index=False))
    expected_states = pd.DataFrame({"state_idx": np.arange(1, N_states + 1),
                                    "state_abbreviation": state_order})
    state_check = frame_states.merge(expected_states, on="state_idx", how="outer",
                                     suffixes=("_frame", "_shapefile"), indicator=True)
    bad_states = state_check[(state_check["_merge"] != "both")
                             | (state_check["state_abbreviation_frame"] != state_check["state_abbreviation_shapefile"])]
    if not bad_states.empty:
        raise ValueError("strat_frame state_idx does not match the shapefile state order:\n"
                         + bad_states.to_string(index=False))

    # Survey side: state_cleaned_idx k must also be state_order[k-1]. Not every state
    # needs respondents, but every respondent state must be a shapefile state.
    survey_states = (
        df[["state_cleaned_idx", "state_cleaned"]]
        .assign(state_cleaned_idx=lambda d: d["state_cleaned_idx"].astype(int),
                state_cleaned=lambda d: d["state_cleaned"].str.upper())
        .drop_duplicates()
    )
    if survey_states["state_cleaned_idx"].duplicated().any() or survey_states["state_cleaned"].duplicated().any():
        raise ValueError("df state_cleaned_idx <-> state_cleaned is not one-to-one:\n"
                         + survey_states.sort_values("state_cleaned_idx").to_string(index=False))
    survey_check = survey_states.merge(expected_states, left_on="state_cleaned_idx", right_on="state_idx",
                                       how="left", indicator=True)
    bad_survey = survey_check[(survey_check["_merge"] != "both")
                              | (survey_check["state_cleaned"] != survey_check["state_abbreviation"])]
    if not bad_survey.empty:
        raise ValueError("df state_cleaned_idx does not match the shapefile state order:\n"
                         + bad_survey.to_string(index=False))
    print(f"State index check passed: poststrat frame {len(frame_states)} states, "
          f"survey {len(survey_states)} states, all aligned to shapefile order")

    print(f"Shapefile states: {N_states}")

    w = weights.Queen.from_dataframe(shp)

    icar_data = prep_icar_data_from_weights(w, N_states)

    print(f"\nICAR structure:")
    print(f"  Connected components: {icar_data['k']}")
    print(f"  Component sizes: {icar_data['group_size']}")
    print(f"  Number of edges: {icar_data['N_edges']}")

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


    metadata_path = f"{global_model_dir}/fit_metadata.json"
    semantic_mappings = {
        "belief": belief,
        "state_order": state_order,
        "time_windows": [pd.Timestamp(value).isoformat() for value in time_window_sorted],
        "outcome_levels": [str(value) for value in df[f"{belief}_cat"].cat.categories],
        "LP_cols": LP_cols,
    }
    # These records detect changed labels; they do not alter or repair the original
    # state or demographic indices supplied to Stan.
    semantic_mappings["poststrat_level_labels"] = {
        index_col: strat_frame[[index_col, label_col]].drop_duplicates()
            .sort_values([index_col, label_col]).to_dict(orient="records")
        for index_col, label_col in [
            ("state_idx", "state_abbreviation"), ("sex_idx", "sex_broad"),
            ("age_idx", "age_broad"), ("eth_idx", "eth_broad"),
            ("income_idx", "income_broad"), ("vote_idx", "vote_broad"),
            ("education_idx", "education_broad"),
        ] if index_col in strat_frame and label_col in strat_frame
    }
    sampling_settings = {
        "chains": args.chains, "parallel_chains": args.chains,
        "iter_warmup": args.warmup, "iter_sampling": args.sampling,
        "thin": args.thin, "adapt_delta": args.adapt_delta, "max_treedepth": args.max_treedepth,
        "sig_figs": 18,
    }
    if args.export_stan_data is not None:
        atomic_write_json(args.export_stan_data, stan_data_base)
        print(f"Exported Stan inputs to {args.export_stan_data}; no model was compiled or sampled.")
        return
    print("Stan model: vectorized likelihood with RW1/ICAR whitening")
    fit_signature = build_fit_signature(stan_code, stan_data_base, semantic_mappings)
    fit_metadata = validate_fit_cache(
        fit_path, metadata_path, fit_signature, args.stage, sampling_settings
    )
    if args.stage == "predict" and fit_metadata is None:
        raise RuntimeError(f"No verified fit yet. Run --stage fit first with --run-name {args.run_name}.")

    # Validate saved provenance before updating or compiling the executable.
    stan_file = Path(work_dir) / "mrp_7d.stan"
    if not stan_file.exists() or stan_file.read_text(encoding="utf-8") != stan_code:
        stan_file.write_text(stan_code, encoding="utf-8")
    model = CmdStanModel(stan_file=str(stan_file))
    fit = None
    if args.stage in ("fit", "all"):
        if fit_metadata is not None:
            print(f"Verified fit matches model, data and sampler settings; reusing {fit_path}")
            diag_path = Path(base_dir) / "diagnose.txt"
            if diag_path.is_file():
                print("Sampler diagnostics (saved):\n" + diag_path.read_text(encoding="utf-8"))
            if Path(summary_path).is_file():
                print(convergence_text(pd.read_csv(summary_path, index_col=0)))
        else:
            # Do not mix a new sampling attempt with an incomplete earlier attempt.
            if any(Path(global_model_dir).iterdir()):
                raise RuntimeError(
                    "The fit directory contains an incomplete/unverified attempt. "
                    "Use a new --run-name to fit cleanly."
                )
            print(f"Fitting full model once: N={len(df)}, J_time={J_time}, "
                  f"{args.chains} chains x {args.warmup} warmup / {args.sampling} sampling, thin={args.thin}, "
                  f"adapt_delta={args.adapt_delta}, max_treedepth={args.max_treedepth}")
            started = time.time()
            fit = model.sample(data=stan_data_base, **sampling_settings,
                               show_console=True, refresh=10, output_dir=global_model_dir)
            sampling_minutes = (time.time() - started) / 60
            print(f"Sampling took {sampling_minutes:.1f} min")
            summary_df = fit.summary()
            atomic_write_csv(summary_path, summary_df, index=True)
            # Diagnostics need thin=1: E-BFMI uses consecutive-transition energy
            # differences, and divergences/treedepth hits on unsaved iterations are invisible.
            if args.thin != 1:
                print(f"WARNING: thin={args.thin}; divergence/treedepth counts and E-BFMI below are unreliable.")
            mv = fit.method_variables()
            energy = mv["energy__"]
            ebfmi = (np.diff(energy, axis=0) ** 2).sum(axis=0) / ((energy - energy.mean(axis=0)) ** 2).sum(axis=0)
            diagnostics = (
                f"settings: {args.chains} chains x {args.warmup} warmup / {args.sampling} sampling, "
                f"adapt_delta={args.adapt_delta}, max_treedepth={args.max_treedepth}\n"
                f"wall time for sampling: {sampling_minutes:.1f} min\n"
                f"divergent transitions: {int(mv['divergent__'].sum())} of {mv['divergent__'].size}\n"
                f"draws at max treedepth ({args.max_treedepth}): "
                f"{int((mv['treedepth__'] >= args.max_treedepth).sum())}\n"
                f"treedepth per chain (max): {mv['treedepth__'].max(axis=0).astype(int).tolist()}\n"
                f"stepsize per chain: {np.round(mv['stepsize__'][0], 5).tolist()}\n"
                f"E-BFMI per chain (< 0.3 is a problem): {np.round(ebfmi, 3).tolist()}\n"
                + convergence_text(summary_df)
            )
            with _atomic_output(f"{base_dir}/diagnose.txt") as stream:
                stream.write(diagnostics)
            print("Sampler diagnostics:\n" + diagnostics)
            fit_metadata = save_verified_fit(
                fit, fit_path, metadata_path, fit_signature, sampling_settings,
                software_versions={"cmdstanpy": cmdstanpy.__version__,
                                   "cmdstan": cmdstanpy.cmdstan_version()},
            )
            print(f"Saved verified fit to {global_model_dir}, summary to {summary_path}")
    if args.stage == "fit":
        return
    if fit is None:
        with open(fit_path, "rb") as stream:
            fit = pickle.load(stream)
    run_predictions(
        model, fit, stan_data_base, strat_frame, belief, base_dir, work_dir,
        time_window_mapping, fit_metadata, args, meta_cols, n_star_draws, group_map,
    )


if __name__ == "__main__":
    main()
