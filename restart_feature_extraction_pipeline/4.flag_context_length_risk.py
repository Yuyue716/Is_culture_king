"""
Estimate which rows in all_user_windows_7d.csv are likely to blow past the
gpt-oss-120b context window (131,072 tokens) once rendered into the actual
belief/demo prompts used by 2.extract_belief_features.ipynb, and save those
rows to a separate CSV for triage -- BEFORE running the real pipeline.

Token estimation method
------------------------
The Azure endpoint doesn't expose a tokenizer, so exact token counts aren't
available offline. The char/token ratio was first calibrated in
diag_context_length.py on plain English filler text (5.33 chars/token), but
6.test_completion_token_usage.py then sent 7 REAL rows (mostly tweet text --
emoji, URLs, non-Latin scripts) to the real endpoint and compared the actual
"input (N tokens)" the API reported against the char count predicted by that
5.33 ratio. Real ratio came out to 3.87-3.98 chars/token across all 7 rows
(avg ~3.92) -- plain English calibration text was ~35% too optimistic, i.e.
real tweets tokenize noticeably worse (fewer chars/token) than filler text.

CHARS_PER_TOKEN below uses 3.85 (just under the observed minimum) as a
still-slightly-conservative estimate now that it's calibrated on real
content rather than synthetic filler. Treat this as a good estimate, not an
exact count -- SAFETY_MARGIN still checks against 90% of the real limit
rather than the limit itself, to leave room for content that tokenizes even
worse than this small calibration sample (e.g. heavier non-Latin-script
content than what was sampled).

Does not touch checkpoint_7d.json / all_results_7d.csv / any production
pipeline state -- this only reads all_user_windows_7d.csv and writes a new
standalone CSV.
"""
import json
import pandas as pd

CHARS_PER_TOKEN = 3.85  # calibrated on real tweet content -- see docstring above
CONTEXT_LIMIT_TOKENS = 131072
SAFETY_MARGIN = 0.90  # flag anything estimated above 90% of the real limit
THRESHOLD_TOKENS = CONTEXT_LIMIT_TOKENS * SAFETY_MARGIN  # ~117,965

INPUT_CSV = "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/all_user_windows_7d.csv"
FEATURES_JSON = "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/belief_features.json"
OUTPUT_CSV = "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/feature_extraction/likely_context_length_exceeded_7d.csv"

# ------------------------------------------------------------
# same prompt_template / categories_text logic as 2.extract_belief_features.ipynb
# (kept in sync manually -- if that notebook's prompt_template changes, update here too)
# ------------------------------------------------------------
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

Below is a list of survey questions; each question is followed by a set of options, each labeled with a symbol (e.g. "A1", "A2", etc.).
Please select, for each question, the most likely option for this user.

For each selected option/symbol, rate the speculation level (0-100), using the following scale:
- 0-20: Explicit, direct evidence (e.g., stated in profile/tweets)
- 21-40: Strong indirect indicators
- 41-60: Partial hints or mixed evidence
- 61-80: Weak, limited indicators
- 81-100: No meaningful evidence

Your answer should pertain only to the information available in the user data -- namely the username, name, description, location, amount of followers, profile picture and tweets from this user -- and should not be affected by additional information available to you from any other source.

The survey questions are:
"""


def categories_text_for(features):
    return "\n".join(
        f"- {f['title']}: Choose one of [{', '.join(f'{i + 1}) {text}' for i, text in enumerate(f['options']))}]"
        for f in features
    )


def prompt_char_len(row, categories_text):
    body = prompt_template.format(
        name=row["name"],
        username=row["username"],
        description=row["description"],
        location=row["location"],
        followers=row["public_metrics.followers_count"],
        tweets=row["tweets_struct"],
        profile_image_description=row["profile_image_main_info"],
    ) + categories_text
    return len(body)


def main():
    with open(FEATURES_JSON, "r", encoding="utf-8") as f:
        feature_data = json.load(f)
    demo_features = feature_data["demo"]
    belief_features = feature_data["beliefs"]

    # category-list length only depends on the feature set, not the row
    # (build_belief_prompt shuffles order, which doesn't change total length)
    belief_categories_text = categories_text_for(belief_features)
    demo_categories_text = categories_text_for(demo_features)

    df = pd.read_csv(INPUT_CSV)

    df["Belief_Prompt_Chars"] = df.apply(lambda r: prompt_char_len(r, belief_categories_text), axis=1)
    df["Demo_Prompt_Chars"] = df.apply(lambda r: prompt_char_len(r, demo_categories_text), axis=1)
    df["Belief_Est_Tokens"] = (df["Belief_Prompt_Chars"] / CHARS_PER_TOKEN).round().astype(int)
    df["Demo_Est_Tokens"] = (df["Demo_Prompt_Chars"] / CHARS_PER_TOKEN).round().astype(int)

    df["Likely_Exceeds_Belief"] = df["Belief_Est_Tokens"] > THRESHOLD_TOKENS
    df["Likely_Exceeds_Demo"] = df["Demo_Est_Tokens"] > THRESHOLD_TOKENS

    flagged = df[df["Likely_Exceeds_Belief"] | df["Likely_Exceeds_Demo"]].copy()
    flagged.to_csv(OUTPUT_CSV, index=False, encoding="utf-8-sig")

    print(f"chars/token ratio used: {CHARS_PER_TOKEN} (calibrated on real rows in 6.test_completion_token_usage.py)")
    print(f"context limit: {CONTEXT_LIMIT_TOKENS} tokens, flag threshold: {THRESHOLD_TOKENS:.0f} tokens ({SAFETY_MARGIN:.0%} margin)")
    print(f"Total rows scanned: {len(df)}")
    print(f"Flagged rows: {len(flagged)}")
    print(f"  -- belief prompt over threshold: {int(df['Likely_Exceeds_Belief'].sum())}")
    print(f"  -- demo prompt over threshold:   {int(df['Likely_Exceeds_Demo'].sum())}")
    print(f"Saved to: {OUTPUT_CSV}")


if __name__ == "__main__":
    main()
