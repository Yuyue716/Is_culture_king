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

## 3. Stan Model Fitting (no seperation between time windows)

**Input:**
- `feature_extraction/preprocessed_cleaned_all_result.pkl`
- `generated_data/tl_2025_us_state/tl_2025_us_state.shp`

**Output:**
- `MrP/{belief_col}_stan_output/mrp_results/`
- `MrP/{belief_col}_stan_output/mrp_summary.csv/`
- `MrP/{belief_col}_stan_output/mrp_draws.csv/`
- `MrP/{belief_col}_stan_output/fit.pkl/`

---

## 4. MRP Prediction (no seperation between time windows)

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



## 8. ordinal_stan_model_multi_time_windows

**Input:**
- `feature_extraction/cleaned_sf.csv`
- `feature_extraction/preprocessed_cleaned_all_result.pkl`
- `generated_data/tl_2025_us_state/tl_2025_us_state.shp`

**Output:**

### For each time window: folder -- model_dir
### base_dir = f"/mnt/e/Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/{belief_col}"
### model_dir = f"{base_dir}/{belief_col}_{window}_stan_output"

    ### fit object
      - original save: 
        -- **{model_dir}/mrp_results/** : CmdStan CSV chain files folder (file size: about 88MB)
        -- **{model_dir}/mrp_summary.csv** : compact summary table from fit.summary() with one row per variable and columns like mean, sd, quantiles, effective sample size, and R-hat. (file size: about 58KB)
        -- **{model_dir}/mrp_draws.csv**: wide draw-level table from fit.draws_pd(), usually all chains combined. It duplicates most of what is already in chain CSVs. (file size: about 83MB)
        -- **{model_dir}/fit.pkl**: pickled CmdStan fit object. Basically the same as cmdstan csv chain file, Convenient to reload quickly in same ecosystem, but less portable and can break across package/version changes. The only file that is used later on (filesize: 33MB)

      - now save: 
        -- **{model_dir}/mrp_summary.csv** : compact summary table from fit.summary() with one row per variable and columns like mean, sd, quantiles, effective sample size, and R-hat. (file size: about 58KB)      
        -- **{model_dir}/fit.pkl**: pickled CmdStan fit object. Basically the same as cmdstan csv chain file, Convenient to reload quickly in same ecosystem, but less portable and can break across package/version changes. The only file that is used later on (filesize: 33MB)
      side note: also update applied the thin = 32, which only saves 250 draws across all chains, can further decrease the fit file size, but might hurt R-hat diagnostic? (i can test it but also the fit file is really not that big, the prediction files are way bigger) 

    ### Predictions (here the file size is based on n_draws = 500)
    ### 8.1 Cell Level
    input: fit.pkl
    **`{model_dir}/cell_level_predictions.csv`**
      - **Shape:** `(row = n_cells, columns = demographic columns + prediction summary columns)`
      - **filesize:** about 663 MB
      - note: the prediction summary columns include 68%, 80%, 90%, 95% confidence interval

    **`{model_dir}/cell_level_all_draws.csv`**
      - **Shape:** `(row = n_cells, columns = n_draws + demographic columns)`
      - **filesize:** about 2.2 GB
      - note: here it saves the expected values, which is computed by weighted average of the category values based on the category probabilities, where the category probabilities is computed by using sigmoid function on the difference between mu and kappa

    **`{model_dir}/cell_level_mu_draws.csv.gz`**
      - **Shape:** `(row = n_cells, columns = n_draws + demographic columns)`
      - **filesize:** about 1.02 GB
      - note: here it saves the raw mu values per draw, which is the linear combination of effects

    **`{model_dir}/kappa_subsampled.csv`**
      - **Shape:** `#(row = n_draws, columns = kappa_1, kappa_2, ..., kappa_n_levels)
      - **filesize:** about 38.1 KB
      - note: here it saves the raw kappa values per draw, which can be used together with mu to derive probability and expected val

     **`{model_dir}/selected_draw_indices.csv`**
      - **Shape:** `#(row = n_selected_draws, columns = draw_index)
      - **filesize:** about 2.38 KB
      - note: here it saves which of the original 8000 draws has been selected and used for predictions


    ### 8.2 State and demographic group Level
    input: cell_level_all_draws.csv
    **`{model_dir}/group_{gname}_all_draws.csv`**
      - **Shape:** `#(row = n_groups, columns = groupname + n_draws)
      - **filesize:** about 50 KB - 500 KB per group

    **`{model_dir}/group_{gname}_predictions.csv`**
      - input: 
      - **Shape:** `#(row = n_states, columns = groupname + prediction summary columns)
      - **filesize:** about 1 KB - 10 KB per group
      - note: the prediction summary columns include 68%, 80%, 90%, 95% confidence interval

    **`{base_dir}/group_{gname}_category_probs_timeseries.csv`**
      - **Shape:** `#(row = n_states*n_windows, columns = state + category predicted probability)
      - **filesize:** about 10 KB - 400 KB per group


## 10. window_visualization
## plots_dir = f"{base_dir}/visualizations"

- function plot_expected_value_trends (just prediction or also compare with gss)
  - input: `{model_dir}/group_{group_name}_predictions.csv`
  - 
  - output: {plots_dir}/expected_value_trends_{group}.png

- function plot_category_stacked_area
  - input: `{base_dir}/group_{group_name}_category_probs_timeseries.csv` 
  - output: {plots_dir}/category_stacked_area_{group}.png"

- function plot_category_timeseries
  - input： `{base_dir}/group_{group_name}_category_probs_timeseries.csv`  
  - output: {plots_dir}/category_probabilities_{group}.png"


**Output:**

cell level: pick a question, calculate all the CI quantiles, calculate each cell mean and standard deviation, resample 250 cells from a beta distribution with the mean and sd, regenerate the draws and recalculate the CI quantiles and see how much you differss

- do not save all stratification frame information, save only the draws and make sure the stratum is ordered
- redo the feature extraction to get 2024 vote prediction
- check if the pie can be used to recover the likert
- replace percentage of republican with percentage of republican minus 
- at the moment in stan, fixed effect is x-beta, the dimension of x is 2 for now, but for some of them is 3 or 4
- for some variable, if it is the likert, include weighted average for probability, if it's binary include one, if it's categorical
- if it is categorical, include the one that is most predictive (or aggregate in some smart way)

TODO:
- add area level predictors
- do beta sample : we did it doesn't work
- add interaction between vote and state area effects (just for the vote choice question)
- for now just store the cell level summary(if it is a lot of work then don't store them), demographic group level all draws