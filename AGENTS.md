# AGENTS.md

## Project overview

Perl project for fetching, storing and managing football data for mandyville. Interacts with external APIs and stores data in a database.

## Structure

- `lib/Mandyville/` — Core modules (API clients, database, competitions, fixtures, players, etc.)
- `bin/` — Executable scripts for data updates
  - `update-fpl-draft` and `update-fpl-availability` sync FPL Draft league state
    (ownership, waivers, lineups, availability) via the public draft API. They are
    backed by `lib/Mandyville/API/FPLDraft.pm` (API client) and
    `lib/Mandyville/FPLDraft.pm` (storage), and write change-only ranges into
    the `fpl_draft_*` and `fpl_player_availability` tables.
- `t/` — Tests (run with `prove -lr t`)
- `etc/` — Configuration files
- `cpanfile` — Perl dependencies

## Development

- Install deps: `cpanm --installdeps --notest .`
- Run tests: `prove -lr t`
- Set `PERL5LIB` to your local dependency path if installed locally
- DB config via env vars (`MANDYVILLE_DB_HOST`, `MANDYVILLE_DB_PASS`) or `etc/mandyville/config.yaml`

## Code style

- Follow existing Perl conventions in the codebase
- All modules must pass `perlcritic` (see `t/criticrc` for config)
- All modules must have POD documentation (checked by `t/podcheck.t` and `t/podcoverage.t`)
- Any scripts for testing and backfilling data should live in the unpackaged/ directory. Crons should be in the bin/ directory
