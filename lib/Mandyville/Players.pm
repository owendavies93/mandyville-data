package Mandyville::Players;

use Mojo::Base -base, -signatures;

use Mandyville::API::Understat;
use Mandyville::API::FootballData;
use Mandyville::Competitions;
use Mandyville::Countries;
use Mandyville::Database;
use Mandyville::Fixtures;
use Mandyville::Gameweeks;
use Mandyville::PlayerName qw(
    candidate_names name_variants normalise_name score_names
);
use Mandyville::Utils qw(current_season debug msg);

use Const::Fast;
use Carp;
use DateTime;
use List::Util qw(any);
use SQL::Abstract::More;

const my $UNDERSTAT_MAPPINGS => {
    npxG      => 'npxg',
    xA        => 'xa',
    xG        => 'xg',
    xGBuildup => 'xg_buildup',
    xGChain   => 'xg_chain',
};

const my $MATCH_THRESHOLD         => 0.80;
const my $MATCH_MARGIN            => 0.10;
const my $SQUAD_LOOKBACK_DAYS     => 400;
const my $JOIN_DATE_TOLERANCE_DAYS => 14;

=head1 NAME

  Mandyville::Players - fetch and store player data

=head1 SYNOPSIS

  use Mandyville::Players;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $teams = Mandyville::Teams->new({
      dbh  => $dbh,
      sqla => $sqla,
  });

  my $comps = Mandyville::Competitions->new({});

  my $fixtures = Mandyville::Fixtures->new({
      comps => $comps,
      dbh   => $dbh,
      sqla  => $sqla,
      teams => $teams,
  });

  my $players = Mandyville::Players->new({
      fapi      => Mandyville::API::FootballData->new,
      uapi      => Mandyville::API::Understat->new,
      comps     => $comps,
      countries => Mandyville::Countries->new,
      fixtures  => $fixtures,
      gameweeks => Mandyville::Gameweeks->new,
      dbh       => $dbh,
      sqla      => $sqla,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing player data,
  including player fixture data. It currently uses the football-data
  API for this, but will eventually use the understat data and the FPL
  API as well.

=head1 METHODS

=over

=item fapi

  An instance of Mandyville::API::FootballData

=item uapi

  An instance of Mandyville::API::Understat

=item comps

  An instance of Mandyville::Competitions.

=item countries

  An instance of Mandyville::Countries.

=item dbh

  A read-write handle to the Mandyville database.

=item fixtures

  An instance of Mandyville::Fixtures.

=item sqla

  An instance of SQL::Abstract::More.

=item teams

  An instance of Mandyville::Teams.

=cut

has 'fapi'      => sub { shift->{fapi} };
has 'uapi'      => sub { shift->{uapi} };
has 'comps'     => sub { shift->{comps} };
has 'countries' => sub { shift->{countries} };
has 'dbh'       => sub { shift->{dbh} };
has 'fixtures'  => sub { shift->{fixtures} };
has 'gameweeks' => sub { shift->{gameweeks} };
has 'sqla'      => sub { shift->{sqla} };
has 'teams'     => sub { shift->{teams} };

=item new ([ OPTIONS ])

  Creates a new instance of the module, and sets the various required
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

    * dbh  => A read-write handle to the Mandyville database
    * sqla => An instance of SQL::Abstract::More

  If these options aren't passed in, they will be instantied by this
  method. However, it's recommended to pass these options in for
  performance and memory usage reasons.

=cut

sub new($class, $options) {
    $options->{fapi} //= Mandyville::API::FootballData->new;
    $options->{uapi} //= Mandyville::API::Understat->new;
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    $options->{countries} //= Mandyville::Countries->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{comps} //= Mandyville::Competitions->new({
        fapi      => $options->{fapi},
        countries => $options->{countries},
        dbh       => $options->{dbh},
        sqla      => $options->{sqla},
    });

    $options->{gameweeks} //= Mandyville::Gameweeks->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{teams} //= Mandyville::Teams->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{fixtures} //=Mandyville::Fixtures->new({
        comps => $options->{comps},
        dbh   => $options->{dbh},
        sqla  => $options->{sqla},
        teams => $options->{teams},
    });

    my $self = {
        fapi      => $options->{fapi},
        uapi      => $options->{uapi},
        comps     => $options->{comps},
        countries => $options->{countries},
        dbh       => $options->{dbh},
        fixtures  => $options->{fixtures},
        gameweeks => $options->{gameweeks},
        sqla      => $options->{sqla},
        teams     => $options->{teams},
    };

    bless $self, $class;
    return $self;
}

=item deactivate_fpl_season ( SEASON )

  Mark all FPL season info entries for the given C<SEASON> as inactive.
  This should be called before processing FPL player data, so that
  only players present in the current API response are active.

=cut

sub deactivate_fpl_season($self, $season) {
    my ($stmt, @bind) = $self->sqla->update(
        -table => 'fpl_season_info',
        -set   => { active => 0 },
        -where => { season => $season },
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=item add_fpl_season_info ( PLAYER_ID, SEASON, FPL_ID, POSITION_ID, STARTING_PRICE )

  Add the FPL season info for the given C<PLAYER_ID>. Checks for the
  season info before inserting. Returns the ID of the season info
  entry.

  C<FPL_ID> is the current season FPL ID, not the FPL "code".
  C<POSITION_ID> is the entity type ID of the player (a number between
  1 and 4). C<STARTING_PRICE> is the integer price from the FPL API
  (i.e. the actual price multiplied by 10). It will be stored as the
  actual decimal value.

=cut

sub add_fpl_season_info($self, $player_id, $season, $fpl_id, $position_id, $starting_price) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(id starting_price)],
        -from    => 'fpl_season_info',
        -where   => {
            player_id => $player_id,
            season    => $season,
        },
    );

    my ($id, $existing_price) = $self->dbh->selectrow_array($stmt, undef, @bind);

    if (defined $id) {
        my $set = { active => 1 };
        if (!defined $existing_price && defined $starting_price) {
            $set->{starting_price} = $starting_price / 10;
        }

        ($stmt, @bind) = $self->sqla->update(
            -table => 'fpl_season_info',
            -set   => $set,
            -where => { id => $id },
        );

        $self->dbh->do($stmt, undef, @bind);
    } else {
        ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fpl_positions',
            -where   => {
                element_type_id => $position_id,
            },
        );

        my ($fpl_position_id) =
            $self->dbh->selectrow_array($stmt, undef, @bind);

        my $values = {
            player_id        => $player_id,
            season           => $season,
            fpl_season_id    => $fpl_id,
            fpl_positions_id => $fpl_position_id,
            active           => 1,
        };

        if (defined $starting_price) {
            $values->{starting_price} = $starting_price / 10;
        }

        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'fpl_season_info',
            -values    => $values,
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return $id;
}

