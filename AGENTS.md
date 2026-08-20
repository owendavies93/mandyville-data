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
  - `update-fpl-classic` syncs the configured classic FPL entry's profile,
    history, chips, transfers and past lineups via `lib/Mandyville/FPLClassic.pm`.
  - `fpl-deadline-reminders` is the long-running daemon (systemd unit
    `fpl-deadline-reminders.service`) that sends Telegram reminders before the
    classic, draft and waiver deadlines. It is backed by
    `lib/Mandyville/Reminders.pm` (scheduling) and
    `lib/Mandyville/Notifier/Telegram.pm` (delivery), and stores sent reminders
    in `fpl_reminders` so a moved deadline re-arms its offsets automatically.
  - The API always returns a null `news_return`: the expected return date is
    only given in the free text of `news` ("Expected back 22 Aug", "Suspended
    until 6 Sep"), so it is parsed out there. Consumers treat a missing return
    date as an open-ended absence, so new news wordings must be added to
    `_parse_news_return`. Use `unpackaged/backfill-news-return` to correct
    stored rows in place afterwards.
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
