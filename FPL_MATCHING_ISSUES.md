# FPL Matching Issues

Testing `find_player_by_fpl_info` against the production DB with live FPL API
data (577 players). Current results:

- **Matched: 393** (68%)
- **Unmatched: 183** (32%)
- **Multiple matches: 1** (Ben Davies)

Of the 183 unmatched, ~53 have a plausible match already in the DB but the
current heuristics don't find them. The remaining ~116 are likely players not
yet in the DB (new signings, promoted players, etc.) and will be inserted when
`update-fixture-data` runs.

## Issues with suggested fixes (by impact)

### 1. Web name as last_name with unique match (~31 cases)

The FPL `web_name` matches a single player's `last_name` in the DB, but the
current code only tries `web_name` combined with first name lookups. Examples:

- `Garnacho` → `Alejandro Garnacho`
- `Caicedo` → `Moisés Caicedo`
- `Martinelli` → `Gabriel Martinelli`
- `Raya` → `David Raya`
- `Solanke` → `Dominic Solanke` (FPL surname: `Solanke-Mitchell`)
- `Colwill` → `Levi Colwill` (FPL surname: `Samuels Colwill`)

**Fix:** Add a step that matches `web_name` against `last_name` directly. If
exactly one PL player has that `last_name`, use it. This single change would
recover ~31 players.

### 2. Accent/diacritic mismatches (~10 cases)

Both APIs have the same player but with different accent usage:

- `Jérémy Doku` → DB `Jeremy Doku`
- `Caoimhín Kelleher` → DB `Caoimhin Kelleher`
- `Roméo Lavia` → DB `Romeo Lavia`
- `Jurriën Timber` → DB `Jurrien Timber`
- `Micky van de Ven` → DB `Mickey van de Ven`
- `Abdukodir Khusanov` → DB `Abduqodir Khusanov`

**Fix:** Add accent-insensitive comparison using Unicode NFKD decomposition
(strip combining marks) before comparing names. Apply to all matching steps.

### 3. Initial-prefixed web names (~10 cases)

The `web_name` has a single-letter prefix like `B.`, `G.`, `J.`:

- `B.Fernandes` → `Bruno Fernandes`
- `G.Jesus` → `Gabriel Fernando de Jesus`
- `B.Badiashile` → `Benoît Badiashile`
- `J.Araujo` → `Julián Araujo`
- `A.Becker` → `Alisson Becker`
- `J.Timber` → `Jurrien Timber`
- `D.Essugo` → `Dário Luís Essugo`

**Fix:** When `web_name` matches `/^[A-Z]\./`, strip the prefix and use the
remainder as `last_name` for matching. Optionally verify the initial matches
the DB `first_name`.

### 4. Reversed name order (~3 cases)

East Asian names given family-name-first by FPL:

- `Tanaka Ao` → DB `Ao Tanaka`
- `Mitoma Kaoru` → DB `Kaoru Mitoma`
- `Endo Wataru` → DB `Wataru Endo`

**Fix:** When no match is found, try swapping `first_name` and `second_name`.

### 5. Nickname/shortened first name (~5 cases)

FPL uses a nickname or shortened first name:

- `Oli McBurnie` → DB `Oliver McBurnie`
- `Sam Szmodics` → DB `Samuel Szmodics`
- `Abdul Fatawu` → DB `Issahaku Fatawu`
- `Shumaira Mheuka` → DB `Shim Mheuka`

**Fix:** These are hard to solve programmatically. Best handled by adding
`fpl_names` entries. A last_name-only match with a single result could also
catch some of these, overlapping with fix #1.

### 6. Suffix-prefixed web names (~2 cases)

The `web_name` has a suffix like `.Jr` or `.T`:

- `Kroupi.Jr` → DB `Eli Kroupi` (last_name match)
- `Jocelin.T` → DB `Jocelin Ta Bi` (last_name match)

**Fix:** Strip `.Jr`, `.Sr`, and single-letter dot suffixes from `web_name`
before matching.

### 7. Multi-match ambiguity (1 case currently)

- `Ben Davies` matches 2 players. Needs fixture data to disambiguate — already
  handled correctly when fixture data exists.

### 8. Web name with "Bruno G." pattern (~1 case)

- `Bruno Guimarães Rodriguez Moura` (web: `Bruno G.`)

**Fix:** Expand the initial-prefix stripping to also handle trailing initials.
Or add an `fpl_names` entry.

## Duplicate players in the DB

The football-data API sometimes changes a player's ID or name format, causing
`get_or_insert` to create a second row for the same player. Known cases:

| Player | Entry 1 | Entry 2 |
|---|---|---|
| Kaine Kesler-Hayden | `Kaine Hayden` (has fpl_id) | `Kaine Kesler-Hayden` |
| Karlan Ahearne-Grant | `Karlan Ahearne-Grant` (has fpl_id) | `Karlan Grant` |
| Harvey Elliott | `Harvey Elliot` (has fpl_id) | `Harvey Elliott` |
| Ian Carlo Poveda | `Ian Carlo Poveda` (has fpl_id) | `Ian Poveda` |

### Cleanup

Write a one-off script to merge duplicates: migrate `players_fixtures`,
`fpl_season_info`, `fpl_players_gameweeks`, and other FK references from the
duplicate to the canonical entry, then delete the duplicate row.

### Prevention

In `get_or_insert`, before inserting a new player, check for existing players
with the same `first_name` and `country_id` where one `last_name` is a
component of the other's hyphenated surname. If found, update the existing
record's `football_data_id` rather than inserting a new row.

### Double-barrelled surname matching in find_player_by_fpl_info

When matching fails, try splitting hyphenated `second_name` values and matching
on each component individually. E.g. `Dewsbury-Hall` → try `Dewsbury`, `Hall`.
This complements fix #1 (web_name matching) which only works when the web_name
happens to use the shorter form.

## Suggested implementation priority

1. **Web name → last_name unique match** (fix #1) — biggest impact, ~31 cases
2. **Initial-prefix stripping** (fix #3) — ~10 cases, simple regex
3. **Accent-insensitive matching** (fix #2) — ~10 cases, cross-cutting
4. **Name reversal** (fix #4) — 3 cases, simple swap
5. **Suffix stripping** (fix #6) — 2 cases, simple regex
6. **fpl_names entries** (fix #5) — manual, for remaining edge cases

Fixes 1-4 together would recover ~54 of the 67 matchable players, bringing the
match rate from 68% to ~77%. The remaining ~23% are likely genuinely new
players not yet in the DB.

7. **Duplicate cleanup** — one-off script to merge existing duplicates
8. **Duplicate prevention in `get_or_insert`** — hyphenated surname component check
9. **Double-barrelled matching in `find_player_by_fpl_info`** — split and try components