=item add_unmatched_fpl_player ( FPL_INFO, SEASON, [ CONTEXT ] )

  Log an unmatched FPL player to the C<fpl_unmatched_players> table.
  Uses the FPL C<code> (persistent ID) and C<SEASON> as the unique
  key. If the player already exists for that season, updates the name
  and context fields rather than skipping. C<CONTEXT> is an optional
  hashref with C<team_name>, C<reason> and C<suggestion> (a hashref
  with C<player_id>, C<score> and C<db_name>) fields.

=cut

sub add_unmatched_fpl_player($self, $fpl_info, $season, $context = {}) {
    my $suggestion = $context->{suggestion} // {};

    my $values = {
        fpl_code    => $fpl_info->{code},
        first_name  => $fpl_info->{first_name},
        second_name => $fpl_info->{second_name},
        web_name    => $fpl_info->{web_name},
        season      => $season,
        fpl_team_id       => $fpl_info->{team},
        fpl_team_name     => $context->{team_name},
        element_type      => $fpl_info->{element_type},
        birth_date        => $fpl_info->{birth_date},
        team_join_date    => $fpl_info->{team_join_date},
        suggested_player_id => $suggestion->{player_id},
        suggested_score     => $suggestion->{score},
        suggestion_reason   => $context->{reason},
    };

    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'fpl_unmatched_players',
        -where   => {
            fpl_code => $fpl_info->{code},
            season   => $season,
        },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    if (defined $id) {
        ($stmt, @bind) = $self->sqla->update(
            -table => 'fpl_unmatched_players',
            -set   => {
                %$values,
                updated_at => \'now()',
            },
            -where => { id => $id },
        );
        $self->dbh->do($stmt, undef, @bind);
    } else {
        ($stmt, @bind) = $self->sqla->insert(
            -into   => 'fpl_unmatched_players',
            -values => $values,
        );
        $self->dbh->do($stmt, undef, @bind);
    }

    return;
}

=item remove_unmatched_fpl_player ( FPL_CODE, SEASON )

  Remove an FPL player from the C<fpl_unmatched_players> table,
  indicating they have been successfully matched.

=cut

sub remove_unmatched_fpl_player($self, $fpl_code, $season) {
    my ($stmt, @bind) = $self->sqla->delete(
        -from  => 'fpl_unmatched_players',
        -where => {
            fpl_code => $fpl_code,
            season   => $season,
        },
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=item find_player_by_fpl_info ( FPL_INFO, [ CONTEXT ] )

  Attempt to find a player in the mandyville database based on their
  info in the FPL API. Returns a hashref:

    { matched => 1, id, first_name, last_name, method, score,
      corroboration, fpl_id_conflict }

  or, when no match is made:

    { matched => 0, reason, suggestion }

  where C<reason> is one of C<no_match>, C<ambiguous>,
  C<uncorroborated>, C<dob_mismatch> or C<fpl_id_conflict>, and
  C<suggestion> carries the best candidate with C<player_id>, C<score>,
  C<db_name> and C<fpl_id_conflict> fields.

  First decisive stage wins:

  * match on C<players.fpl_id>
  * match an C<fpl_names> alias
  * exact normalised full-name match, scoped to the FPL team's squad,
    then Premier League players, then all players
  * scored fuzzy match within the squad
  * scored fuzzy match over Premier League, then all players

  C<CONTEXT> is an optional hashref with C<team_id> (mandyville team
  id) and C<date> (YYYY-MM-DD) fields, used to scope the search to the
  player's current club and to corroborate fuzzy matches.

=cut

sub find_player_by_fpl_info($self, $fpl_info, $context = {}) {
    my $fpl_id  = $fpl_info->{code};
    my $team_id = $context->{team_id};
    my $date    = $context->{date};

    my $variants = name_variants($fpl_info);

    if (defined $fpl_id) {
        my $hit = $self->_player_by_fpl_id($fpl_id);
        return $self->_match_result($hit, 'fpl_id', 1.0, [], $fpl_id)
            if $hit;
    }

    my $alias = $self->_match_fpl_name($variants);
    return $self->_match_result($alias, 'alias', 1.0, [], $fpl_id)
        if $alias;

    my $squad = defined $team_id
        ? $self->get_squad_for_team($team_id, $date)
        : [];

    my @scopes = (
        $squad,
        $self->get_pl_players(),
        $self->get_all_players_with_names(),
    );

    # Exact matches across all scopes first: an exact name match in a
    # broader scope must win over a fuzzy match in a narrower one.
    foreach my $candidates (@scopes) {
        my $exact = $self->_exact_match(
            $candidates, $fpl_info, $team_id, $date, $fpl_id
        );
        return $exact if $exact->{matched};

        # Ambiguity and conflicts on an exact full-name match are
        # scope-independent: a superset can only add more collisions.
        return $exact if $exact->{reason} eq 'ambiguous';
        return $exact if $exact->{reason} eq 'fpl_id_conflict';
    }

    # Fuzzy matches across all scopes. Unlike exact matches, a wider
    # scope can surface a clearer top candidate, so every non-match is
    # carried as a fallback and the best one returned at the end.
    my $best_fallback;
    foreach my $candidates (@scopes) {
        my $fuzzy = $self->_fuzzy_match(
            $variants, $candidates, $fpl_info, $team_id, $date, $fpl_id
        );
        return $fuzzy if $fuzzy->{matched};

        $best_fallback = $self->_better_unmatched($best_fallback, $fuzzy);
    }

    return $best_fallback // { matched => 0, reason => 'no_match' };
}

=item get_squad_for_team ( TEAM_ID, [ DATE ] )

  Return the candidate hashrefs for the squad of the team given by
  C<TEAM_ID> as of C<DATE> (defaults to today): players with a
  C<players_teams> stint covering C<DATE>, plus players with a
  C<players_fixtures> row for the team within the last
  C<SQUAD_LOOKBACK_DAYS> days. Each candidate is marked with an
  C<in_squad> flag. Cached per team for the life of the object.

=cut

sub get_squad_for_team($self, $team_id, $date = undef) {
    $date //= DateTime->today->ymd;

    return $self->{_squad_cache}{$team_id}
        if exists $self->{_squad_cache}{$team_id};

    my $lookback =
        DateTime->today->subtract(days => $SQUAD_LOOKBACK_DAYS)->ymd;

    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(p.id p.first_name p.last_name p.date_of_birth p.fpl_id)],
        -from    => [-join => qw(
            players|p <=>{p.id=pt.player_id} players_teams|pt
        )],
        -where   => {
            -and => [
                { 'pt.team_id'     => $team_id },
                { 'pt.start_date'  => { '<=' => $date } },
                { '-or' => [
                    { 'pt.end_date' => { '>' => $date } },
                    { 'pt.end_date' => undef },
                ] },
            ],
        },
    );

    my $stint_players =
        $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

    ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(p.id p.first_name p.last_name p.date_of_birth p.fpl_id)],
        -from    => [-join => qw(
            players|p <=>{p.id=pf.player_id} players_fixtures|pf
                      <=>{pf.fixture_id=f.id} fixtures|f
        )],
        -where   => {
            'pf.team_id'     => $team_id,
            'f.fixture_date' => { '>=' => $lookback },
        },
    );

    my $fixture_players =
        $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

    my %by_id;
    foreach my $row (@$stint_players, @$fixture_players) {
        $by_id{ $row->{id} } = $row;
    }

    my $squad = $self->_candidates_from_rows([values %by_id]);
    $_->{in_squad} = 1 for @$squad;

    $self->{_squad_cache}{$team_id} = $squad;
    return $squad;
}

