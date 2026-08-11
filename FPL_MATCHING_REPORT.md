# FPL Player Matching Improvements Report

Tested against production DB dump (mandyville_debug) with 577 live FPL API
players. Each fix was tested by running `find_player_by_fpl_info` for all FPL
players and measuring matched/unmatched/multiple counts.

## Baseline

| Matched | Unmatched | Multiple |
|---------|-----------|----------|
| 393     | 183       | 1        |

## Fix 1: Web name → last_name matching

Added a step that matches `web_name` directly against `last_name` in the DB.
When multiple matches are found, disambiguates by checking if the first word
of the FPL first name matches the DB first name.

| Matched | Unmatched | Multiple | Delta |
|---------|-----------|----------|-------|
| 443     | 133       | 1        | +50   |

Examples: `Garnacho` → Alejandro Garnacho, `Caicedo` → Moisés Caicedo,
`Solanke` → Dominic Solanke, `Colwill` → Levi Colwill.

## Fix 2: Initial-prefix stripping

When `web_name` matches `^[A-Z]\.`, strips the prefix and retries as
`last_name`. Disambiguates multiple matches using the initial letter against
first name.

| Matched | Unmatched | Multiple | Delta |
|---------|-----------|----------|-------|
| 451     | 125       | 1        | +8    |

Examples: `B.Fernandes` → Bruno Fernandes, `G.Jesus` → Gabriel Jesus,
`J.Timber` → Jurrien Timber.

## Fix 3: Accent-insensitive matching

Added Unicode NFKD decomposition to strip diacritics before comparing names.
Applied as a fallback step that fetches all PL players and compares with
stripped accents on both sides.

| Matched | Unmatched | Multiple | Delta |
|---------|-----------|----------|-------|
| 460     | 116       | 1        | +9    |

Examples: `Jérémy Doku` → Jeremy Doku, `Caoimhín Kelleher` → Caoimhin
Kelleher, `Roméo Lavia` → Romeo Lavia, `Benjamin Sesko` → Benjamin Šeško.

## Fix 4: Reversed name order

When no match is found, swaps first and last name to handle family-name-first
ordering (common for East Asian names).

| Matched | Unmatched | Multiple | Delta |
|---------|-----------|----------|-------|
| 461     | 115       | 1        | +1    |

Example: `Endo Wataru` → Wataru Endo (Tanaka Ao and Mitoma Kaoru were
already caught by fix 1).

## Fix 5: Dot suffix stripping

Strips trailing dot suffixes like `.Jr`, `.T`, `.Sr` from `web_name` before
matching.

| Matched | Unmatched | Multiple | Delta |
|---------|-----------|----------|-------|
| 462     | 114       | 1        | +1    |

Example: `Kroupi.Jr` → Eli Kroupi.

## Fix 6: Single-name player matching

Added matching for players stored with an empty `first_name` or `last_name`
in the DB, using `web_name` against whichever field is populated.

| Matched | Unmatched | Multiple | Delta |
|---------|-----------|----------|-------|
| 465     | 111       | 1        | +3    |

Examples: `Emersonn` → (empty first_name) Emersonn, `Nico González` → Nico
González.

## Fix 6b: fpl_names entries + schema migration

Added 56 manual `fpl_names` entries for edge cases that can't be solved
programmatically (nicknames, spelling differences, complex name variants).
Also added migration 000034 to allow multiple `fpl_names` per player (the
table previously had a unique constraint on `player_id`).

| Matched | Unmatched | Multiple | Delta |
|---------|-----------|----------|-------|
| 510     | 66        | 1        | +45   |

Examples: `Alisson Becker` → Alisson, `Oli McBurnie` → Oliver McBurnie,
`Cristian Romero` → Christian Romero, `Matthijs de Ligt` → Matthijs de.

## Fix 7: Duplicate cleanup

Wrote `unpackaged/merge-duplicate-players` script to merge known duplicate
player entries. Migrates all FK references (players_fixtures, fpl_season_info,
etc.) from the duplicate to the canonical entry, then deletes the duplicate.

Merged 3 duplicates:
- Harvey Elliot (#1434) ← Harvey Elliott (#18363) — 116 fixture rows migrated
- Kaine Hayden (#2246) ← Kaine Kesler-Hayden (#20121) — 124 rows migrated
- Karlan Ahearne-Grant (#2125) ← Karlan Grant (#20164) — 108 rows migrated

## Fix 8: Duplicate prevention

Added `_find_hyphen_duplicate` check to `get_or_insert`. Before inserting a
new player, checks for existing players with the same first name and country
where one last name is a component of the other's hyphenated surname. If
found, updates the existing record's `football_data_id` rather than creating
a duplicate.

## Fix 9: Hyphenated surname splitting

When matching fails, splits hyphenated `second_name` values and tries matching
on each component individually. No additional matches in current data (already
covered by earlier fixes), but prevents future mismatches.

## Final results

| Matched | Unmatched | Multiple |
|---------|-----------|----------|
| 510     | 66        | 1        |

Match rate improved from **68%** to **88%**. The remaining 66 unmatched players
are genuinely not in the DB — they're new signings or promoted players without
Premier League fixture data yet. They will be matched automatically once
`update-fixture-data` populates their fixture records.

The 1 multiple match (Ben Davies) is an expected ambiguity requiring fixture
data to disambiguate.
