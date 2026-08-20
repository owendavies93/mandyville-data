package Mandyville::Gameweeks;

use Mojo::Base -base, -signatures;

use Mandyville::API::FPL;
use Mandyville::API::FPLDraft;
use Mandyville::Database;
use Mandyville::Utils qw(current_season);

use Const::Fast;
use SQL::Abstract::More;
use Time::Piece;

const my $NO_OF_GWS => 38;

=head1 NAME

  Mandyville::Gameweeks - fetch and store gameweek data

=head1 SYNOPSIS

  use Mandyville::Gameweeks;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $gameweeks = Mandyville::Gameweeks->new({
      api       => Mandyville::API::FPL->new,
      draft_api => Mandyville::API::FPLDraft->new,
      dbh       => $dbh,
      sqla      => $sqla,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing gameweek data,
  where a 'gameweek' refers to a set of matches in the Fantasy Premier
  League game. It stores the classic deadline as well as the draft game's
  deadline, waiver and trade times, recording each in a change-only
  history table so that deadline changes can be detected and reacted to.

=head1 METHODS

=over

=item api

  An instance of Mandyville::API::FPL.

=item draft_api

  An instance of Mandyville::API::FPLDraft.

=item dbh

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=cut

has 'api'       => sub { shift->{api} };
has 'draft_api' => sub { shift->{draft_api} };
has 'dbh'       => sub { shift->{dbh} };
has 'sqla'      => sub { shift->{sqla} };

=item new ([ OPTIONS ])

  Creates a new instance of the module, and sets the various required
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

    * api       => An instance of Mandyville::API::FPL
    * draft_api => An instance of Mandyville::API::FPLDraft
    * dbh       => A read-write handle to the Mandyville database
    * sqla      => An instance of SQL::Abstract::More

  If these options aren't passed in, they will be instantied by this
  method. However, it's recommended to pass these options in for
  performance and memory usage reasons.

=cut

sub new($class, $options) {
    $options->{api}       //= Mandyville::API::FPL->new;
    $options->{draft_api} //= Mandyville::API::FPLDraft->new;
    $options->{dbh}       //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla}      //= SQL::Abstract::More->new;

    my $self = {
        api       => $options->{api},
        draft_api => $options->{draft_api},
        dbh       => $options->{dbh},
        sqla      => $options->{sqla},
        changes   => [],
    };

    bless $self, $class;
    return $self;
}

=item add_fixture_gameweeks ([ SEASON ])

  Adds or updates gameweek information for all eligible fixtures in the
  database - that is, any Premier League fixtures which are in the
  given C<SEASON>. Uses the deadline times of the gameweeks to work out
  which gameweek the fixture falls into. If no C<SEASON> is provided,
  defaults to the current season.

=cut

sub add_fixture_gameweeks($self, $season=undef) {
    $season //= current_season();
    my $gws = $self->_get_gameweeks_for_season($season);

    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(f.id f.fixture_date)],
        -from    => [-join => qw(
            fixtures|f <=>{f.competition_id=c.id} competitions|c
                       <=>{c.country_id=co.id}    countries|co
        )],
        -where   => {
            'f.season' => $season,
            'co.name'  => 'England',
            'c.name'   => 'Premier League',
        }
    );

    my $fixtures =
        $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

    my $updated = 0;
    foreach my $f (@$fixtures) {
        my $gw =
            $self->_find_gameweek_from_fixture_date($f->{fixture_date}, $gws);

        ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fixtures_fpl_gameweeks',
            -where   => {
                fixture_id => $f->{id}
            }
        );

        my ($f_gw_id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        if (defined $f_gw_id) {
            ($stmt, @bind) = $self->sqla->update(
                -table => 'fixtures_fpl_gameweeks',
                -set   => {
                    gameweek_id => $gw->{id},
                },
                -where => {
                    id => $f_gw_id,
                }
            );
        } else {
            ($stmt, @bind) = $self->sqla->insert(
                -into   => 'fixtures_fpl_gameweeks',
                -values => {
                    fixture_id  => $f->{id},
                    gameweek_id => $gw->{id},
                }
            );
        }

        $updated += $self->dbh->do($stmt, undef, @bind);
    }

    return $updated;
}

=item get_gameweek_id ( SEASON, GAMEWEEK )

  Fetch the gameweek database ID associated with the given C<SEASON>
  and C<GAMEWEEK>. Dies if no gameweek ID is found.

=cut

sub get_gameweek_id($self, $season, $gameweek) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'fpl_gameweeks',
        -where   => {
            gameweek => $gameweek,
            season   => $season,
        }
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    die "No gameweek found for $season gw $gameweek" if !defined $id;

    return $id;
}

