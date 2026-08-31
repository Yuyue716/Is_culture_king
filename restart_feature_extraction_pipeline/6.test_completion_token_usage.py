"""
Diagnostic: run a handful of REAL belief-extraction API calls against Azure
to measure how many completion tokens gpt-oss-120b actually uses when
answering the full ~29-category belief schema, and check whether responses
ever get truncated (finish_reason == "length") before finishing the JSON.

Row selection is deliberate, not random: picks the rows with the LARGEST
estimated prompt size among those NOT already flagged as exceeding the
context window (see 4.flag_context_length_risk.py) -- these are the rows
most likely to give the model a lot to reason/hedge about across all 29
categories, and therefore the most likely to produce long completions.
Also includes a few median-sized rows as a baseline for comparison.

Costs real API calls (money + time) -- keeps N_STRESS_ROWS/N_BASELINE_ROWS
small by default. Does not touch checkpoint_7d.json / all_results_7d.csv /
any production pipeline state -- writes only to a local diagnostic CSV next
to this script.
"""
import json
import os
import re
import time
import unicodedata

import pandas as pd
import requests

# ------------------------------------------------------------
# config
# ------------------------------------------------------------
N_STRESS_ROWS = 1      # largest-estimated-prompt row (still under the exceeded threshold) -- most "verbose" in-range row
N_BASELINE_ROWS = 0    # already have baseline data from the previous run
MAX_TOKENS = 16384     # matches production infer_beliefs()
MODEL_NAME = "gpt-oss-120b"

ALL_WINDOWS_CSV = "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/all_user_windows_7d.csv"
FEATURES_JSON = "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/belief_features.json"
FLAGGED_CSV = "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/feature_extraction/likely_context_length_exceeded_7d.csv"
OUTPUT_CSV = "token_usage_diagnostic_verbose_row.csv"  # local to this folder, not a production artifact

CHARS_PER_TOKEN = 3.85  # calibrated on real rows -- see 4.flag_context_length_risk.py docstring
CONTEXT_LIMIT_TOKENS = 131072
SAFETY_MARGIN = 0.90
THRESHOLD_TOKENS = CONTEXT_LIMIT_TOKENS * SAFETY_MARGIN

endpoint_base = "https://aipolling.services.ai.azure.com/models"
api_version = "2024-05-01-preview"
url = f"{endpoint_base}/chat/completions?api-version={api_version}"

api_key = os.getenv("AZURE_API_KEY")
if not api_key:
    raise ValueError("AZURE_API_KEY environment variable is not set")

# ------------------------------------------------------------
# same helpers / prompt as 2.extract_belief_features.ipynb
# (kept in sync manually -- update here if the notebook's prompt_template changes)
# ------------------------------------------------------------
def normalize_text(text):
    if not text:
        return text
    text = str(text)
    text = text.replace("*", "").replace("<<", "").replace(">>", "")
    text = re.sub(r"[-‐-―−﹘﹣－]", "", text)
    normalized = unicodedata.normalize("NFKD", text)
    ascii_text = normalized.encode("ASCII", "ignore").decode("ASCII")
    return " ".join(ascii_text.split()).lower()


def make_safe_key(title):
    return re.sub(r"\W+", "_", normalize_text(title)).strip("_")


prompt_template = """
A social media account has the following username, name, description:
- Name: {name}
- Username: {username}
- Description: {description}
A structured description of their profile image is the following:
- Profile Image Description: {profile_image_description}
Furthermore, they self-report their location in their bio as: {location}
The amount of followers they have is: {followers}
They have written the following tweet(s): {tweets}

Below is a list of categories; each title (e.g. "AGE:" or "SEX:") is followed by a set of options, each labeled with a symbol (e.g. "A1", "A2", or "E1").
Please select, for each title, the most likely option to which this user belongs to.

For each selected symbol/category, rate the Speculation level (0-100): how little the user data supports the selection.

Scale:
- 0-20: Explicit, direct evidence (e.g., stated in profile/tweets)
- 21-40: Strong indirect indicators
- 41-60: Partial hints or mixed evidence
- 61-80: Weak, limited indicators
- 81-100: No meaningful evidence

For each category, explain in detail which data features drove your choice and speculation level.

Use the exact title text shown in the schema for the title field.
Do not omit any category and do not add extra commentary.
Your answer should pertain only to the information available in the user data -- namely the username, name, description, location, profile picture and tweets from this user -- and should not be affected by additional information available to you from any other source.

The categories are:
"""


def categories_text_for(features):
    return "\n".join(
        f"- {f['title']}: Choose one of [{', '.join(f'{k}) {v}' for k, v in f['options'].items())}]"
        for f in features
    )


def build_assessment_schema(feature):
    symbol_options = [str(s) for s in feature["options"].keys()]
    category_options = [str(c) for c in feature["options"].values()]
    return {
        "type": "object",
        "properties": {
            "title": {"type": "string", "enum": [feature["title"]]},
            # no `pattern` here -- confirmed via real testing that this backend enforces `pattern`
            # as a FULLMATCH, which either mangles the explanation (narrow pattern) or breaks JSON
            # termination (wildcard pattern). Quality-checked downstream instead.
            "explanation": {"type": "string", "minLength": 1},
            "symbol": {"type": "string", "enum": symbol_options},
            "category": {"type": "string", "enum": category_options},
            "speculation": {"type": "integer", "minimum": 0, "maximum": 100},
        },
        "required": ["title", "explanation", "symbol", "category", "speculation"],
        "additionalProperties": False,
    }


def build_response_schema(features, schema_name):
    properties, required = {}, []
    for feature in features:
        safe_key = make_safe_key(feature["title"])
        properties[safe_key] = build_assessment_schema(feature)
        required.append(safe_key)
    return {
        "name": schema_name,
        "strict": True,
        "schema": {
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": False,
        },
    }


