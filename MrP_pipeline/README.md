## 1. Raw Data Cleaning

**Input:**
- `feature_extraction/all_results.csv`
  - **Description:** Raw output from LLM feature extraction
  - **Shape:**
    - Rows: `n_user_timewindow`
    - Columns: Demographic columns + Belief columns

**Output:**

### 1.1 `feature_extraction/cleaned_all_result.csv` & `cleaned_all_result.pkl`
  - **Description:** Unify the symbols output format, map states to abbreviation, added `belief_cols_cat`, `belief_cols_num` with Likert order
  - **Shape:**
    - Rows: `n_user_timewindow`
    - Columns: Demographic columns + Belief columns + `belief_cat` + `belief_num`

### 1.2 `feature_extraction/drop_usa_cleaned_all_result.csv` & `preprocessed_cleaned_all_result.pkl`
  - **Description:** Dropped `No_state` and "USA" rows, encoded all predictor columns with added `predictor_cols_idx` columns
  - **Shape:**
    - Rows: `n_user_timewindow`
    - Columns: Demographic columns + Belief columns + `belief_cat` + `belief_num` + `predictor_cols_idx`

### 1.3 `MrP/all_mappings.pkl`
  - **Description:** Recorded how each predictor column is mapped to index

---

## 2. Stratification Frame Cleaning

**Input:**
- `original_data/SF_extended.rds`
  - **Description:** Stratification frame for US population
  - **Shape:**
    - Rows: `cells_combination_demo_feature`
    - Columns: Demographic features + Population size samples + State-level fixed effects

**Output:**
- `feature_extraction/cleaned_sf.csv`
  - **Description:** Encoded demographic features, added `_idx` columns, aggregated the stratification frame to collapse all other columns that weren't used in the prediction (education for example -- update: education will be used for prediction)
  - **Shape:**
    - Rows: `cells_combination_demo_feature`
    - Columns: Demographic features + Population size samples + State-level fixed effects + `demo_idx`

---

## 3. Stan Model Fitting

**Input:**
- `feature_extraction/preprocessed_cleaned_all_result.pkl`

**Output:**
- `MrP/{belief_col}_stan_output/mrp_results/`
- `MrP/{belief_col}_stan_output/mrp_summary.csv/`
- `MrP/{belief_col}_stan_output/mrp_draws.csv/`
- `MrP/{belief_col}_stan_output/fit.pkl/`

---

## 4. MRP Prediction

**Input:**
- `feature_extraction/cleaned_sf.csv`
- `MrP/{belief_col}_stan_output/fit.pkl`

**Output:**

### 4.1 Cell Level

**`MrP/{belief_col}_stan_output/cell_level_predictions.csv`**
  - **Shape:** `(n_cells, demographic columns + prediction summary columns)`

**`MrP/{belief_col}_stan_output/cell_level_all_draws.csv`**
  - **Shape:** `(n_cells, n_draws + demographic columns)`


### 4.2 State Level

**`MrP/{belief_col}_stan_output/state_level_predictions.csv`**
  - **Shape:** `(n_states, summary columns)`

**`MrP/{belief_col}_stan_output/state_level_all_draws.csv`**
  - **Shape:** `(n_states * n_weight_samples, n_draws) -- state one under another`

### 4.3 National Level

**`MrP/{belief_col}_stan_output/national_level_predictions.csv`**
  - **Shape:** `one row with summary columns`

**`MrP/{belief_col}_stan_output/national_level_all_draws.csv`**
  - **Shape:** `(n_weight_samples, n_draws)`