=item process_gameweeks

  Fetch the gameweek data for the current season from the FPL API, and
  store/update the information in the database. Deadline values are only
  written when they differ from what is already stored, and every change
  is recorded in the C<fpl_gameweek_deadline_history> table.

  Return the number of gameweeks that changed.

=cut

sub process_gameweeks($self) {
    my $gameweek_info = $self->api->gameweeks;
    my $season = current_season();
    my $updated = 0;

    foreach my $gw (@$gameweek_info) {
        my $gw_number = $gw->{id};
        my $deadline  = $gw->{deadline_time};

        # Sanity check the first gameweek deadline to ensure we're
        # processing the correct season, given that we've made
        # assumptions about the current season.
        if ($gw_number == 1) {
            my ($deadline_year) = $deadline =~ /^(\d{4})/;
            if ($deadline_year != $season) {
                die 'Deadline for first gameweek doesn\'t match season! ' .
                    'Has the next season started?';
            }
        }

        my ($stmt, @bind) = $self->sqla->select(
            -columns => [qw(id deadline)],
            -from    => 'fpl_gameweeks',
            -where   => {
                gameweek => $gw_number,
                season   => $season,
            }
        );

        my ($id, $current) = $self->dbh->selectrow_array($stmt, undef, @bind);

        if (defined $id) {
            next if $self->_same_timestamp($current, $deadline);

            ($stmt, @bind) = $self->sqla->update(
                -table => 'fpl_gameweeks',
                -set   => {
                    deadline => $deadline,
                },
                -where => {
                    id => $id
                }
            );
        } else {
            ($stmt, @bind) = $self->sqla->insert(
                -into   => 'fpl_gameweeks',
                -values => {
                    deadline => $deadline,
                    gameweek => $gw_number,
                    season   => $season,
                }
            );
        }

        $updated += $self->dbh->do($stmt, undef, @bind);
        $self->_record_deadline($id // $self->get_gameweek_id($season, $gw_number),
            $season, $gw_number, 'classic', $deadline, $current);
    }

    return $updated;
}

=item process_draft_gameweeks

  Fetch the draft game's event deadlines for the current season and
  store/update the draft deadline, waiver and trade times in the
  database, with the same change-only behaviour as C<process_gameweeks>.
  Return the number of gameweeks that changed.

=cut

sub process_draft_gameweeks($self) {
    my $events = $self->draft_api->events;
    my $season = current_season();
    my $updated = 0;

    my $data = ref $events eq 'HASH' && ref $events->{data} eq 'ARRAY'
        ? $events->{data} : $events;

    foreach my $gw (@$data) {
        my $gw_number = $gw->{id};
        next unless defined $gw_number;

        my ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fpl_gameweeks',
            -where   => {
                gameweek => $gw_number,
                season   => $season,
            }
        );

        my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        # The classic feed is normally processed first, but if this is the
        # first gameweek we've ever seen the classic deadline is unknown;
        # use the draft deadline as a temporary stand-in since the classic
        # column is not nullable.
        if (!defined $id) {
            ($stmt, @bind) = $self->sqla->insert(
                -into   => 'fpl_gameweeks',
                -values => {
                    deadline => $gw->{deadline_time},
                    gameweek => $gw_number,
                    season   => $season,
                }
            );

            if ($self->dbh->do($stmt, undef, @bind)) {
                $id = $self->get_gameweek_id($season, $gw_number);
                $self->_record_deadline(
                    $id, $season, $gw_number, 'classic',
                    $gw->{deadline_time}, undef
                );
            }
        }

        next unless defined $id;

        foreach my $kind (qw(draft waivers trades)) {
            my $value = $kind eq 'draft'
                ? $gw->{deadline_time}
                : $kind eq 'waivers'
                    ? $gw->{waivers_time}
                    : $gw->{trades_time};

            next unless defined $value;

            $updated += $self->_upsert_draft_deadline(
                $id, $season, $gw_number, $kind, $value
            );
        }
    }

    return $updated;
}

=item last_changes

  Return the deadline changes recorded by the most recent call to
  C<process_gameweeks> or C<process_draft_gameweeks>, as a list of
  hashrefs with C<season>, C<gameweek>, C<kind>, C<old> and C<new>.

=cut

sub last_changes($self) {
    return $self->{changes};
}

=item upcoming_deadlines ( FROM, HORIZON )

  Return the upcoming deadlines of every kind from the database between
  C<FROM> (epoch seconds) and C<FROM + HORIZON> (epoch seconds), as a
  list of hashrefs with C<season>, C<gameweek>, C<kind>, C<deadline> and
  C<deadline_epoch>.

=cut

