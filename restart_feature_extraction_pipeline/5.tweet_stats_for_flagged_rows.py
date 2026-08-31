"""
Adds tweet-count / posting-pattern statistics to the flagged rows produced by
4.flag_context_length_risk.py, as new columns on the same CSV -- to help
eyeball whether a flagged account's volume looks bot-like.

Parsing note: tweets_struct is stored as the str() repr of a Python list
containing a leading marker string (e.g. "8 weeks to election") followed by
dicts like {'text': ..., 'created_at': Timestamp('...')}. Timestamp(...) is
not a literal ast.literal_eval can parse directly, so we neutralize it into
a plain string first ("Timestamp('X')" -> "'X'") and then literal_eval the
rest -- this only ever parses str/list/dict/number literals, never executes
arbitrary code, so it's safe against whatever text happens to be in a tweet.

Does not touch checkpoint_7d.json / all_results_7d.csv / production state --
only reads/rewrites likely_context_length_exceeded_7d.csv.
"""
import ast
import re
import pandas as pd

INPUT_CSV = "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data/feature_extraction/likely_context_length_exceeded_7d.csv"
OUTPUT_CSV = INPUT_CSV  # enrich in place -- this file is derived/regenerable, not production state

BURST_GAP_SECONDS = 10  # consecutive tweets closer together than this count as a "burst" (bot-ish signal)

TIMESTAMP_CALL_RE = re.compile(r"Timestamp\('([^']*)'\)")


def parse_tweets_struct(raw):
    if not isinstance(raw, str) or not raw.strip():
        return []
    safe = TIMESTAMP_CALL_RE.sub(r"'\1'", raw)
    try:
        parsed = ast.literal_eval(safe)
    except (ValueError, SyntaxError):
        return None  # unparseable -- flagged separately below
    if not isinstance(parsed, list):
        return None
    return parsed


def tweet_stats(raw):
    parsed = parse_tweets_struct(raw)
    if parsed is None:
        return {"Parse_Error": True}

    tweets = [item for item in parsed if isinstance(item, dict) and "text" in item]
    if not tweets:
        return {
            "Parse_Error": False,
            "Tweet_Count": 0,
        }

    texts = [str(t.get("text", "")) for t in tweets]
    times = pd.Series(pd.to_datetime([t.get("created_at") for t in tweets], errors="coerce"))
    times = times.dropna().sort_values().reset_index(drop=True)

    total_chars = sum(len(t) for t in texts)
    normalized = [" ".join(t.strip().lower().split()) for t in texts]
    unique_ratio = len(set(normalized)) / len(normalized)

    reply_ratio = sum(t.startswith("@") for t in texts) / len(texts)
    url_ratio = sum("https://t.co/" in t for t in texts) / len(texts)

    stats = {
        "Parse_Error": False,
        "Tweet_Count": len(tweets),
        "Total_Tweet_Chars": total_chars,
        "Avg_Tweet_Chars": round(total_chars / len(tweets), 1),
        "Duplicate_Text_Ratio": round(1 - unique_ratio, 4),
        "Reply_Ratio": round(reply_ratio, 4),
        "URL_Ratio": round(url_ratio, 4),
    }

    if len(times) >= 2:
        gaps_seconds = times.diff().dropna().dt.total_seconds()
        span_hours = (times.iloc[-1] - times.iloc[0]).total_seconds() / 3600
        stats.update({
            "Time_Span_Hours": round(span_hours, 2),
            "Avg_Gap_Seconds": round(gaps_seconds.mean(), 1),
            "Median_Gap_Seconds": round(gaps_seconds.median(), 1),
            "Min_Gap_Seconds": round(gaps_seconds.min(), 1),
            "Tweets_Per_Hour": round(len(tweets) / span_hours, 2) if span_hours > 0 else None,
            "Burst_Count_Under_10s": int((gaps_seconds < BURST_GAP_SECONDS).sum()),
        })
    else:
        stats.update({
            "Time_Span_Hours": 0.0,
            "Avg_Gap_Seconds": None,
            "Median_Gap_Seconds": None,
            "Min_Gap_Seconds": None,
            "Tweets_Per_Hour": None,
            "Burst_Count_Under_10s": 0,
        })

    return stats


def main():
    df = pd.read_csv(INPUT_CSV, encoding="utf-8-sig")

    stats_rows = [tweet_stats(raw) for raw in df["tweets_struct"]]
    stats_df = pd.DataFrame(stats_rows)

    df = pd.concat([df.reset_index(drop=True), stats_df.reset_index(drop=True)], axis=1)
    df.to_csv(OUTPUT_CSV, index=False, encoding="utf-8-sig")

    print(f"Rows processed: {len(df)}")
    print(f"Parse errors: {int(df['Parse_Error'].sum())}")
    print(f"Saved enriched table to: {OUTPUT_CSV}")


if __name__ == "__main__":
    main()
