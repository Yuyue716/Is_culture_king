# is_culture_king scripts

Code for estimating weekly (7-day window) public opinion from X/Twitter users' posts:
an LLM extracts each user's beliefs and demographics per window, and MrP
(multilevel regression and poststratification) turns these into population estimates.

Data are not in this repo. Inputs and outputs live in Dropbox under
`Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/`; scripts reach it
through relative paths such as `../../Dropbox/...`, so the repo is expected at
`D:\is_culture_king_scripts` next to `D:\Dropbox`.

## Current pipeline (run in this order)

**1. Upstream data preparation (repo root)**

| Step | File | Output |
|---|---|---|
| Link sampled users with their tweet histories | `0.link_x_user_data.R` | user/tweet tables (`setwd("~/Dropbox/is_culture_king/")`) |
| Check which profile images are still available | `3.detect_unavailable_image.ipynb` | `user_profiles_fixed.csv` |
| Describe profile images with an LLM | `8.5. get_image_description.ipynb` | `user_profiles_with_imgdesc.csv` → `final_user_profiles_cleaned.csv` |

`3` and `8.5` were run in September 2025 and still use the older relative path
`../generated_data/...`; their outputs now sit in the Dropbox `generated_data/`
folder. Update the paths before re-running them.

**2. Feature extraction: `restart_feature_extraction_pipeline/`**

1. `1.group_tweets_into_time_windows.ipynb`: deduplicate tweets, build 7-day windows, attach profile-image descriptions.
2. `2.extract_belief_features.ipynb`: LLM extraction of beliefs and demographics per window (resumable).
3. `3.inspect_extraction_results.ipynb`, `7.preliminary_belief_stats.ipynb`: checks and descriptive statistics.

`prompt_and_schema.md` documents the prompt and output schema.

**3. MrP: `restart_MrP_pipeline/`**

1. `1.feature_extraction_data_cleaning_7d.ipynb`: clean extraction output for MrP (recodes in `belief_recodes_7d.py`).
2. `2.build_target_df_7d.ipynb`: survey targets (GSS / ANES / CCES) for validation.
3. `3.preliminary_cleaning_checks_7d.ipynb`: coverage and cleaning checks.
4. `4.optimized_mrp_pilot_7d.py`: fit the Stan model for one belief and predict every window
   (`4.mrp_pilot_7d.py` is the earlier, unoptimized version).

Example (Windows, CmdStan from conda-forge via micromamba):

```
D:\cmdstan_conda\micromamba.exe run -r D:\cmdstan_conda\root -p D:\cmdstan_conda\env <python.exe> restart_MrP_pipeline\4.optimized_mrp_pilot_7d.py --belief GRASS
```

## Other folders

- `archive/`: the earlier biweekly pipeline (`MrP_pipeline/`, `11.feature_extraction_pipeline/`),
  image-saliency experiments, prompt/model spot checks, time-window selection and other
  exploratory notebooks. Kept for reference; not used by the current pipeline. Their
  relative paths were written for the repo root, so they will not run unchanged from `archive/`.
- `1.infer_x_user_attitudes.R`, `2.estimate_stability_coefficient.R`, `kriging.R`, `quantiles.R`:
  earlier R scripts, kept for reference.
- `pyproject.toml`, `uv.lock`: Python environment (managed with uv).