=item get_pl_players ( )

  Return the candidate hashrefs for every player with a fixture in the
  English Premier League. Cached for the life of the object.

=cut

sub get_pl_players($self) {
    return $self->{_pl_players_cache} if $self->{_pl_players_cache};

    my ($stmt, @bind) = $self->sqla->select(
        -columns =>
            [-distinct => qw(p.id p.first_name p.last_name p.date_of_birth p.fpl_id)],
        -from    => [-join => qw(
            players|p <=>{p.id=pf.player_id}     players_fixtures|pf
                      <=>{pf.fixture_id=f.id}    fixtures|f
                      <=>{f.competition_id=c.id} competitions|c
                      <=>{c.country_id=co.id}    countries|co
        )],
        -where   => {
            'c.name'  => 'Premier League',
            'co.name' => 'England',
        },
    );

    my $rows = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);
    $self->{_pl_players_cache} = $self->_candidates_from_rows($rows);
    return $self->{_pl_players_cache};
}

=item get_all_players_with_names ( )

  Return the candidate hashrefs for every player with at least one
  C<players_fixtures> row. Cached for the life of the object.

=cut

sub get_all_players_with_names($self) {
    return $self->{_all_players_cache} if $self->{_all_players_cache};

    my ($stmt, @bind) = $self->sqla->select(
        -columns =>
            [-distinct => qw(p.id p.first_name p.last_name p.date_of_birth p.fpl_id)],
        -from    => [-join => qw(
            players|p <=>{p.id=pf.player_id} players_fixtures|pf
        )],
    );

    my $rows = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);
    $self->{_all_players_cache} = $self->_candidates_from_rows($rows);
    return $self->{_all_players_cache};
}

=item find_by_date_of_birth ( DOB )

  Return the candidate hashrefs for every player whose
  C<date_of_birth> equals C<DOB> (YYYY-MM-DD). Used to corroborate or
  disambiguate fuzzy name matches.

=cut

sub find_by_date_of_birth($self, $dob) {
    return [] unless defined $dob;

    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(id first_name last_name date_of_birth fpl_id)],
        -from    => 'players',
        -where   => { date_of_birth => $dob },
    );

    my $rows = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);
    return $self->_candidates_from_rows($rows);
}

=item update_date_of_birth ( PLAYER_ID, DOB )

  Set the C<date_of_birth> of C<PLAYER_ID> to C<DOB> when it is not
  already set. Returns C<1> if set, C<0> if already set to the same
  value, C<-1> if already set to a different value (left unchanged).

=cut

sub update_date_of_birth($self, $player_id, $dob) {
    return 0 unless defined $dob;

    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'date_of_birth',
        -from    => 'players',
        -where   => { id => $player_id },
    );

    my ($existing) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return 0  if defined $existing && $existing eq $dob;
    return -1 if defined $existing && $existing ne $dob;

    ($stmt, @bind) = $self->sqla->update(
        -table => 'players',
        -set   => { date_of_birth => $dob },
        -where => { id => $player_id },
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=item get_open_stint_start ( PLAYER_ID )

  Return the C<start_date> of the player's open C<players_teams> stint
  (the stint with no C<end_date>), or C<undef> if none exists.

=cut

sub get_open_stint_start($self, $player_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'start_date',
        -from    => 'players_teams',
        -where   => {
            player_id => $player_id,
            end_date  => undef,
        },
        -order_by => 'start_date DESC',
        -limit    => 1,
    );

    my ($start) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return $start;
}

sub _player_by_fpl_id($self, $fpl_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(id first_name last_name date_of_birth fpl_id)],
        -from    => 'players',
        -where   => { fpl_id => $fpl_id },
    );

    my ($row) = $self->dbh->selectrow_hashref($stmt, { Slice => {} }, @bind);
    return unless $row;

    return $self->_candidates_from_rows([$row])->[0];
}

sub _match_fpl_name($self, $variants) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(f.name p.id p.first_name p.last_name p.date_of_birth p.fpl_id)],
        -from    => [-join => qw(
            fpl_names|f <=>{f.player_id=p.id} players|p
        )],
    );

    my $rows = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);
    my %by_name;
    foreach my $row (@$rows) {
        $by_name{ normalise_name($row->{name}) } = $row;
    }

    foreach my $variant (@$variants) {
        if (my $row = $by_name{$variant}) {
            return $self->_candidates_from_rows([$row])->[0];
        }
    }

    return;
}

