
# Prompt and structured-output schema (7-day-window extraction)

This is exactly what `2.extract_belief_features.ipynb` sent to `gpt-oss-120b` in the 7-day-window run (completed 2026-10-23). Each non-empty user-window gets two calls with the same prompt template and different question lists: one with the 40 belief questions and one with the 10 demographic questions. Empty windows are not sent to the model.

## Prompt template

```text
A social media account has the following username, name, description:
- Name: {name}
- Username: {username}
- Description: {description}
A structured description of their profile image is the following:
- Profile Image Description: {profile_image_description}
Furthermore, they self-report their location in their bio as: {location}
The amount of followers they have is: {followers}
They have written the following tweet(s): {tweets}

Below is a list of survey questions; each question is followed by a set of options, each labeled with a symbol that starts with that question's own id (e.g. "IMMCRIME1_1", "IMMCRIME1_2", etc.) -- some questions below have very similar wording to each other, so always double-check that the id prefix on the symbol/option you're using matches the question you're currently answering.
Please select, for each question, the most likely option for this user.

For each selected option/symbol, rate the speculation level (0-100), using the following scale: 
- 0-20: Explicit, direct evidence (e.g., stated in profile/tweets)
- 21-40: Strong indirect indicators
- 41-60: Partial hints or mixed evidence
- 61-80: Weak, limited indicators
- 81-100: No meaningful evidence

Your answer should pertain only to the information available in the user data -- namely the username, name, description, location, amount of followers, profile picture and tweets from this user -- and should not be affected by additional information available to you from any other source.

The survey questions are:
- Does the user think the number of immigrants to America nowadays should be…: Choose one of [LETIN1A_1) Increased a lot, LETIN1A_2) Increased a little, LETIN1A_3) Remain the same as it is, LETIN1A_4) Reduced a little, LETIN1A_5) Reduced a lot]
- There are different opinions about immigrants from other countries living in America. By “immigrants” we mean people who come to settle in America. How much would the user agree or disagree with the following statements: Immigrants increase crime rates.: Choose one of [IMMCRIME1_1) Agree strongly, IMMCRIME1_2) Agree, IMMCRIME1_3) Neither agree nor disagree, IMMCRIME1_4) Disagree, IMMCRIME1_5) Disagree strongly]
- ...
```

**Notes:**

- **Placeholders:**
  - The `{placeholder}` fields are filled in for each user-window at runtime.
  - `{tweets}` is that window's `tweets_struct`: a list that starts with a "N weeks to election" label, followed by the tweet texts and timestamps.
  - `{profile_image_description}` is filled from the `profile_image_main_info` column.
- **Question list:** the list at the end is shown with 2 of the 40 belief questions for illustration. Each line is `- {feature_name}: Choose one of [{id}_1) option 1, {id}_2) option 2, ...]`.
- **Question order:** the order of the questions is shuffled at random on every call. The same shuffled order is used for the prompt text and for the property order of the response schema, so the model never has to match two differently ordered lists.
- **No system message:** there is a single user message. Under gpt-oss's harmony format, the system slot is for model-level settings, and this backend does not accept a developer role.

## Request parameters

| Parameter | Value |
|---|---|
| `model` | `gpt-oss-120b` (Azure AI Foundry deployment) |
| `temperature` | `0` |
| `max_tokens` | `16384`; see the context-length note below |
| `response_format` | `json_schema`, with `strict: true` (schema below) |
| `reasoning_effort` | not set, so the backend default is used. Setting `"high"` made the model loop and use up the token budget. |

## belief_features.json format

The questions live in `generated_data/updated_belief_features.json`, under the keys `beliefs` (40 items) and `demo` (10 items). Each item looks like:

```json
{
  "id": "IMMCRIME1",
  "feature_name": "There are different opinions about immigrants from other countries living in America. By “immigrants” we mean people who come to settle in America. How much would the user agree or disagree with the following statements: Immigrants increase crime rates.",
  "options": [
    "Agree strongly",
    "Agree",
    "Neither agree nor disagree",
    "Disagree",
    "Disagree strongly"
  ]
}
```

- `id` is the single source of truth for which question this is.
  - For belief items it is the variable code from the source survey codebook, such as GSS `LETIN1A`, ANES `V241400x` or CCES `CC24_326d`, so the results can be joined to real survey answers.
  - It is used in three places: as the property key in the response schema, as the prefix of the option symbols (`IMMCRIME1_1`, ...), and as the prefix of the output CSV columns.
  - It must be unique within each of `beliefs` and `demo`.
- `feature_name` is the question text shown in the prompt. The response schema also requires the model to echo it back as `title`, as a cross-check.
- `options` is the ordered list of option texts. An option's symbol is `{id}_{position}`, where position counts from 1. The symbols are generated from that position and are never typed by hand.

## Corresponding structured-output schema

Shown here for the same 2 example questions. In practice the schema has one property per question in the call (40 for belief, 10 for demo), in the same shuffled order as the prompt. The `name` is `belief_assessments` or `demo_assessments`.