sub upcoming_deadlines($self, $from, $horizon) {
    my $to = $from + $horizon;

    my $sql = q{
        SELECT season, gameweek, kind, deadline,
               extract(epoch from deadline)::bigint AS deadline_epoch
        FROM (
            SELECT season, gameweek, 'classic' AS kind, deadline
            FROM fpl_gameweeks WHERE deadline IS NOT NULL
            UNION ALL
            SELECT season, gameweek, 'draft' AS kind, draft_deadline
            FROM fpl_gameweeks WHERE draft_deadline IS NOT NULL
            UNION ALL
            SELECT season, gameweek, 'waivers' AS kind, waivers_time
            FROM fpl_gameweeks WHERE waivers_time IS NOT NULL
            UNION ALL
            SELECT season, gameweek, 'trades' AS kind, trades_time
            FROM fpl_gameweeks WHERE trades_time IS NOT NULL
        ) d
        WHERE extract(epoch from deadline)::bigint > ?::bigint
          AND extract(epoch from deadline)::bigint <= ?::bigint
        ORDER BY deadline_epoch
    };

    return $self->dbh->selectall_arrayref($sql, { Slice => {} }, $from, $to);
}

=back

=cut

sub _upsert_draft_deadline($self, $id, $season, $gameweek, $kind, $value) {
    my $column = $kind eq 'draft' ? 'draft_deadline'
               : $kind eq 'waivers' ? 'waivers_time'
               : 'trades_time';

    my ($current) = $self->dbh->selectrow_array(
        "SELECT $column FROM fpl_gameweeks WHERE id = ?", undef, $id
    );

    return 0 if $self->_same_timestamp($current, $value);

    my ($stmt, @bind) = $self->sqla->update(
        -table => 'fpl_gameweeks',
        -set   => { $column => $value },
        -where => { id => $id },
    );

    my $changed = $self->dbh->do($stmt, undef, @bind);
    $self->_record_deadline($id, $season, $gameweek, $kind, $value, $current);

    return $changed;
}

sub _record_deadline($self, $id, $season, $gameweek, $kind, $value, $old) {
    # First sightings open a history row but aren't reported as changes.
    push @{$self->{changes}}, {
        season   => $season,
        gameweek => $gameweek,
        kind     => $kind,
        old      => $old,
        new      => $value,
    } if defined $old && !$self->_same_timestamp($old, $value);

    $self->dbh->do(
        'UPDATE fpl_gameweek_deadline_history SET end_time = now()
         WHERE fpl_gameweek_id = ? AND kind = ? AND end_time IS NULL',
        undef, $id, $kind
    );

    $self->dbh->do(
        'INSERT INTO fpl_gameweek_deadline_history (fpl_gameweek_id, kind, deadline)
         VALUES (?,?,?)',
        undef, $id, $kind, $value
    );

    return;
}

sub _same_timestamp($self, $a, $b) {
    return 1 if !defined $a && !defined $b;
    return 0 if !defined $a || !defined $b;

    my $ae = $self->_timestamp_epoch($a);
    my $be = $self->_timestamp_epoch($b);

    return defined $ae && defined $be && $ae == $be;
}

sub _timestamp_epoch($self, $ts) {
    return $ts if $ts =~ /^\d+$/;

    # Accept both the API's ISO 8601 form (e.g. 2020-09-12T10:00:00Z) and
    # the space-separated form DBI returns for timestamptz columns (e.g.
    # 2020-09-12 11:00:00+01 in a Europe/London session). A numeric offset
    # is applied so both forms land on the same UTC epoch.
    my $offset;

    if ($ts =~ s/Z$//) {
        $offset = '+0000';
    } elsif ($ts =~ s/([+-]\d\d)(?::?(\d\d))?$//) {
        $offset = sprintf('%s%02d', $1, $2 // 0);
    }

    $ts =~ s/T/ /;

    my $parsed = defined $offset
        ? eval { Time::Piece->strptime("$ts $offset", '%Y-%m-%d %H:%M:%S %z') }
        : eval { Time::Piece->strptime($ts, '%Y-%m-%d %H:%M:%S') };

    return unless $parsed;
    return $parsed->epoch;
}

sub _find_gameweek_from_fixture_date($self, $fixture_date, $gw_info) {
    for (my $i = 1; $i < $NO_OF_GWS; $i++) {
        my $gw = $gw_info->[$i];
        my ($gw_date) = $gw->{deadline} =~ /^([\w-]+)\s/;

        if ($fixture_date lt $gw_date) {
            return $gw_info->[$i - 1];
        }
    }
    return $gw_info->[$NO_OF_GWS - 1];
}

sub _get_gameweeks_for_season($self, $season) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns  => [qw(id gameweek deadline)],
        -from     => 'fpl_gameweeks',
        -where    => {
            season => $season,
        },
        -order_by => 'gameweek',
    );

    my $gws = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);
    return $gws;
}

1;