sub _candidates_from_rows($self, $rows) {
    return [
        map {
            {
                id            => $_->{id},
                first_name    => $_->{first_name},
                last_name     => $_->{last_name},
                date_of_birth => $_->{date_of_birth},
                fpl_id        => $_->{fpl_id},
                names         => candidate_names($_->{first_name}, $_->{last_name}),
            }
        } @$rows
    ];
}

sub _exact_match($self, $candidates, $fpl_info, $team_id, $date, $fpl_id) {
    my %variant_set =
        map { $_ => 1 } @{ $self->_exact_variants($fpl_info) };

    my @exact;
    foreach my $c (@$candidates) {
        my $name = $c->{names}[0];
        next unless defined $name;

        if ($variant_set{$name}) {
            push @exact, { candidate => $c, score => 1.0 };
        }
    }

    return { matched => 0, reason => 'no_match' } if !@exact;

    my $winner;
    if (@exact == 1) {
        $winner = $exact[0];
    } else {
        $winner = $self->_resolve_ambiguous(\@exact, $fpl_info, $team_id, $date);

        if (!$winner) {
            if ($team_id && grep { $_->{candidate}{in_squad} } @exact) {
                my @ids = map { $_->{candidate}{id} } @exact;
                msg "Possible duplicate players for '"
                    . $fpl_info->{first_name} . ' '
                    . $fpl_info->{second_name}
                    . "': " . join(' / ', @ids);
            }

            return $self->_unmatched_result('ambiguous', $exact[0], $fpl_id);
        }
    }

    if (my $conflict = $self->_fpl_id_conflict($winner->{candidate}, $fpl_id)) {
        return $self->_unmatched_result('fpl_id_conflict', $winner, $fpl_id);
    }

    return $self->_match_result($winner->{candidate}, 'exact', 1.0, ['name'], $fpl_id);
}

sub _fuzzy_match($self, $variants, $candidates, $fpl_info, $team_id, $date, $fpl_id) {
    my $scored = $self->_score_candidates($variants, $candidates);
    return { matched => 0, reason => 'no_match' } if !@$scored;

    my $top    = $scored->[0];
    my $second = $scored->[1];

    return { matched => 0, reason => 'no_match' }
        if $top->{score} < $MATCH_THRESHOLD;

    my $second_score = $second ? $second->{score} : 0;
    return $self->_unmatched_result('ambiguous', $top, $fpl_id)
        if $top->{score} - $second_score < $MATCH_MARGIN;

    my ($evidence, $ok) =
        $self->_corroborate($top->{candidate}, $fpl_info, $team_id);

    return $self->_unmatched_result('dob_mismatch', $top, $fpl_id) if !$ok;
    return $self->_unmatched_result('uncorroborated', $top, $fpl_id)
        if !@$evidence;

    if (my $conflict = $self->_fpl_id_conflict($top->{candidate}, $fpl_id)) {
        return $self->_unmatched_result('fpl_id_conflict', $top, $fpl_id);
    }

    return $self->_match_result(
        $top->{candidate}, 'fuzzy', $top->{score}, $evidence, $fpl_id
    );
}

sub _exact_variants($self, $fpl_info) {
    my $first  = $fpl_info->{first_name}  // '';
    my $second = $fpl_info->{second_name} // '';
    my $web    = $fpl_info->{web_name}    // '';

    my @variants;

    push @variants, normalise_name("$first $second");
    push @variants, normalise_name("$second $first")
        if length $first && length $second;

    # First word of a compound first name plus web name.
    if ($first =~ /^(\S+)\s/ && length $web) {
        push @variants, normalise_name("$1 $web");
    }

    # A multi-word web_name is a full name (e.g. "Juanlu Sánchez").
    push @variants, normalise_name($web) if $web =~ /\s/;

    my %seen;
    return [ grep { length $_ && !$seen{$_}++ } @variants ];
}

sub _score_candidates($self, $variants, $candidates) {
    my @scored;

    foreach my $c (@$candidates) {
        push @scored, {
            candidate => $c,
            score     => score_names($variants, $c->{names}),
        };
    }

    return [ sort { $b->{score} <=> $a->{score} } @scored ];
}

sub _resolve_ambiguous($self, $matches, $fpl_info, $team_id, $date) {
    my $fpl_dob = $fpl_info->{birth_date};

    if (defined $fpl_dob) {
        my @dob = grep {
            defined $_->{candidate}{date_of_birth}
                && $_->{candidate}{date_of_birth} eq $fpl_dob
        } @$matches;
        return $dob[0] if @dob == 1;
    }

    if (defined $team_id) {
        my @squad = grep { $_->{candidate}{in_squad} } @$matches;
        return $squad[0] if @squad == 1;
    }

    if (defined $team_id && defined $fpl_info->{team_join_date}) {
        my @by_join;
        foreach my $m (@$matches) {
            my $start =
                $self->_stint_start_for_team($m->{candidate}{id}, $team_id);

            push @by_join, $m
                if defined $start
                && $self->_days_between($start, $fpl_info->{team_join_date})
                    <= $JOIN_DATE_TOLERANCE_DAYS;
        }
        return $by_join[0] if @by_join == 1;
    }

    return;
}

sub _corroborate($self, $candidate, $fpl_info, $team_id) {
    my @evidence;

    my $fpl_dob = $fpl_info->{birth_date};
    my $db_dob  = $candidate->{date_of_birth};

    if (defined $fpl_dob && defined $db_dob) {
        if ($fpl_dob eq $db_dob) {
            push @evidence, 'dob';
        } else {
            return ([], 0);
        }
    }

    if (defined $team_id && $candidate->{in_squad}) {
        push @evidence, 'team';
    }

    if (defined $team_id && defined $fpl_info->{team_join_date}) {
        my $start = $self->_stint_start_for_team($candidate->{id}, $team_id);

        if (defined $start
            && $self->_days_between($start, $fpl_info->{team_join_date})
                <= $JOIN_DATE_TOLERANCE_DAYS) {
            push @evidence, 'join_date';
        }
    }

    return (\@evidence, 1);
}

sub _stint_start_for_team($self, $player_id, $team_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'start_date',
        -from    => 'players_teams',
        -where   => {
            player_id => $player_id,
            team_id   => $team_id,
        },
        -order_by => 'start_date DESC',
        -limit    => 1,
    );

    my ($start) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return $start;
}

