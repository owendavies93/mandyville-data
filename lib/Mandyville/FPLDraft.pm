package Mandyville::FPLDraft;

use Mojo::Base -base, -signatures;

use Mandyville::API::FPLDraft;
use Mandyville::Database;
use Mandyville::Utils qw(current_season debug msg);

use Mojo::JSON qw(encode_json);
use Time::Piece;

# Months as they appear in FPL news strings ("Expected back 22 Aug").
my %NEWS_MONTHS = (
    Jan => 1, Feb => 2,  Mar => 3,  Apr => 4,
    May => 5, Jun => 6,  Jul => 7,  Aug => 8,
    Sep => 9, Oct => 10, Nov => 11, Dec => 12,
);

=head1 NAME

  Mandyville::FPLDraft - fetch and store FPL Draft state

=head1 SYNOPSIS

  use Mandyville::FPLDraft;
  my $fpl_draft = Mandyville::FPLDraft->new({
      api     => Mandyville::API::FPLDraft->new,
      dbh     => Mandyville::Database->new->rw_db_handle(),
      leagues => [{ id => 12345, entry => 678 }],
      season  => current_season(),
  });

  my $changes = $fpl_draft->sync;

=head1 DESCRIPTION

  This module fetches the state of the Fantasy Premier League Draft game
  and stores it in the mandyville database. It covers league
  configuration, managers, the draft itself, ownership of every player,
  waiver order, transactions, fixtures, standings and per-gameweek
  lineups, as well as per-player availability (injuries, suspensions,
  draft rank).

  Ownership, waiver order and availability are stored as change-only
  date/time ranges (like C<players_teams>): a row is closed and a new one
  opened only when something actually changes.

=head1 METHODS

=over

=item new ( [ OPTIONS ] )

  Creates a new instance. C<OPTIONS> is a hashref that may contain
  C<api>, C<dbh>, C<leagues>, C<season> and C<dry_run>; any of these
  left unset are defaulted.

=item api

  An instance of Mandyville::API::FPLDraft.

=item dbh

  A read-write handle to the Mandyville database.

=item leagues

  An arrayref of hashrefs, each with an C<id> (the FPL draft league id)
  and an C<entry> (the global entry id of the manager we are tracking in
  that league, used to set the C<is_mine> flag).

=item season

  The season to store data for, in YYYY format (the year the season
  started). Defaults to the current season.

=item dry_run

  If true, do not write to the database; log what would change instead.

=cut

