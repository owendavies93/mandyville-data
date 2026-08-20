package Mandyville::FPLClassic;

use Mojo::Base -base, -signatures;

use Mandyville::API::FPL;
use Mandyville::Database;
use Mandyville::Utils qw(current_season debug);

=head1 NAME

  Mandyville::FPLClassic - fetch and store FPL classic entry state

=head1 SYNOPSIS

  use Mandyville::FPLClassic;
  my $classic = Mandyville::FPLClassic->new({
      api   => Mandyville::API::FPL->new,
      dbh   => Mandyville::Database->new->rw_db_handle(),
      entry => 1234567,
  });

  my $changes = $classic->sync;

=head1 DESCRIPTION

  This module fetches the state of a classic Fantasy Premier League entry
  and stores it in the mandyville database: the entry itself, its
  per-gameweek history, its chips, its transfers and, once a gameweek's
  deadline has passed, its lineup picks. It also derives the current
  squad (last known picks plus the live transfer feed) and an estimate
  of the number of free transfers available, since the FPL API only
  publishes picks after a deadline has passed.

=head1 METHODS

=over

=item api

  An instance of Mandyville::API::FPL.

=item dbh

  A read-write handle to the Mandyville database.

=item entry

  The classic FPL entry id to track.

=item season

  The season to store data for, in YYYY format (the year the season
  started). Defaults to the current season.

=item dry_run

  If true, do not write to the database; log what would change instead.

=cut