sub _days_between($self, $a, $b) {
    return 1e9 unless defined $a && defined $b;

    my ($y1, $m1, $d1) = split /-/, $a;
    my ($y2, $m2, $d2) = split /-/, $b;

    my $da = DateTime->new(year => $y1, month => $m1, day => $d1);
    my $db = DateTime->new(year => $y2, month => $m2, day => $d2);

    return abs($da->delta_days($db)->in_units('days'));
}

sub _fpl_id_conflict($self, $candidate, $fpl_id) {
    return 0 unless defined $fpl_id && defined $candidate->{fpl_id};
    return 0 if $candidate->{fpl_id} == $fpl_id;
    return $candidate->{fpl_id};
}

sub _match_result($self, $candidate, $method, $score, $evidence, $fpl_id) {
    return {
        matched         => 1,
        id              => $candidate->{id},
        first_name      => $candidate->{first_name},
        last_name       => $candidate->{last_name},
        method          => $method,
        score           => $score,
        corroboration   => $evidence,
        fpl_id_conflict => $self->_fpl_id_conflict($candidate, $fpl_id),
    };
}

sub _unmatched_result($self, $reason, $scored = undef, $fpl_id = undef) {
    my $result = { matched => 0, reason => $reason };

    if ($scored) {
        my $c = $scored->{candidate};
        $result->{suggestion} = {
            player_id       => $c->{id},
            score           => $scored->{score},
            db_name         => ($c->{first_name} // '') . ' ' . ($c->{last_name} // ''),
            fpl_id_conflict => $self->_fpl_id_conflict($c, $fpl_id),
        };
    }

    return $result;
}

sub _better_unmatched($self, $a, $b) {
    return $a // $b unless $a && $b;

    my $rank = sub {
        my ($r) = @_;
        return 0 if $r->{reason} eq 'no_match';
        return 1 if $r->{reason} eq 'uncorroborated';
        return 2 if $r->{reason} eq 'ambiguous';
        return 3 if $r->{reason} eq 'dob_mismatch';
        return 4 if $r->{reason} eq 'fpl_id_conflict';
        return 0;
    };

    my ($ra, $rb) = ($rank->($a), $rank->($b));
    return $b if $rb > $ra;
    return $a if $ra > $rb;

    my $sa = $a->{suggestion}{score} // 0;
    my $sb = $b->{suggestion}{score} // 0;
    return $sb > $sa ? $b : $a;
}

=item find_understat_id ( ID )

  Attempt to find the understat ID for the player with the given
  C<ID>. C<ID> refers to the mandyville database ID in this case. Runs
  through the following steps to attempt to do this:

  * Work out the most teams for the player
  * Search understat for the player's full name
  * If there's a result with the correct team, use that ID
  * If not, search for the player's last name
  * If still not, search for the player's first name

  Note that understat team names won't always match mandyville database
  team names, and are usually shorter, so do a substring check when
  comparing team names.

  Inserts the understat ID into the database if one is found. Dies if
  no ID is found (since we want to alert and fix in that case).

=cut

sub find_understat_id($self, $id) {
    my $teams = $self->_get_teams($id);

    my ($first, $last) = $self->_get_name($id);

    my $full = "$first $last";

    my @options;
    if ($last ne '') {
        @options = ($full, $last, $first);
    } else {
        @options = ($first);
    }

    foreach my $string (@options) {
        my $res = $self->_search_understat_and_store(
            $string, $id, $teams
        );

        return $res if defined $res;
    }

    die "Couldn't find understat ID for player #$id: $full";
}

=item get_by_football_data_id ( FOOTBALL_DATA_ID )

  Fetch the player associated with the given C<FOOTBALL_DATA_ID>. Does
  no insertion into the database; returns undef if no player is found,
  returns the mandyville database ID of the found player if a player is
  found.

=cut

sub get_by_football_data_id($self, $football_data_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'players',
        -where   => {
            football_data_id => $football_data_id,
        },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return $id;
}

=item get_or_insert ( FOOTBALL_DATA_ID, PLAYER_INFO )

  Fetch the player associated with the given C<FOOTBALL_DATA_ID>. If no
  such player is found, check for a potential duplicate by looking for
  players with the same first name and country where one last name is a
  component of the other's hyphenated surname. If a match is found,
  update the existing record's C<football_data_id>.

  Otherwise, insert the player into the database using the fields
  provided in C<PLAYER_INFO>. The C<first_name>, C<last_name> and
  C<country_name> attributes are required for insertion. The
  C<country_name> field should refer to the player's nationality, not
  their country of birth. Returns a hashref of the fetched or inserted
  player information.

=cut

sub get_or_insert($self, $football_data_id, $player_info) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(p.id p.first_name p.last_name c.name) ],
        -from    => [ -join => qw(
            players|p <=>{p.country_id=c.id} countries|c
        )],
        -where   => {
            'p.football_data_id' => $football_data_id,
        }
    );

    my ($id, $first_name, $last_name, $country_name) =
        $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        for (qw(first_name last_name country_name)) {
            croak "missing $_ attribute in player_info param"
                unless defined $player_info->{$_};
        }

        my $country_id =
            $self->countries->get_country_id($player_info->{country_name});

        if (!defined $country_id) {
            $country_id = $self->countries->get_id_for_alternate_name(
                $player_info->{country_name}
            );
        }

        die 'No country with name ' . $player_info->{country_name} . ' found'
            unless defined $country_id;

        # Check for potential duplicate with hyphenated surname
        my $existing = $self->_find_hyphen_duplicate(
            $player_info->{first_name},
            $player_info->{last_name},
            $country_id,
        );

        if (defined $existing) {
            ($stmt, @bind) = $self->sqla->update(
                -table => 'players',
                -set   => {
                    football_data_id => $football_data_id,
                },
                -where => { id => $existing->{id} },
            );
            $self->dbh->do($stmt, undef, @bind);

            return {
                id           => $existing->{id},
                first_name   => $existing->{first_name},
                last_name    => $existing->{last_name},
                country_name => $player_info->{country_name},
            };
        }

        my %values = (
            first_name       => $player_info->{first_name},
            last_name        => $player_info->{last_name},
            country_id       => $country_id,
            football_data_id => $football_data_id,
        );

        $values{date_of_birth} = $player_info->{dateOfBirth}
            if defined $player_info->{dateOfBirth};

        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'players',
            -values    => \%values,
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        $first_name   = $player_info->{first_name};
        $last_name    = $player_info->{last_name};
        $country_name = $player_info->{country_name};
    }

    return {
        id           => $id,
        first_name   => $first_name,
        last_name    => $last_name,
        country_name => $country_name,
    };
}