has 'api'     => sub { shift->{api} };
has 'dbh'     => sub { shift->{dbh} };
has 'leagues' => sub { shift->{leagues} // [] };
has 'season'  => sub { shift->{season} };
has 'dry_run' => sub { shift->{dry_run} // 0 };

sub new($class, $options) {
    $options->{api}     //= Mandyville::API::FPLDraft->new;
    $options->{dbh}     //= Mandyville::Database->new->rw_db_handle();
    $options->{leagues} //= [];
    $options->{season}  //= current_season();
    $options->{dry_run} //= 0;

    my $self = {
        api     => $options->{api},
        dbh     => $options->{dbh},
        leagues => $options->{leagues},
        season  => $options->{season},
        dry_run => $options->{dry_run},
    };

    bless $self, $class;
    return $self;
}

=item sync

  Fetch and store the full draft game state for every configured league,
  plus the draft element to player mapping. Returns the number of changes
  written.

=cut

sub sync($self) {
    my $bootstrap = $self->api->bootstrap;

    my $changes = $self->_sync_elements($bootstrap->{elements});
    $self->{event_deadlines} = $self->_event_deadlines($bootstrap->{events});

    $self->_record_sync_run(
        undef, 'update-fpl-draft', 'bootstrap-static', $changes
    );

    foreach my $league (@{$self->leagues}) {
        $changes += $self->_sync_league($league);
    }

    return $changes;
}

=item sync_availability

  Fetch and store player availability (status, injury news, chances of
  playing, draft rank) for every element. Returns the number of changes
  written.

  Draft rank is stored but deliberately excluded from change detection:
  the game recalculates it constantly, and tracking it would close and
  reopen a range for most elements on every run. The stored rank is
  therefore the value as at the last material change, not live.

  The API's own C<news_return> field is, in practice, always null: the
  expected return date is only given in the free text of C<news>. Where
  the API leaves it unset we parse the news instead, so consumers get a
  usable date rather than an open-ended absence.

=cut

sub sync_availability($self) {
    my $elements = $self->api->elements;

    my $changes = 0;
    my $open = $self->_select_all(
        'SELECT id, fpl_draft_element, player_id, status,
                chance_of_playing_this, chance_of_playing_next,
                news, news_added, news_return, draft_rank
         FROM fpl_player_availability
         WHERE season = ? AND end_time IS NULL',
        $self->season
    );
    my %open = map { $_->{fpl_draft_element} => $_ } @$open;

    my %seen;
    foreach my $e (@$elements) {
        my $element = $e->{id};
        my $player_id = $self->_player_id_for_code($e->{code});

        # The API almost never sets news_return itself; fall back to the
        # date embedded in the news text.
        my $news_return = $e->{news_return}
            // $self->_parse_news_return($e->{news}, $self->season);

        my $cur = $open{$element};
        if (!$cur) {
            $self->_apply(
                'INSERT INTO fpl_player_availability
                   (player_id, fpl_draft_element, season, status,
                    chance_of_playing_this, chance_of_playing_next,
                    news, news_added, news_return, draft_rank)
                 VALUES (?,?,?,?,?,?,?,?,?,?)',
                $player_id, $element, $self->season,
                $e->{status}, $e->{chance_of_playing_this_round},
                $e->{chance_of_playing_next_round}, $e->{news},
                $e->{news_added}, $news_return, $e->{draft_rank},
                "insert availability for element $element"
            );
            $changes++;
        } else {
            my $changed = 0;
            $changed ||= $self->_differs($cur->{player_id}, $player_id);
            $changed ||= $self->_differs($cur->{status}, $e->{status});
            $changed ||= $self->_differs($cur->{chance_of_playing_this}, $e->{chance_of_playing_this_round});
            $changed ||= $self->_differs($cur->{chance_of_playing_next}, $e->{chance_of_playing_next_round});
            $changed ||= $self->_differs($cur->{news}, $e->{news});
            $changed ||= $self->_differs($cur->{news_return}, $news_return);
            # draft_rank is intentionally not compared here; see the POD.

            if ($changed) {
                $self->_apply(
                    'UPDATE fpl_player_availability SET end_time = now() WHERE id = ?',
                    $cur->{id}, "close availability for element $element"
                );
                $self->_apply(
                    'INSERT INTO fpl_player_availability
                       (player_id, fpl_draft_element, season, status,
                        chance_of_playing_this, chance_of_playing_next,
                        news, news_added, news_return, draft_rank)
                     VALUES (?,?,?,?,?,?,?,?,?,?)',
                    $player_id, $element, $self->season,
                    $e->{status}, $e->{chance_of_playing_this_round},
                    $e->{chance_of_playing_next_round}, $e->{news},
                    $e->{news_added}, $news_return, $e->{draft_rank},
                    "reopen availability for element $element"
                );
                $changes += 2;
            }
        }

        $seen{$element} = 1;
    }

    # Close rows for elements no longer present in the game.
    foreach my $element (keys %open) {
        next if $seen{$element};
        $self->_apply(
            'UPDATE fpl_player_availability SET end_time = now() WHERE id = ?',
            $open{$element}{id}, "close availability for element $element (removed)"
        );
        $changes++;
    }

    $self->_record_sync_run(
        undef, 'update-fpl-availability', 'bootstrap-static', $changes
    );

    return $changes;
}

=item backfill_news_return

  Re-parse the C<news> text of every availability row that has no
  C<news_return> and fill the date in where one can be found. Returns the
  number of rows updated.

  Rows are corrected in place, across every season, rather than being
  closed and reopened: an absent return date was a parsing omission on
  our side, not a change in the player's state, so inventing a
  transition would corrupt the history. Running this repeatedly is
  harmless.

=cut

sub backfill_news_return($self) {
    my $rows = $self->_select_all(
        'SELECT id, season, news
         FROM fpl_player_availability
         WHERE news_return IS NULL AND news IS NOT NULL'
    );

    my $changes = 0;
    foreach my $row (@$rows) {
        my $date = $self->_parse_news_return($row->{news}, $row->{season});
        next unless defined $date;

        $self->_apply(
            'UPDATE fpl_player_availability SET news_return = ? WHERE id = ?',
            $date, $row->{id},
            "backfill news_return=$date for availability row $row->{id}"
        );
        $changes++;
    }

    return $changes;
}

=back

=cut

sub _sync_league($self, $league) {
    my $fpl_league_id = $league->{id};
    my $my_entry_id   = $league->{entry};

    my $changes = 0;
    my $details = $self->api->league_details($fpl_league_id);

    my ($league_db_id, $league_changes) =
        $self->_upsert_league($fpl_league_id, $details);
    $changes += $league_changes;

    return $changes unless defined $league_db_id;

    my $entries = $self->_upsert_entries($league_db_id, $details, $my_entry_id);
    $changes += $entries->{changes};

    $changes += $self->_upsert_waiver_order($entries->{by_entry_id}, $details);
    $changes += $self->_upsert_matches($league_db_id, $entries->{by_league_entry_id}, $details);
    $changes += $self->_upsert_standings($league_db_id, $entries->{by_league_entry_id}, $details);

    my $choices = $self->api->choices($fpl_league_id);
    $changes += $self->_upsert_picks($league_db_id, $entries->{by_entry_id}, $choices);

    my $txns = $self->api->transactions($fpl_league_id);
    $changes += $self->_upsert_transactions($league_db_id, $entries->{by_entry_id}, $txns);

    my $element_status = $self->api->element_status($fpl_league_id);
    $changes += $self->_sync_ownership($league_db_id, $entries->{by_entry_id}, $element_status);

    $changes += $self->_sync_entry_picks($league_db_id, $entries->{by_entry_id}, $details);

    $self->_record_sync_run(
        $league_db_id, 'update-fpl-draft',
        'league-details,choices,transactions,element-status,entry-event', $changes
    );

    return $changes;
}

sub _sync_elements($self, $elements) {
    my $changes = 0;
    my %map;

    foreach my $e (@$elements) {
        my $player_id = $self->_player_id_for_code($e->{code});
        $map{$e->{id}} = $player_id;
        $changes += $self->_set_draft_id($player_id, $e->{id});
    }

    $self->{element_map} = \%map;
    return $changes;
}

sub _player_id_for_code($self, $code) {
    my ($id) = $self->dbh->selectrow_array(
        'SELECT id FROM players WHERE fpl_id = ?', undef, $code
    );
    return $id;
}

sub _set_draft_id($self, $player_id, $draft_id) {
    return 0 unless defined $player_id;

    my ($id, $current) = $self->dbh->selectrow_array(
        'SELECT id, fpl_draft_id FROM fpl_season_info
         WHERE player_id = ? AND season = ?',
        undef, $player_id, $self->season
    );

    return 0 unless defined $id;
    return 0 if defined $current && $current == $draft_id;

    $self->_apply(
        'UPDATE fpl_season_info SET fpl_draft_id = ? WHERE id = ?',
        $draft_id, $id,
        "set fpl_draft_id=$draft_id for player $player_id"
    );
    return 1;
}

sub _upsert_league($self, $fpl_league_id, $details) {
    my $l    = $details->{league};
    my $name = $l->{name} // '';

    my $row = $self->_select_row(
        'SELECT id, name, scoring, transaction_mode, trades, start_event, stop_event
         FROM fpl_draft_leagues WHERE fpl_league_id = ? AND season = ?',
        $fpl_league_id, $self->season
    );

    if (!$row) {
        my $id = $self->_insert_returning(
            'INSERT INTO fpl_draft_leagues
               (fpl_league_id, season, name, scoring, transaction_mode,
                trades, draft_dt, start_event, stop_event)
             VALUES (?,?,?,?,?,?,?,?,?) RETURNING id',
            $fpl_league_id, $self->season, $name, $l->{scoring},
            $l->{transaction_mode}, $l->{trades}, $l->{draft_dt},
            $l->{start_event}, $l->{stop_event},
            "insert league $fpl_league_id"
        );
        return ($id, defined $id ? 1 : 0);
    }

    my ($id, $c_name, $c_scoring, $c_txn, $c_trades, $c_start, $c_stop) = @$row;

    my $changed = 0;
    $changed ||= $self->_differs($c_name, $name);
    $changed ||= $self->_differs($c_scoring, $l->{scoring});
    $changed ||= $self->_differs($c_txn, $l->{transaction_mode});
    $changed ||= $self->_differs($c_trades, $l->{trades});
    $changed ||= $self->_differs($c_start, $l->{start_event});
    $changed ||= $self->_differs($c_stop, $l->{stop_event});

    if ($changed) {
        $self->_apply(
            'UPDATE fpl_draft_leagues
             SET name = ?, scoring = ?, transaction_mode = ?, trades = ?,
                 start_event = ?, stop_event = ?
             WHERE id = ?',
            $name, $l->{scoring}, $l->{transaction_mode}, $l->{trades},
            $l->{start_event}, $l->{stop_event}, $id,
            "update league $fpl_league_id"
        );
        return ($id, 1);
    }

    return ($id, 0);
}

sub _upsert_entries($self, $league_db_id, $details, $my_entry_id) {
    my %by_entry_id;
    my %by_league_entry_id;
    my $changes = 0;

    foreach my $e (@{$details->{league_entries}}) {
        my $is_mine = defined $my_entry_id && $e->{entry_id} == $my_entry_id ? 1 : 0;

        my $row = $self->_select_row(
            'SELECT id, entry_name, player_first_name, player_last_name,
                    short_name, is_mine, league_entry_id
             FROM fpl_draft_entries WHERE league_id = ? AND entry_id = ?',
            $league_db_id, $e->{entry_id}
        );

        my $id;
        if (!$row) {
            $id = $self->_insert_returning(
                'INSERT INTO fpl_draft_entries
                   (league_id, entry_id, league_entry_id, entry_name,
                    player_first_name, player_last_name, short_name, is_mine)
                 VALUES (?,?,?,?,?,?,?,?) RETURNING id',
                $league_db_id, $e->{entry_id}, $e->{id}, $e->{entry_name},
                $e->{player_first_name}, $e->{player_last_name},
                $e->{short_name}, $is_mine,
                "insert entry $e->{entry_name}"
            );
            $changes++ if defined $id;
        } else {
            $id = $row->[0];
            my $changed = 0;
            $changed ||= $self->_differs($row->[1], $e->{entry_name});
            $changed ||= $self->_differs($row->[2], $e->{player_first_name});
            $changed ||= $self->_differs($row->[3], $e->{player_last_name});
            $changed ||= $self->_differs($row->[4], $e->{short_name});
            $changed ||= $self->_bool_differs($row->[5], $is_mine);
            $changed ||= $self->_differs($row->[6], $e->{id});

            if ($changed) {
                $self->_apply(
                    'UPDATE fpl_draft_entries
                     SET entry_name = ?, player_first_name = ?, player_last_name = ?,
                         short_name = ?, is_mine = ?, league_entry_id = ?
                     WHERE id = ?',
                    $e->{entry_name}, $e->{player_first_name},
                    $e->{player_last_name}, $e->{short_name}, $is_mine,
                    $e->{id}, $id,
                    "update entry $e->{entry_name}"
                );
                $changes++;
            }
        }

        $by_entry_id{$e->{entry_id}}       = $id;
        $by_league_entry_id{$e->{id}}      = $id;
    }

    return {
        changes           => $changes,
        by_entry_id       => \%by_entry_id,
        by_league_entry_id => \%by_league_entry_id,
    };
}

sub _upsert_waiver_order($self, $by_entry_id, $details) {
    my $changes = 0;

    foreach my $e (@{$details->{league_entries}}) {
        my $draft_entry_id = $by_entry_id->{$e->{entry_id}};
        next unless defined $draft_entry_id;

        my $pick = $e->{waiver_pick};
        my $row = $self->_select_row(
            'SELECT id, waiver_pick FROM fpl_draft_waiver_order
             WHERE draft_entry_id = ? AND end_time IS NULL',
            $draft_entry_id
        );

        if (!$row) {
            $self->_apply(
                'INSERT INTO fpl_draft_waiver_order (draft_entry_id, waiver_pick)
                 VALUES (?, ?)',
                $draft_entry_id, $pick,
                "insert waiver order for entry $draft_entry_id"
            );
            $changes++;
        } elsif ($row->[1] != $pick) {
            $self->_apply(
                'UPDATE fpl_draft_waiver_order SET end_time = now() WHERE id = ?',
                $row->[0], "close waiver order row $row->[0]"
            );
            $self->_apply(
                'INSERT INTO fpl_draft_waiver_order (draft_entry_id, waiver_pick)
                 VALUES (?, ?)',
                $draft_entry_id, $pick,
                "insert new waiver order for entry $draft_entry_id"
            );
            $changes += 2;
        }
    }

    return $changes;
}

sub _upsert_matches($self, $league_db_id, $by_league_entry_id, $details) {
    my $changes = 0;

    foreach my $m (@{$details->{matches}}) {
        my $home = $by_league_entry_id->{$m->{league_entry_1}};
        my $away = $by_league_entry_id->{$m->{league_entry_2}};
        next unless defined $home && defined $away;

        my $win = defined $m->{winning_league_entry}
            ? $by_league_entry_id->{$m->{winning_league_entry}} : undef;

        my $home_pts = $m->{league_entry_1_points} // 0;
        my $away_pts = $m->{league_entry_2_points} // 0;
        my $finished = $m->{finished} ? 1 : 0;
        my $started  = $m->{started}  ? 1 : 0;
        my $method   = $m->{winning_method};

        my $row = $self->_select_row(
            'SELECT id FROM fpl_draft_matches
             WHERE league_id = ? AND event = ? AND home_draft_entry_id = ?',
            $league_db_id, $m->{event}, $home
        );

        if (!$row) {
            $self->_apply(
                'INSERT INTO fpl_draft_matches
                   (league_id, event, home_draft_entry_id, away_draft_entry_id,
                    home_points, away_points, finished, started,
                    winning_draft_entry_id, winning_method)
                 VALUES (?,?,?,?,?,?,?,?,?,?)',
                $league_db_id, $m->{event}, $home, $away,
                $home_pts, $away_pts, $finished, $started, $win, $method,
                "insert match event $m->{event}"
            );
            $changes++;
        } else {
            my $cur = $self->_select_row(
                'SELECT home_points, away_points, finished, started,
                        winning_draft_entry_id, winning_method
                 FROM fpl_draft_matches WHERE id = ?',
                $row->[0]
            );

            my $changed = 0;
            $changed ||= $self->_differs($cur->[0], $home_pts);
            $changed ||= $self->_differs($cur->[1], $away_pts);
            $changed ||= $self->_bool_differs($cur->[2], $finished);
            $changed ||= $self->_bool_differs($cur->[3], $started);
            $changed ||= $self->_differs($cur->[4], $win);
            $changed ||= $self->_differs($cur->[5], $method);

            if ($changed) {
                $self->_apply(
                    'UPDATE fpl_draft_matches
                     SET home_points = ?, away_points = ?, finished = ?, started = ?,
                         winning_draft_entry_id = ?, winning_method = ?
                     WHERE id = ?',
                    $home_pts, $away_pts, $finished, $started, $win, $method,
                    $row->[0],
                    "update match event $m->{event}"
                );
                $changes++;
            }
        }
    }

    return $changes;
}

sub _upsert_standings($self, $league_db_id, $by_league_entry_id, $details) {
    my $changes = 0;

    foreach my $s (@{$details->{standings}}) {
        my $draft_entry_id = $by_league_entry_id->{$s->{league_entry}};
        next unless defined $draft_entry_id;

        my $row = $self->_select_row(
            'SELECT id FROM fpl_draft_standings
             WHERE league_id = ? AND draft_entry_id = ?',
            $league_db_id, $draft_entry_id
        );

        my @vals = (
            $s->{rank}, $s->{last_rank},
            $s->{points_for} // 0, $s->{points_against} // 0,
            $s->{matches_played} // 0, $s->{matches_won} // 0,
            $s->{matches_drawn} // 0, $s->{matches_lost} // 0,
            $s->{total} // 0,
        );

        if (!$row) {
            $self->_apply(
                'INSERT INTO fpl_draft_standings
                   (league_id, draft_entry_id, rank, last_rank,
                    points_for, points_against, matches_played, matches_won,
                    matches_drawn, matches_lost, total)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                $league_db_id, $draft_entry_id, @vals,
                "insert standings for entry $draft_entry_id"
            );
            $changes++;
        } else {
            my $cur = $self->_select_row(
                'SELECT rank, last_rank, points_for, points_against,
                        matches_played, matches_won, matches_drawn,
                        matches_lost, total
                 FROM fpl_draft_standings WHERE id = ?',
                $row->[0]
            );

            my $changed = 0;
            for my $i (0 .. $#vals) {
                $changed ||= $self->_differs($cur->[$i], $vals[$i]);
            }

            if ($changed) {
                $self->_apply(
                    'UPDATE fpl_draft_standings
                     SET rank = ?, last_rank = ?, points_for = ?, points_against = ?,
                         matches_played = ?, matches_won = ?, matches_drawn = ?,
                         matches_lost = ?, total = ?, recorded_at = now()
                     WHERE id = ?',
                    @vals, $row->[0],
                    "update standings for entry $draft_entry_id"
                );
                $changes++;
            }
        }
    }

    return $changes;
}

sub _upsert_picks($self, $league_db_id, $by_entry_id, $choices) {
    my $changes = 0;

    foreach my $c (@$choices) {
        my $draft_entry_id = $by_entry_id->{$c->{entry}};
        next unless defined $draft_entry_id;

        my $draft_id = $c->{draft} // 1;
        my $row = $self->_select_row(
            'SELECT id FROM fpl_draft_picks
             WHERE league_id = ? AND draft_id = ? AND pick_index = ?',
            $league_db_id, $draft_id, $c->{index}
        );
        next if $row;

        my $player_id = $self->{element_map}{$c->{element}};
        my $was_auto  = $c->{was_auto} ? 1 : 0;

        $self->_apply(
            'INSERT INTO fpl_draft_picks
               (league_id, draft_entry_id, player_id, fpl_draft_element,
                draft_id, round, pick, pick_index, choice_time, was_auto)
             VALUES (?,?,?,?,?,?,?,?,?,?)',
            $league_db_id, $draft_entry_id, $player_id, $c->{element},
            $draft_id, $c->{round}, $c->{pick}, $c->{index},
            $c->{choice_time}, $was_auto,
            "insert pick index $c->{index}"
        );
        $changes++;
    }

    return $changes;
}

sub _upsert_transactions($self, $league_db_id, $by_entry_id, $txns) {
    my $changes = 0;

    foreach my $t (@$txns) {
        my $txn_id = $t->{id};
        unless (defined $txn_id) {
            debug "Skipping transaction without id: " . encode_json($t);
            next;
        }

        my $row = $self->_select_row(
            'SELECT id FROM fpl_draft_transactions
             WHERE league_id = ? AND fpl_transaction_id = ?',
            $league_db_id, $txn_id
        );
        next if $row;

        my $draft_entry_id =
            defined $t->{subject} ? $by_entry_id->{$t->{subject}} : undef;
        my $player_in  = defined $t->{element_in}
            ? $self->{element_map}{$t->{element_in}} : undef;
        my $player_out = defined $t->{element_out}
            ? $self->{element_map}{$t->{element_out}} : undef;

        $self->_apply(
            'INSERT INTO fpl_draft_transactions
               (league_id, draft_entry_id, player_in_id, player_out_id,
                element_in, element_out, kind, result, event, added_time, priority,
                fpl_transaction_id)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
            $league_db_id, $draft_entry_id, $player_in, $player_out,
            $t->{element_in}, $t->{element_out}, $t->{kind}, $t->{result},
            $t->{event}, $t->{added}, $t->{priority}, $txn_id,
            "insert transaction $txn_id"
        );
        $changes++;
    }

    return $changes;
}

sub _sync_ownership($self, $league_db_id, $by_entry_id, $element_status) {
    my $changes = 0;

    my $open = $self->_select_all(
        'SELECT id, fpl_draft_element, draft_entry_id, player_id, status,
                in_accepted_trade
         FROM fpl_draft_ownership
         WHERE league_id = ? AND end_time IS NULL',
        $league_db_id
    );
    my %open = map { $_->{fpl_draft_element} => $_ } @$open;

    my %seen;
    foreach my $es (@$element_status) {
        my $element = $es->{element};
        my $draft_entry_id =
            defined $es->{owner} ? $by_entry_id->{$es->{owner}} : undef;
        my $player_id = $self->{element_map}{$element};
        my $status    = $es->{status};
        my $in_trade  = $es->{in_accepted_trade} ? 1 : 0;

        my $cur = $open{$element};
        if (!$cur) {
            $self->_apply(
                'INSERT INTO fpl_draft_ownership
                   (league_id, draft_entry_id, player_id, fpl_draft_element,
                    status, in_accepted_trade)
                 VALUES (?,?,?,?,?,?)',
                $league_db_id, $draft_entry_id, $player_id, $element,
                $status, $in_trade,
                "insert ownership for element $element"
            );
            $changes++;
        } else {
            my $changed = 0;
            $changed ||= $self->_differs($cur->{draft_entry_id}, $draft_entry_id);
            $changed ||= $self->_differs($cur->{player_id}, $player_id);
            $changed ||= $self->_differs($cur->{status}, $status);
            $changed ||= $self->_bool_differs($cur->{in_accepted_trade}, $in_trade);

            if ($changed) {
                $self->_apply(
                    'UPDATE fpl_draft_ownership SET end_time = now() WHERE id = ?',
                    $cur->{id}, "close ownership for element $element"
                );
                $self->_apply(
                    'INSERT INTO fpl_draft_ownership
                       (league_id, draft_entry_id, player_id, fpl_draft_element,
                        status, in_accepted_trade)
                     VALUES (?,?,?,?,?,?)',
                    $league_db_id, $draft_entry_id, $player_id, $element,
                    $status, $in_trade,
                    "reopen ownership for element $element"
                );
                $changes += 2;
            }
        }

        $seen{$element} = 1;
    }

    # Close rows for elements no longer listed (e.g. removed from the game).
    foreach my $element (keys %open) {
        next if $seen{$element};
        $self->_apply(
            'UPDATE fpl_draft_ownership SET end_time = now() WHERE id = ?',
            $open{$element}{id}, "close ownership for element $element (removed)"
        );
        $changes++;
    }

    return $changes;
}

sub _sync_entry_picks($self, $league_db_id, $by_entry_id, $details) {
    my $changes = 0;

    my $start = $details->{league}{start_event} // 1;
    my $stop  = $details->{league}{stop_event}  // 38;

    my ($last_event) = $self->dbh->selectrow_array(
        'SELECT COALESCE(MAX(event), 0) FROM fpl_draft_entry_picks
         WHERE league_id = ?',
        undef, $league_db_id
    );

    my $now = time();
    for my $event ($start .. $stop) {
        my $epoch = $self->_event_epoch($event);
        next if !defined $epoch || $epoch > $now;
        next if $event <= $last_event;

        foreach my $entry_id (keys %$by_entry_id) {
            my $draft_entry_id = $by_entry_id->{$entry_id};
            next unless defined $draft_entry_id;

            my $data = $self->api->entry_event($entry_id, $event);
            next unless defined $data;

            $changes += $self->_upsert_entry_picks(
                $league_db_id, $draft_entry_id, $event, $data
            );
        }
    }

    return $changes;
}

sub _upsert_entry_picks($self, $league_db_id, $draft_entry_id, $event, $data) {
    my $picks = $data->{picks};
    return 0 unless ref $picks eq 'ARRAY';

    my $changes = 0;
    foreach my $p (@$picks) {
        my $element  = $p->{element};
        my $position = $p->{position};
        next unless defined $element && defined $position;

        my $player_id   = $self->{element_map}{$element};
        my $is_starting = $position <= 11 ? 1 : 0;

        my $row = $self->_select_row(
            'SELECT id, player_id FROM fpl_draft_entry_picks
             WHERE league_id = ? AND draft_entry_id = ? AND event = ? AND position = ?',
            $league_db_id, $draft_entry_id, $event, $position
        );

        if (!$row) {
            $self->_apply(
                'INSERT INTO fpl_draft_entry_picks
                   (league_id, draft_entry_id, event, player_id,
                    fpl_draft_element, position, is_starting)
                 VALUES (?,?,?,?,?,?,?)',
                $league_db_id, $draft_entry_id, $event, $player_id,
                $element, $position, $is_starting,
                "insert pick position $position for entry $draft_entry_id event $event"
            );
            $changes++;
        } elsif (!defined $row->[1] && defined $player_id) {
            # Backfill the player_id if the element has since been matched.
            $self->_apply(
                'UPDATE fpl_draft_entry_picks SET player_id = ? WHERE id = ?',
                $player_id, $row->[0],
                "backfill player_id for pick $row->[0]"
            );
            $changes++;
        }
    }

    return $changes;
}

sub _event_deadlines($self, $events) {
    my %deadlines;
    my $data = $events->{data} // [];
    foreach my $e (@$data) {
        $deadlines{$e->{id}} = $e->{deadline_time};
    }
    return \%deadlines;
}

sub _event_epoch($self, $event) {
    my $ts = $self->{event_deadlines}{$event};
    return unless defined $ts;

    $ts =~ s/\.\d+//; # strip fractional seconds
    my $t = eval { Time::Piece->strptime($ts, '%Y-%m-%dT%H:%M:%SZ') };
    return unless $t;
    return $t->epoch;
}

sub _record_sync_run($self, $league_db_id, $source, $endpoints, $changes, $notes = undef) {
    return if $self->dry_run;

    $self->_apply(
        'INSERT INTO fpl_draft_sync_runs
           (league_id, source, endpoints, changes, succeeded, notes)
         VALUES (?,?,?,?,?,?)',
        $league_db_id, $source, $endpoints, $changes, 1, $notes,
        'record sync run'
    );

    return;
}

# --- database helpers -------------------------------------------------

sub _select_row($self, $sql, @bind) {
    return $self->dbh->selectrow_arrayref($sql, undef, @bind);
}

sub _select_all($self, $sql, @bind) {
    return $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

# Note: these two helpers intentionally use classic @_ parsing rather than
# signatures, so the human-readable description can trail the bind values.
sub _apply {
    my ($self, $sql, @bind) = @_;
    my $description = pop @bind;

    if ($self->dry_run) {
        debug "DRY RUN: $description";
        return 1;
    }
    return $self->dbh->do($sql, undef, @bind);
}

sub _insert_returning {
    my ($self, $sql, @bind) = @_;
    my $description = pop @bind;

    if ($self->dry_run) {
        debug "DRY RUN: $description";
        return;
    }
    return $self->dbh->selectrow_array($sql, undef, @bind);
}

# Compare two possibly-undef values as normalised strings.
# Pull an expected return date out of FPL news text. The game writes
# "Expected back 22 Aug" for injuries and "Suspended until 6 Sep" for
# bans, never including a year. Returns a YYYY-MM-DD string, or undef if
# there's no parseable date ("Unknown return date", "75% chance of
# playing", transfer notices, and so on).
sub _parse_news_return($self, $news, $season) {
    return unless defined $news && defined $season;
    return unless $news =~ /(?:Expected \s back | Suspended \s until)
                            \s+ (\d{1,2}) \s+ ([A-Z][a-z]{2})/x;

    my ($day, $month_name) = ($1, $2);
    my $month = $NEWS_MONTHS{$month_name};
    return unless defined $month;

    # Seasons span two calendar years: August to December belong to the
    # season's starting year, January to July to the one after.
    my $year = $month >= 8 ? $season : $season + 1;
    my $ymd  = sprintf('%04d-%02d-%02d', $year, $month, $day);

    # Round-trip through Time::Piece to reject impossible dates, which
    # strptime would otherwise silently roll over into the next month.
    my $parsed = eval { Time::Piece->strptime($ymd, '%Y-%m-%d') };
    return unless $parsed && $parsed->ymd eq $ymd;

    return $ymd;
}

sub _differs($self, $a, $b) {
    my $aa = defined $a ? $a : '';
    my $bb = defined $b ? $b : '';
    return $aa ne $bb;
}

# Compare two possibly-undef booleans (Perl 1/0 or DBI 't'/'f').
sub _bool_differs($self, $a, $b) {
    return $self->_bool($a) != $self->_bool($b);
}

sub _bool($self, $v) {
    return 0 unless defined $v;
    return 1 if $v eq 't' || $v eq 'true' || $v eq '1';
    return 0;
}

1;