def build_prompt(row, categories_text):
    return prompt_template.format(
        name=row["name"],
        username=row["username"],
        description=row["description"],
        location=row["location"],
        followers=row["public_metrics.followers_count"],
        tweets=row["tweets_struct"],
        profile_image_description=row["profile_image_main_info"],
    ) + categories_text


# ------------------------------------------------------------
# select stress + baseline rows
# ------------------------------------------------------------
def select_test_rows():
    with open(FEATURES_JSON, "r", encoding="utf-8") as f:
        feature_data = json.load(f)
    belief_features = feature_data["beliefs"]
    belief_categories_text = categories_text_for(belief_features)

    df = pd.read_csv(ALL_WINDOWS_CSV)
    df = df[~df["is_empty_window"]].copy()

    flagged_keys = set()
    if os.path.exists(FLAGGED_CSV):
        flagged = pd.read_csv(FLAGGED_CSV, encoding="utf-8-sig")
        flagged_keys = set(zip(flagged["id"], flagged["time_window_start"]))

    df["Belief_Prompt_Chars"] = df.apply(lambda r: len(build_prompt(r, belief_categories_text)), axis=1)
    df["Belief_Est_Tokens"] = (df["Belief_Prompt_Chars"] / CHARS_PER_TOKEN).round().astype(int)
    df["_key"] = list(zip(df["id"], df["time_window_start"]))

    candidates = df[(~df["_key"].isin(flagged_keys)) & (df["Belief_Est_Tokens"] < THRESHOLD_TOKENS)].copy()

    stress_rows = candidates.sort_values("Belief_Est_Tokens", ascending=False).head(N_STRESS_ROWS).copy()
    stress_rows["Row_Type"] = "stress"

    remaining = candidates.drop(stress_rows.index).copy()
    median_val = candidates["Belief_Est_Tokens"].median()
    remaining["_dist_from_median"] = (remaining["Belief_Est_Tokens"] - median_val).abs()
    baseline_rows = remaining.nsmallest(N_BASELINE_ROWS, "_dist_from_median").copy()
    baseline_rows["Row_Type"] = "baseline"

    test_rows = pd.concat([stress_rows, baseline_rows], ignore_index=True)
    return test_rows, belief_features, belief_categories_text


# ------------------------------------------------------------
# run real API calls, log usage
# ------------------------------------------------------------
def run_test():
    test_rows, belief_features, belief_categories_text = select_test_rows()
    belief_schema = build_response_schema(belief_features, "belief_assessments_diag")

    print(f"Selected {len(test_rows)} rows to test "
          f"({(test_rows['Row_Type'] == 'stress').sum()} stress + {(test_rows['Row_Type'] == 'baseline').sum()} baseline)")
    print(test_rows[["Row_Type", "username", "time_window_start", "Belief_Est_Tokens"]].to_string(index=False))
    print()

    results = []
    for _, row in test_rows.iterrows():
        prompt = build_prompt(row, belief_categories_text)
        messages = [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": prompt},
        ]
        body = {
            "model": MODEL_NAME,
            "max_tokens": MAX_TOKENS,
            "temperature": 0,
            "messages": messages,
            "response_format": {"type": "json_schema", "json_schema": belief_schema},
        }
        headers = {"Content-Type": "application/json", "api-key": api_key}

        record = {
            "Row_Type": row["Row_Type"],
            "username": row["username"],
            "time_window_start": row["time_window_start"],
            "Est_Prompt_Tokens": row["Belief_Est_Tokens"],
        }

        start = time.time()
        try:
            response = requests.post(url, headers=headers, data=json.dumps(body), timeout=300)
            record["Elapsed_Seconds"] = round(time.time() - start, 1)
            record["Status_Code"] = response.status_code

            if not response.ok:
                record["Error"] = response.text[:500]
                print(f"  {row['username']}: HTTP {response.status_code} -- {response.text[:200]}")
                results.append(record)
                continue

            payload = response.json()
            usage = payload.get("usage", {})
            choice = payload["choices"][0]
            finish_reason = choice.get("finish_reason")
            content = choice["message"].get("content")

            record.update({
                "Prompt_Tokens_Actual": usage.get("prompt_tokens"),
                "Completion_Tokens_Actual": usage.get("completion_tokens"),
                "Total_Tokens_Actual": usage.get("total_tokens"),
                "Finish_Reason": finish_reason,
                "Truncated": finish_reason == "length",
            })

            if content is None:
                record["Parse_Result"] = "no_content"
            else:
                try:
                    parsed = json.loads(content)
                    record["Parse_Result"] = "ok"
                    record["Categories_Returned"] = len(parsed) if isinstance(parsed, dict) else 0
                    record["Categories_Expected"] = len(belief_features)
                except (ValueError, json.JSONDecodeError):
                    record["Parse_Result"] = "invalid_json"
                    record["Content_Tail"] = content[-200:]

            print(f"  {row['username']} ({row['Row_Type']}): "
                  f"prompt={usage.get('prompt_tokens')} completion={usage.get('completion_tokens')} "
                  f"finish={finish_reason} parse={record.get('Parse_Result')} "
                  f"({record['Elapsed_Seconds']}s)")

        except requests.exceptions.RequestException as e:
            record["Error"] = str(e)
            print(f"  {row['username']}: request failed: {e}")

        results.append(record)
        time.sleep(1)

    results_df = pd.DataFrame(results)
    results_df.to_csv(OUTPUT_CSV, index=False, encoding="utf-8-sig")
    print(f"\nSaved {len(results_df)} rows to {OUTPUT_CSV}")
    return results_df


if __name__ == "__main__":
    run_test()