=item get_fpl_id ( PLAYER_ID )

  Fetch the FPL entity ID (code) for the player corresponding to
  C<PLAYER_ID>. Returns undef if no FPL ID is set.

=cut

sub get_fpl_id($self, $player_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'fpl_id',
        -from    => 'players',
        -where   => { id => $player_id },
    );

    my ($fpl_id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return $fpl_id;
}

=item get_team_for_player_fixture ( PLAYER_ID, FIXTURE_ID )

  Fetch the team ID for the given C<PLAYER_ID> and C<FIXTURE_ID>
  from the C<players_fixtures> DB table.

=cut

sub get_team_for_player_fixture($self, $player_id, $fixture_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'team_id',
        -from    => 'players_fixtures',
        -where   => {
            fixture_id => $fixture_id,
            player_id  => $player_id,
        }
    );

    my ($team_id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return $team_id;
}

=item update_player_team ( PLAYER_ID, TEAM_ID, DATE )

  Record that the player given by C<PLAYER_ID> plays for the team
  given by C<TEAM_ID> as of C<DATE>. Updates the C<players_teams>
  table so that the player has an open stint for C<TEAM_ID>:

  * If an open stint for the same team already exists, do nothing.
  * If an open stint for a different team exists, close it by setting
    its C<end_date> to C<DATE>, and insert a new open stint starting
    on C<DATE>.
  * If no open stint exists, insert a new open stint starting on
    C<DATE>.

  National teams are ignored and never recorded in C<players_teams>.

  Returns the number of rows modified (0 or 1).

=cut

sub update_player_team($self, $player_id, $team_id, $date) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'is_national_team',
        -from    => 'teams',
        -where   => { id => $team_id },
    );

    my ($is_national_team) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return 0 if $is_national_team;

    ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(id team_id)],
        -from    => 'players_teams',
        -where   => {
            player_id => $player_id,
            end_date  => undef,
        },
    );

    my ($stint_id, $stint_team_id) =
        $self->dbh->selectrow_array($stmt, undef, @bind);

    return 0 if defined $stint_id && $stint_team_id == $team_id;

    if (defined $stint_id) {
        ($stmt, @bind) = $self->sqla->update(
            -table => 'players_teams',
            -set   => { end_date => $date },
            -where => { id => $stint_id },
        );

        $self->dbh->do($stmt, undef, @bind);
    }

    ($stmt, @bind) = $self->sqla->insert(
        -into   => 'players_teams',
        -values => {
            player_id  => $player_id,
            team_id    => $team_id,
            start_date => $date,
        },
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=item get_player_team ( PLAYER_ID, [ DATE ] )

  Fetch the team ID for the player given by C<PLAYER_ID>. If C<DATE>
  is provided, returns the team the player was at on that date;
  otherwise returns the team the player currently plays for (i.e. the
  team of their open stint). Returns undef if no matching stint is
  found.

=cut

sub get_player_team($self, $player_id, $date=undef) {
    my $where = { player_id => $player_id };

    if (defined $date) {
        $where = $self->sqla->merge_conditions($where, {
            'start_date' => { '<=' => $date },
            '-or' => [
                { 'end_date' => { '>' => $date } },
                { 'end_date' => undef },
            ],
        });
    } else {
        $where->{end_date} = undef;
    }

    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'team_id',
        -from    => 'players_teams',
        -where   => $where,
        -order_by => 'start_date DESC',
        -limit   => 1,
    );

    my ($team_id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return $team_id;
}

=item get_player_teams ( PLAYER_ID )

  Fetch all team names the player given by C<PLAYER_ID> has played
  for, based on their stints in the C<players_teams> table. Returns an
  arrayref of team names.

=cut

sub get_player_teams($self, $player_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns  => [-distinct => 't.name'],
        -from     => [-join => qw(
            players_teams|pt <=>{pt.team_id=t.id} teams|t
        )],
        -where    => {
            'pt.player_id' => $player_id,
        },
    );

    return $self->dbh->selectcol_arrayref($stmt, undef, @bind);
}

=item get_with_missing_understat_ids ( COMP_IDS )

  Fetch all player IDs from the database without corresponding
  understat IDs. Returns an arrayref of these IDs.

  If C<COMP_IDS> is provided, only returns players who have known
  fixtures in the competitions corresponding to the provided IDs
  (regardless of whether they are currently playing in that
  competition, or if their most recent fixture is in another
  competiton).

=cut

sub get_with_missing_understat_ids($self, $comp_ids=[]) {
    my %query = (
        -columns => 'id',
        -from    => 'players',
        -where   => {
            understat_id => undef,
        }
    );

    if (scalar @$comp_ids > 0) {
        %query = (
            -columns => [-distinct => 'p.id'],
            -from    => [ -join => qw(
                players|p <=>{p.id=pf.player_id} players_fixtures|pf
                          <=>{pf.fixture_id=f.id} fixtures|f
            )],
            -where   => {
                'f.competition_id' => {
                    -in => $comp_ids,
                },
                'p.understat_id' => undef,
            }
        );
    }

    my ($stmt, @bind) = $self->sqla->select(%query);

    my $ids = $self->dbh->selectcol_arrayref($stmt, undef, @bind);
    return $ids;
}

=item get_without_understat_data ( SEASON, COMP_IDS )

  Fetches all players that have an understat ID but have no understat
  data. Excludes any non-unique understat IDs, since we don't want to
  mistakenly assign data to the wrong player. Only fetches for the
  given C<SEASON> and C<COMP_IDS> (which should be an arrayref of
  competition IDs).

  Returns an arrayref of hashrefs, containing the C<id> and
  C<understat_id> attributes.

=cut

