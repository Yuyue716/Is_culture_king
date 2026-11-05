"""
Belief recodes shared by the 7-day-window cleaning notebooks.

Used by:
  - 1.feature_extraction_data_cleaning_7d.ipynb  (our LLM extraction)
  - 18.build_target_df_7d.ipynb                  (ANES / GSS / CCES targets)

Both sides must apply exactly the same recode, otherwise the MrP estimates
and the survey targets end up on different scales. That's why the rules live
here and not inside either notebook.

Keys are belief ids from updated_belief_features.json -- the source survey's
variable code. The inner dicts map an option's 1-based position in that file's
`options` list to its recoded value. The option lists follow the codebook
order, so for the target side these are the same numbers as the survey's own
valid codes (after its negative / missing codes are dropped). Positions not
listed are kept as they are.
"""

RECODES = {
    # GSS DIVLAW: 1 Easier, 2 More difficult, 3 Stay as is.
    # Swap 2 <-> 3 so the scale is monotonic: easier < stay as is < more difficult.
    "DIVLAW": {2: 3, 3: 2},
    # GSS COURTS: 1 Too harshly, 2 Not harshly enough, 3 About right.
    # Swap 2 <-> 3 so the scale is monotonic: too harshly < about right < not harshly enough.
    "COURTS": {2: 3, 3: 2},
    # ANES V241409x: 1-7 from "side a lot with Israelis" to "side a lot with
    # Palestinians", plus 8 "Side with neither", which is off the scale.
    # Merge 8 into the midpoint 4 ("Side with both equally"). Code 8 is ~35%
    # of valid ANES answers, so treating it as missing would drop a third of the target.
    "V241409x": {8: 4},
}


def recode_value(belief_id, value):
    """Recode one option position (int) for this belief; None/NaN passes through."""
    if value is None or value != value:  # NaN check without importing numpy/pandas
        return value
    return RECODES.get(belief_id, {}).get(int(value), int(value))


def n_categories(belief_id, n_options):
    """Number of distinct values (K) left after recoding a belief with n_options options."""
    return len({recode_value(belief_id, i) for i in range(1, n_options + 1)})