has 'api'     => sub { shift->{api} };
has 'dbh'     => sub { shift->{dbh} };
has 'entry'   => sub { shift->{entry} };
has 'season'  => sub { shift->{season} };
has 'dry_run' => sub { shift->{dry_run} // 0 };

sub new($class, $options) {
    $options->{api}     //= Mandyville::API::FPL->new;
    $options->{dbh}     //= Mandyville::Database->new->rw_db_handle();
    $options->{season}  //= current_season();
    $options->{dry_run} //= 0;

    die 'No classic FPL entry id configured' unless defined $options->{entry};

    my $self = {
        api     => $options->{api},
        dbh     => $options->{dbh},
        entry   => $options->{entry},
        season  => $options->{season},
        dry_run => $options->{dry_run},
    };

    bless $self, $class;
    return $self;
}

=item new ( OPTIONS )

  Creates a new instance. C<OPTIONS> is a hashref that may contain
  C<api>, C<dbh>, C<entry>, C<season> and C<dry_run>; any of these left
  unset are defaulted. C<entry> is required.

=item sync

  Fetch and store the classic entry's profile, history, chips, transfers
  and past lineups. Returns the number of changes written.

=cut

sub sync($self) {
    my $entry_id = $self->entry;

    my $profile = $self->api->entry($entry_id);
    my $history = $self->api->entry_history($entry_id);
    my $transfers = $self->api->entry_transfers($entry_id);

    my $changes = $self->_upsert_entry($profile);

    my $classic_entry_id = $self->_classic_entry_db_id();
    return $changes unless defined $classic_entry_id;

    $changes += $self->_upsert_history($classic_entry_id, $history->{current});
    $changes += $self->_upsert_chips($classic_entry_id, $history->{chips});
    $changes += $self->_sync_transfers($classic_entry_id, $transfers);
    $changes += $self->_sync_picks($classic_entry_id, $profile->{started_event});

    return $changes;
}

=item current_squad

  Reconstruct the current squad as the last stored lineup with every
  transfer for later gameweeks applied in time order. Returns a hashref
  with:

    * players      => arrayref of player ids currently owned
    * captain      => fpl element id of the last known captain (or undef)
    * vice_captain => fpl element id of the last known vice captain (or undef)
    * upcoming     => the next gameweek that has not reached its deadline

  The lineup for the upcoming gameweek is not public before its deadline,
  so the captain and vice captain are the last known ones.

=cut

sub current_squad($self) {
    my $entry_db_id = $self->_classic_entry_db_id();
    return { players => [], upcoming => undef } unless defined $entry_db_id;

    my $last_event = $self->_last_picks_event($entry_db_id);

    my $now = time();
    my ($upcoming) = $self->dbh->selectrow_array(
        'SELECT gameweek FROM fpl_gameweeks
         WHERE season = ? AND extract(epoch from deadline)::bigint > ?
         ORDER BY deadline LIMIT 1',
        undef, $self->season, $now
    );

    # No upcoming deadline means the season is over; the last lineup is
    # the final squad.
    my $to_event = defined $upcoming ? $upcoming : 38;

    my %players;
    my ($captain, $vice) = (undef, undef);

    if (defined $last_event) {
        my $picks = $self->dbh->selectall_arrayref(
            'SELECT fpl_element, player_id, is_captain, is_vice_captain
             FROM fpl_classic_picks
             WHERE classic_entry_id = ? AND event = ?',
            { Slice => {} }, $entry_db_id, $last_event
        );

        foreach my $p (@$picks) {
            $players{$p->{fpl_element}} = $p->{player_id};
            $captain = $p->{fpl_element} if $p->{is_captain};
            $vice    = $p->{fpl_element} if $p->{is_vice_captain};
        }
    }

    my $from_event = defined $last_event ? $last_event + 1 : 1;

    my $transfers = $self->dbh->selectall_arrayref(
        'SELECT element_in, element_out, player_in_id
         FROM fpl_classic_transfers
         WHERE classic_entry_id = ? AND event >= ? AND event <= ?
         ORDER BY transfer_time',
        { Slice => {} }, $entry_db_id, $from_event, $to_event
    );

    foreach my $t (@$transfers) {
        delete $players{$t->{element_out}};
        $players{$t->{element_in}} = $t->{player_in_id};
    }

    # If the last known captain left the squad, the captaincy is unknown.
    $captain = undef unless defined $captain && exists $players{$captain};
    $vice    = undef unless defined $vice && exists $players{$vice};

    return {
        players      => [values %players],
        captain      => $captain,
        vice_captain => $vice,
        upcoming     => $upcoming,
    };
}

=item estimated_free_transfers

  Estimate the free transfers currently available. FPL grants one per
  completed gameweek (capped at five), and a transfer uses one unless it
  was made in a wildcard or free-hit gameweek. This is an estimate
  because the exact roll-over rules around chips are not modelled; the
  reminder messages mark it as approximate.

=cut

sub estimated_free_transfers($self) {
    my $entry_db_id = $self->_classic_entry_db_id();
    return 0 unless defined $entry_db_id;

    my ($completed) = $self->dbh->selectrow_array(
        'SELECT COUNT(*) FROM fpl_classic_entry_history
         WHERE classic_entry_id = ?',
        undef, $entry_db_id
    );

    my ($transfers) = $self->dbh->selectrow_array(
        'SELECT COUNT(*) FROM fpl_classic_transfers
         WHERE classic_entry_id = ?',
        undef, $entry_db_id
    );

    my $free = $completed - $transfers;

    return $free < 0 ? 0 : $free > 5 ? 5 : $free;
}

=item chips_remaining

  Return a list of chip names that have not yet been played this season.

=cut

sub chips_remaining($self) {
    my $entry_db_id = $self->_classic_entry_db_id();
    return [] unless defined $entry_db_id;

    my $played = $self->dbh->selectcol_arrayref(
        'SELECT name FROM fpl_classic_chips WHERE classic_entry_id = ?',
        undef, $entry_db_id
    );

    my %played = map { $_ => 1 } @$played;

    my @chips = grep { !$played{$_} }
        qw(wildcard freehit bboost 3xc);

    return \@chips;
}

=back

=cut

sub _upsert_entry($self, $profile) {
    my $row = $self->_select_row(
        'SELECT id, entry_name, player_first_name, player_last_name,
                started_event
         FROM fpl_classic_entries WHERE fpl_entry_id = ? AND season = ?',
        $self->entry, $self->season
    );

    my ($name, $first, $last) = (
        $profile->{name} // '',
        $profile->{player_first_name} // '',
        $profile->{player_last_name} // '',
    );

    if (!$row) {
        my $id = $self->_insert_returning(
            'INSERT INTO fpl_classic_entries
               (fpl_entry_id, season, entry_name, player_first_name,
                player_last_name, started_event, is_mine)
             VALUES (?,?,?,?,?,?,?) RETURNING id',
            $self->entry, $self->season, $name, $first, $last,
            $profile->{started_event}, 1,
            "insert classic entry $self->{entry}"
        );
        return defined $id ? 1 : 0;
    }

    my ($id, $c_name, $c_first, $c_last, $c_start) = @$row;

    my $changed = 0;
    $changed ||= $self->_differs($c_name, $name);
    $changed ||= $self->_differs($c_first, $first);
    $changed ||= $self->_differs($c_last, $last);
    $changed ||= $self->_differs($c_start, $profile->{started_event});

    if ($changed) {
        $self->_apply(
            'UPDATE fpl_classic_entries
             SET entry_name = ?, player_first_name = ?, player_last_name = ?,
                 started_event = ?
             WHERE id = ?',
            $name, $first, $last, $profile->{started_event}, $id,
            "update classic entry $self->{entry}"
        );
        return 1;
    }

    return 0;
}

sub _upsert_history($self, $classic_entry_id, $current) {
    my $changes = 0;

    foreach my $h (@{$current // []}) {
        my $row = $self->_select_row(
            'SELECT id FROM fpl_classic_entry_history
             WHERE classic_entry_id = ? AND event = ?',
            $classic_entry_id, $h->{event}
        );

        my @vals = (
            $h->{points}, $h->{total_points}, $h->{rank}, $h->{overall_rank},
            $h->{percentile_rank}, $h->{bank}, $h->{value},
            $h->{event_transfers}, $h->{event_transfers_cost},
            $h->{points_on_bench},
        );

        if (!$row) {
            $self->_apply(
                'INSERT INTO fpl_classic_entry_history
                   (classic_entry_id, event, points, total_points, rank,
                    overall_rank, percentile_rank, bank, value,
                    event_transfers, event_transfers_cost, points_on_bench)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
                $classic_entry_id, $h->{event}, @vals,
                "insert classic history event $h->{event}"
            );
            $changes++;
        }
    }

    return $changes;
}

sub _upsert_chips($self, $classic_entry_id, $chips) {
    my $changes = 0;

    foreach my $c (@{$chips // []}) {
        my $row = $self->_select_row(
            'SELECT id FROM fpl_classic_chips
             WHERE classic_entry_id = ? AND name = ? AND event = ?',
            $classic_entry_id, $c->{name}, $c->{event}
        );
        next if $row;

        $self->_apply(
            'INSERT INTO fpl_classic_chips
               (classic_entry_id, name, event, played_time)
             VALUES (?,?,?,?)',
            $classic_entry_id, $c->{name}, $c->{event}, $c->{time},
            "insert classic chip $c->{name}"
        );
        $changes++;
    }

    return $changes;
}

sub _sync_transfers($self, $classic_entry_id, $transfers) {
    my $changes = 0;

    foreach my $t (@$transfers) {
        my $row = $self->_select_row(
            'SELECT id FROM fpl_classic_transfers
             WHERE classic_entry_id = ? AND event = ? AND element_in = ?
               AND element_out = ? AND transfer_time = ?',
            $classic_entry_id, $t->{event}, $t->{element_in},
            $t->{element_out}, $t->{time}
        );
        next if $row;

        my $player_in  = $self->_player_id_for_element($t->{element_in});
        my $player_out = $self->_player_id_for_element($t->{element_out});

        $self->_apply(
            'INSERT INTO fpl_classic_transfers
               (classic_entry_id, event, player_in_id, player_out_id,
                element_in, element_out, element_in_cost, element_out_cost,
                transfer_time)
             VALUES (?,?,?,?,?,?,?,?,?)',
            $classic_entry_id, $t->{event}, $player_in, $player_out,
            $t->{element_in}, $t->{element_out},
            $t->{element_in_cost}, $t->{element_out_cost}, $t->{time},
            "insert classic transfer for event $t->{event}"
        );
        $changes++;
    }

    return $changes;
}

sub _sync_picks($self, $classic_entry_id, $started_event) {
    my $changes = 0;

    my $last_event = $self->_last_picks_event($classic_entry_id) // 0;
    my $now = time();

    my $events = $self->dbh->selectall_arrayref(
        'SELECT gameweek FROM fpl_gameweeks
         WHERE season = ? AND gameweek >= ?
           AND extract(epoch from deadline)::bigint <= ?
         ORDER BY gameweek',
        { Slice => {} }, $self->season,
        defined $started_event ? $started_event : 1, $now
    );

    foreach my $e (@$events) {
        my $event = $e->{gameweek};
        next if $event <= $last_event;

        my $data = eval { $self->api->entry_picks($self->entry, $event) };
        next unless defined $data && ref $data->{picks} eq 'ARRAY';

        foreach my $p (@{$data->{picks}}) {
            my $element = $p->{element};
            my $position = $p->{position};
            next unless defined $element && defined $position;

            my $player_id = $self->_player_id_for_element($element);

            $self->_apply(
                'INSERT INTO fpl_classic_picks
                   (classic_entry_id, event, player_id, fpl_element, position,
                    multiplier, is_captain, is_vice_captain, active_chip)
                 VALUES (?,?,?,?,?,?,?,?,?)',
                $classic_entry_id, $event, $player_id, $element, $position,
                $p->{multiplier} // 1,
                $p->{is_captain} ? 1 : 0,
                $p->{is_vice_captain} ? 1 : 0,
                $data->{active_chip},
                "insert classic pick position $position event $event"
            );
            $changes++;
        }
    }

    return $changes;
}

sub _classic_entry_db_id($self) {
    my ($id) = $self->dbh->selectrow_array(
        'SELECT id FROM fpl_classic_entries
         WHERE fpl_entry_id = ? AND season = ?',
        undef, $self->entry, $self->season
    );
    return $id;
}

sub _last_picks_event($self, $classic_entry_id) {
    my ($event) = $self->dbh->selectrow_array(
        'SELECT MAX(event) FROM fpl_classic_picks WHERE classic_entry_id = ?',
        undef, $classic_entry_id
    );
    return $event;
}

sub _player_id_for_element($self, $element) {
    return unless defined $element;

    my ($id) = $self->dbh->selectrow_array(
        'SELECT player_id FROM fpl_season_info
         WHERE season = ? AND fpl_season_id = ?',
        undef, $self->season, $element
    );
    return $id;
}

# --- database helpers -------------------------------------------------

sub _select_row($self, $sql, @bind) {
    return $self->dbh->selectrow_arrayref($sql, undef, @bind);
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

sub _differs($self, $a, $b) {
    my $aa = defined $a ? $a : '';
    my $bb = defined $b ? $b : '';
    return $aa ne $bb;
}

1;