sub get_without_understat_data($self, $season, $comp_ids) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'understat_id',
        -from    => 'players',
        -group_by => 'understat_id',
        -having   => {
            'COUNT(understat_id)' => { '>' => 1 }
        }
    );

    my $ids = $self->dbh->selectcol_arrayref($stmt, undef, @bind);

    my $where = {
        'f.competition_id' => { -in => $comp_ids },
        'f.season'         => $season,
        'p.understat_id'   => { '!=' => undef },
        'pf.goals'         => undef,
    };

    if (scalar @$ids > 0) {
        $where = $self->sqla->merge_conditions($where, {
            'p.understat_id' => { -not_in => $ids }
        });
    }

    ($stmt, @bind) = $self->sqla->select(
        -columns  => [-distinct => qw/p.id p.understat_id/],
        -from     => [ -join => qw(
            players|p <=>{p.id=pf.player_id}  players_fixtures|pf
                      <=>{pf.fixture_id=f.id} fixtures|f
        )],
        -where    => $where,
    );

    my $results = $self->dbh->selectall_arrayref(
        $stmt, { Slice => {} }, @bind
    );

    return $results;
}

=item process_fpl_season_history ( PLAYER_ID, FPL_SEASON_INFO )

  Process the FPL current season history for the player given by C<ID>.
  C<ID> should be the mandyville database ID of the player.

  Goes through each gameweek in the season history, and adds the info
  if it doesn't already exist. Doesn't overwrite already stored info.

  If the current gameweek is ongoing, we may have the situation where
  there's partial info in the season history - we deal with this by
  checking if the score in the fixture info is defined, and ignoring
  the fixture info if it isn't.

  Returns the number of inserted rows in total.

  Note that we store the actual decimal value of the player, not the
  integer value returned by the FPL API.

=cut

sub process_fpl_season_history($self, $player_id, $fpl_season_info) {
    my $season = current_season();
    my $count = 0;
    foreach my $gameweek (@$fpl_season_info) {
        my $gw_number = $gameweek->{round};

        if (!defined $gameweek->{team_h_score}) {
            debug "Skipping GW$gw_number, it's incomplete";
            next;
        }

        my $gw_id = $self->gameweeks->get_gameweek_id($season, $gw_number);

        my ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fpl_players_gameweeks',
            -where   => {
                player_id       => $player_id,
                fpl_gameweek_id => $gw_id,
            },
        );

        my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        if (!defined $id) {
            my $to_insert = {
                player_id       => $player_id,
                fpl_gameweek_id => $gw_id,
                bonus_points    => $gameweek->{bonus},
                bps             => $gameweek->{bps},
                total_points    => $gameweek->{total_points},
                transfers_in    => $gameweek->{transfers_in},
                transfers_out   => $gameweek->{transfers_out},
                selected        => $gameweek->{selected},
                value           => $gameweek->{value} / 10,
            };

            my ($stmt, @bind) = $self->sqla->insert(
                -into   => 'fpl_players_gameweeks',
                -values => $to_insert,
            );

            $count += $self->dbh->do($stmt, undef, @bind);
        }
    }

    return $count;
}

=item update_fixture_info ( FIXTURE_DATA )

  Process the player data for a fixture, inserting player data where
  necessary. The C<FIXTURE_DATA> paramater should be hashref in the
  same format as the JSON shown in
  football-data.org/documentation/api#match. Doesn't attempt to
  process player information for an incomplete fixture.

  Calls out to the football-data API to fetch player info if the
  player isn't previously known.

=cut

sub update_fixture_info($self, $fixture_data) {
    my $fixture_info = $self->fixtures->process_fixture_data($fixture_data);

    return unless defined $fixture_data->{score}->{fullTime}->{home};

    my $fixture_id   = $fixture_info->{id};
    my $fixture_date = $fixture_info->{fixture_date};

    my $home_id = $fixture_info->{home_team_id};
    $self->_process_team_info(
        $fixture_id, $home_id, $fixture_data, $fixture_data->{homeTeam},
        $fixture_date);

    my $away_id = $fixture_info->{away_team_id};
    return $self->_process_team_info(
        $fixture_id, $away_id, $fixture_data, $fixture_data->{awayTeam},
        $fixture_date);
}

=item update_fpl_id ( PLAYER_ID, FPL_ID )

  Set the FPL entity ID for the player corresponding to C<PLAYER_ID>
  to C<FPL_ID>. Returns C<1> if set, C<0> if already set to the same
  code, or C<-1> if already set to a different code (left unchanged).

=cut

sub update_fpl_id($self, $player_id, $fpl_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'fpl_id',
        -from    => 'players',
        -where   => {
            id => $player_id,
        }
    );

    my ($result) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return 0  if defined $result && $result == $fpl_id;
    return -1 if defined $result;

    ($stmt, @bind) = $self->sqla->update(
        -table => 'players',
        -set   => {
            fpl_id => $fpl_id,
        },
        -where => {
            id => $player_id,
        }
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=item update_understat_fixture_info ( PLAYER_ID, FIXTURE_ID, TEAM_ID, UNDERSTAT_INFO )

  Add the understat information for the fixture event specified by the
  given C<PLAYER_ID>, C<FIXTURE_ID>, C<TEAM_ID>.

  Returns the status of the row update operation, i.e. 1 if the update
  succeeded, 0 if the update failed.

=cut

sub update_understat_fixture_info(
    $self, $player_id, $fixture_id, $team_id, $understat_info) {

    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'goals',
        -from    => 'players_fixtures',
        -where   => {
            fixture_id => $fixture_id,
            player_id  => $player_id,
            team_id    => $team_id,
        }
    );

    my ($goals) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return 0 if defined $goals;

    my $to_insert = {};
    for (qw(goals assists key_passes xG xA xGBuildup xGChain npg npxG
            position)) {

        croak "$_ not provided in understat info"
            unless defined $understat_info->{$_};

        if ($_ eq 'position') {
            my $position_id = $self->_get_position_id($understat_info->{$_});
            $to_insert->{position_id} = $position_id;
        } elsif (exists $UNDERSTAT_MAPPINGS->{$_}) {
            $to_insert->{$UNDERSTAT_MAPPINGS->{$_}} = $understat_info->{$_};
        } else {
            $to_insert->{$_} = $understat_info->{$_};
        }
    }

    ($stmt, @bind) = $self->sqla->update(
        -table => 'players_fixtures',
        -set   => $to_insert,
        -where => {
            fixture_id => $fixture_id,
            player_id  => $player_id,
            team_id    => $team_id,
        }
    );

    return $self->dbh->do($stmt, undef, @bind);
}