```json
{
  "name": "belief_assessments",
  "strict": true,
  "schema": {
    "type": "object",
    "properties": {
      "LETIN1A": {
        "type": "object",
        "properties": {
          "title": {
            "type": "string",
            "enum": ["Does the user think the number of immigrants to America nowadays should be…"]
          },
          "symbol": {
            "type": "string",
            "enum": ["LETIN1A_1", "LETIN1A_2", "LETIN1A_3", "LETIN1A_4", "LETIN1A_5"]
          },
          "category": {
            "type": "string",
            "enum": [
              "Increased a lot",
              "Increased a little",
              "Remain the same as it is",
              "Reduced a little",
              "Reduced a lot"
            ]
          },
          "speculation": {
            "type": "integer",
            "minimum": 0,
            "maximum": 100
          }
        },
        "required": ["title", "symbol", "category", "speculation"],
        "additionalProperties": false
      },
      "IMMCRIME1": {
        "type": "object",
        "properties": {
          "title": {
            "type": "string",
            "enum": ["There are different opinions about immigrants from other countries living in America. By “immigrants” we mean people who come to settle in America. How much would the user agree or disagree with the following statements: Immigrants increase crime rates."]
          },
          "symbol": {
            "type": "string",
            "enum": ["IMMCRIME1_1", "IMMCRIME1_2", "IMMCRIME1_3", "IMMCRIME1_4", "IMMCRIME1_5"]
          },
          "category": {
            "type": "string",
            "enum": [
              "Agree strongly",
              "Agree",
              "Neither agree nor disagree",
              "Disagree",
              "Disagree strongly"
            ]
          },
          "speculation": {
            "type": "integer",
            "minimum": 0,
            "maximum": 100
          }
        },
        "required": ["title", "symbol", "category", "speculation"],
        "additionalProperties": false
      }
    },
    "required": ["LETIN1A", "IMMCRIME1"],
    "additionalProperties": false
  }
}
```

## Validation and retries

The backend does not reliably enforce the single-value `title` enum. In an earlier test the model put one question's answer under another question's key. So each response is checked before it is accepted:

- Every question's key must be present.
- The returned `title` must equal that question's `feature_name`.
- The returned `symbol` must start with that question's `{id}_` prefix.
- No field may be empty.

A response that fails any check counts as a failed attempt and is retried, up to 15 attempts.

The following are retried **without** counting as an attempt, because they say nothing about the model's answer:
- **HTTP 429 (rate limiting):** waits for the `Retry-After` period.
- **Network errors** (connection failures, timeouts, connections broken mid-response): waits 15 s, 30 s, 60 s and so on, up to a 300 s cap.

The full run needed retries on only 29 belief calls and 2 demo calls.

## Context-length handling

The model's context window is 131,072 tokens.

- **The input alone is too long** ("The input (N tokens) is longer than the model's context length"): the call is skipped with no retry.
- **The input fits, but input + `max_tokens` does not** ("... N tokens from the input messages and 16384 tokens for the completion"):
  - The call is retried once, with `max_tokens` = 131,072 − N − 256.
  - That only happens if the room left is at least `200 × (number of questions) + 1000` tokens: 9,000 for belief and 3,000 for demo. That floor is based on the largest outputs seen in the pilot (about 11K tokens for belief, about 2K for demo).
  - With less room the call is skipped, because the answer would be cut off.

Skipped calls are recorded as `context_length_exceeded: <error text>` in `Belief_Skip_Reason` / `Demo_Skip_Reason`. In the full run, 40 belief calls and 36 demo calls out of 19,782 non-empty windows were skipped this way.

## Output columns

Results go to `generated_data/feature_extraction/all_results_7d.csv` (one row per user-window), with one CSV per user in `users_7d/{id}.csv`. On top of the input columns, each row has:

| Column | Meaning |
|---|---|
| `Belief_{id}_Category`, `Demo_{id}_Category` | the chosen option text |
| `Belief_{id}_Symbol`, `Demo_{id}_Symbol` | the option's 1-based position, with the `{id}_` prefix removed (e.g. `IMMCRIME1_2` → `2`) |
| `Belief_{id}_Speculation`, `Demo_{id}_Speculation` | the 0–100 speculation score |
| `Belief_Raw`, `Demo_Raw` | the raw JSON reply |
| `Belief_Reasoning`, `Demo_Reasoning` | the model's reasoning trace (Azure's `reasoning_content`), kept for spot checks |
| `Belief_Skip_Reason`, `Demo_Skip_Reason` | empty on success; otherwise `context_length_exceeded: ...` or `exhausted_retries: ...` |
| `Belief_Attempts`, `Demo_Attempts` | number of attempts used (1 = first try succeeded; 429 and network waits not counted) |
| `Belief_Seconds`, `Demo_Seconds` | wall-clock time of the call, including retries and waits |
| `Model` | the model name |

Empty windows are written as rows with all of these output columns empty.

**Symbols for two questions are not monotonic scales.** For V241409x, option 8 "Side with neither" is not part of the 1–7 scale. For COURTS, the option order is "Too harshly / Not harshly enough / About right". Recode both before treating `_Symbol` as an ordinal value.