sub _process_team_info($self, $fixture_id, $team_id, $fixture_data, $team_info, $fixture_date) {
    my $starters = $team_info->{lineup};
    my $subs     = $team_info->{bench};

    my %bookings = map {
        $_->{player}->{id} => $_->{card}
    } @{$fixture_data->{bookings}};

    my %subsOff = map {
        $_->{playerOut}->{id} => $_->{minute}
    } @{$fixture_data->{substitutions}};

    my %subsOn = map {
        $_->{playerIn}->{id} => $_->{minute}
    } @{$fixture_data->{substitutions}};

    # TODO: reduce duplication
    foreach my $player (@$starters) {
        my $player_id = $self->get_by_football_data_id($player->{id});

        $player_id = $self->_get_api_info_and_store($player->{id})->{id}
            if !defined $player_id;

        my $yellow = $self->_has_card($player->{id}, \%bookings, 'YELLOW');
        my $red    = $self->_has_card($player->{id}, \%bookings, 'RED');

        my $minutes_played = exists $subsOff{$player->{id}} ?
                             ($subsOff{$player->{id}} // 0) : 90;

        my $info = {
            player_id   => $player_id,
            fixture_id  => $fixture_id,
            team_id     => $team_id,
            minutes     => $minutes_played,
            yellow_card => $yellow || 0,
            red_card    => $red || 0,
        };

        $self->_insert_player_fixture($info, $fixture_date);
    }

    foreach my $player (@$subs) {
        my $player_id = $self->get_by_football_data_id($player->{id});

        $player_id = $self->_get_api_info_and_store($player->{id})->{id}
            if !defined $player_id;

        my $yellow = $self->_has_card($player->{id}, \%bookings, 'YELLOW');
        my $red    = $self->_has_card($player->{id}, \%bookings, 'RED');

        my $minutes_played = exists $subsOn{$player->{id}} ?
                             90 - ($subsOn{$player->{id}} // 90) : 0;

        my $info = {
            player_id   => $player_id,
            fixture_id  => $fixture_id,
            team_id     => $team_id,
            minutes     => $minutes_played,
            yellow_card => $yellow || 0,
            red_card    => $red || 0,
        };

        $self->_insert_player_fixture($info, $fixture_date);
    }

    return 1;
}

sub _get_api_info_and_store($self, $player_id) {
    my $player_info = $self->_sanitise_name($self->fapi->player($player_id));

    my $to_insert = {
        first_name   => $player_info->{firstName},
        last_name    => $player_info->{lastName},
        country_name => $player_info->{nationality},
        dateOfBirth  => $player_info->{dateOfBirth},
    };
    # TODO: Add insert only mode to save a query
    my $id = $self->get_or_insert($player_id, $to_insert);
    return $id;
}

sub _get_teams($self, $id) {
    return $self->get_player_teams($id);
}

sub _get_name($self, $id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(first_name last_name) ],
        -from    => 'players',
        -where   => {
            'id' => $id,
        }
    );

    my ($first, $last) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return ($first, $last);
}

sub _get_position_id($self, $position) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'positions',
        -where   => {
            'name' => $position,
        }
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return $id;
}

sub _find_hyphen_duplicate($self, $first_name, $last_name, $country_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(id first_name last_name)],
        -from    => 'players',
        -where   => {
            first_name => $first_name,
            country_id => $country_id,
        },
    );

    my $candidates =
        $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

    for my $c (@$candidates) {
        next if $c->{last_name} eq $last_name;

        if ($last_name =~ /-/) {
            my @parts = split(/-/, $last_name);
            return $c if any { $_ eq $c->{last_name} } @parts;
        }

        if ($c->{last_name} =~ /-/) {
            my @parts = split(/-/, $c->{last_name});
            return $c if any { $_ eq $last_name } @parts;
        }
    }

    return;
}

sub _sanitise_name($self, $player_info) {
    my $first = $player_info->{firstName};
    my $last  = $player_info->{lastName};
    my $full  = $player_info->{name};

    return $player_info if defined $first && defined $last;

    if ($full =~ /\s/) {
        ($first, $last) = $full =~ /(\w+)\s+(.+)$/;
    } elsif (!defined $last) {
        $last = '';
    } elsif (!defined $first) {
        $first = '';
    }

    return {
        firstName   => $first,
        lastName    => $last,
        name        => $full,
        nationality => $player_info->{nationality},
        dateOfBirth => $player_info->{dateOfBirth},
    };
}

sub _has_card($self, $player_id, $booking_info, $colour) {
    return (exists $booking_info->{$player_id}) &&
           ($booking_info->{$player_id} eq $colour . "_CARD");
}

sub _insert_player_fixture($self, $info, $fixture_date) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'players_fixtures',
        -where   => {
           player_id  => $info->{player_id},
           fixture_id => $info->{fixture_id},
           team_id    => $info->{team_id},
        },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        my ($stmt, @bind) = $self->sqla->insert(
            -into      => 'players_fixtures',
            -values    => $info,
            -returning => 'id'
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        $self->update_player_team(
            $info->{player_id}, $info->{team_id}, $fixture_date
        );
    }

    return $id;
}

sub _search_understat_and_store($self, $string, $id, $teams) {
    my $results = $self->uapi->search($string);

    return if scalar @$results == 0;

    foreach my $player (@$results) {
        if (any { $_ =~ /\Q$player->{team}\E/ } @$teams) {
            my ($stmt, @bind) = $self->sqla->select(
                -columns => 'id',
                -from    => 'players',
                -where   => {
                    understat_id => $player->{id},
                },
            );

            my ($existing) = $self->dbh->selectrow_array($stmt, undef, @bind);

            next if defined $existing;

            ($stmt, @bind) = $self->sqla->update(
                -table => 'players',
                -set   => {
                    understat_id => $player->{id},
                },
                -where => {
                    id => $id,
                }
            );

            $self->dbh->do($stmt, undef, @bind);

            return $player;
        }
    }

    return;
}

sub _update_name($self, $id, $fd_id) {
    my $player_info = $self->_sanitise_name($self->fapi->player($fd_id));

    my ($stmt, @bind) = $self->sqla->update(
        -table => 'players',
        -set   => {
            first_name => $player_info->{firstName},
            last_name  => $player_info->{lastName},
        },
        -where => {
            id => $id,
        }
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=back

=cut

1;
