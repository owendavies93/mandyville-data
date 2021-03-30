package Mandyville::Fixtures;

use Mojo::Base -base, -signatures;

use Mandyville::Competitions;
use Mandyville::Countries;
use Mandyville::Database;
use Mandyville::Teams;

use Array::Utils qw(intersect);
use Carp;
use Const::Fast;
use List::Util qw(any);
use SQL::Abstract::More;

=head1 NAME

  Mandyville::Fixtures - fetch and store fixture data

=head1 SYNOPSIS

  use Mandyville::Fixtures;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $fixtures = Mandyville::Fixtures->new({
      comps => Mandyville::Competitions->new({}),
      dbh   => $dbh,
      sqla  => $sqla,
      teams => Mandyville::Teams->new({}),
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing fixture data.
  It primarly uses match data from the football-data API to achieve
  this.

=head1 METHODS

=over

=item comps

  An instance of Mandyville::Competitions;

=item dbh

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=item teams

  An instance of Mandyville::Teams.

=cut

has 'comps' => sub { shift->{comps} };
has 'dbh'   => sub { shift->{dbh} };
has 'sqla'  => sub { shift->{sqla} };
has 'teams' => sub { shift->{teams} };

=item new ([ OPTIONS ])

  Creates a new instance of the module, and sets the various required
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

    * comps => An instance of Mandyville::Competitions
    * dbh   => A read-write handle to the Mandyville database
    * sqla  => An instance of SQL::Abstract::More
    * teams => An instance of Mandyville::Teams

  If these options aren't passed in, they will be instantied by this
  method. However, it's recommended to pass these options in for
  performance and memory usage reasons.

=cut

sub new($class, $options) {
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    $options->{comps} //= Mandyville::Competitions->new({
        countries => Mandyville::Countries->new({
            dbh  => $options->{dbh},
            sqla => $options->{sqla},
        }),
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    my $self = {
        comps => $options->{comps},
        dbh   => $options->{dbh},
        sqla  => $options->{sqla},
        teams => $options->{teams},
    };

    bless $self, $class;
    return $self;
}

=item find_fixture_from_understat_data ( UNDERSTAT_DATA, COMPS )

  Attempts to find a fixture for the given C<UNDERSTAT_DATA>. Finds all
  teams matching the home and away team names, finds the combinations
  of those home and away teams that played in the same competition(s)
  in the given season (which is provided by the understat data), and
  finds all fixtures that match those combinations of home and away
  teams in that season.

  This will almost always result in one fixture, but it's possible that
  teams could play each other multiple times at the same venue in the
  same season, because of:

    * Domestic cup competitions;
    * Continental cup competitions;
    * Leagues with splits like the SPL;

  This is solved by passing an arrayref of competition IDs as C<COMPS>,
  which are the set of competition IDs that fixtures are allowed to be
  from.

  Returns the database ID of the fixture.

  This would be a lot simpler if we stored date info with fixtures, but
  currently we don't...

=cut

sub find_fixture_from_understat_data($self, $understat_data, $comps) {
    my $season = $understat_data->{season};
    my $home_team_ids =
        $self->teams->find_from_name($understat_data->{h_team});
    my $away_team_ids =
        $self->teams->find_from_name($understat_data->{a_team});

    my $away_comps = {};
    foreach my $id (@$away_team_ids) {
        $away_comps->{$id} = $self->teams->get_comps_for_season($id, $season);
    }

    my $matching_comp_id;
    my $matching_home_id;
    my $matching_away_id;
    OUTER: foreach my $id (@$home_team_ids) {
        my $home_comp_ids = $self->teams->get_comps_for_season($id, $season);
        my @matching_comps = intersect(@$home_comp_ids, @$comps);

        next if scalar @matching_comps == 0;

        my $home_comp_id = $matching_comps[0];

        foreach my $a_id (keys %$away_comps) {
            my $away_comp_ids = $away_comps->{$a_id};

            if (any { $_ == $home_comp_id } @$away_comp_ids) {
                $matching_comp_id = $home_comp_id;
                $matching_home_id = $id;
                $matching_away_id = $a_id;
                last OUTER;
            }
        }
    }

    if (!defined $matching_comp_id) {
        my $home = $understat_data->{h_team};
        my $away = $understat_data->{a_team};
        die "No competition ID found! $home - $away - $season";
    }

    my $fixture = $self->get_or_insert(
        $matching_comp_id, $matching_home_id, $matching_away_id, $season, {});
    return $fixture->{id};
}

=item get_or_insert ( COMP_ID, HOME_ID, AWAY_ID, SEASON, MATCH_INFO )

  Fetch the fixture associated with the given C<COMP_ID>, C<HOME_ID>,
  C<AWAY_ID> and C<SEASON>. C<COMP_ID> is the mandyville database
  competition ID, C<HOME_ID> and C<AWAY_ID> are both mandyville
  database team IDs. C<SEASON> is the starting year of the season.
  C<MATCH_INFO> is a hashref used for insertion, which can contain
  the C<winning_team_id>, C<home_team_goals> and C<away_team_goals>
  attributes. The C<winning_team_id> is optional, because sometimes
  football matches don't have winners. Returns a hashref of the
  fetched or inserted fixture data.

=cut

sub get_or_insert($self, $comp_id, $home_id, $away_id, $season, $match_info) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(id winning_team_id home_team_goals away_team_goals) ],
        -from    => 'fixtures',
        -where   => {
            competition_id => $comp_id,
            home_team_id   => $home_id,
            away_team_id   => $away_id,
            season         => $season,
        }
    );

    my ($id, $win, $h_goals, $a_goals) =
        $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        for (qw(home_team_goals away_team_goals)) {
            croak "missing $_ attribute in match_info param"
                unless defined $match_info->{$_};
        }

        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'fixtures',
            -values    => {
                competition_id  => $comp_id,
                home_team_id    => $home_id,
                away_team_id    => $away_id,
                season          => $season,
                winning_team_id => $match_info->{winning_team_id},
                home_team_goals => $match_info->{home_team_goals},
                away_team_goals => $match_info->{away_team_goals},
            },
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return {
        id              => $id,
        comp_id         => $comp_id,
        home_team_id    => $home_id,
        away_team_id    => $away_id,
        season          => $season,
        winning_team_id => $match_info->{winning_team_id},
        home_team_goals => $match_info->{home_team_goals},
        away_team_goals => $match_info->{away_team_goals},
    };
}

=item process_fixture_data ( FIXTURE_DATA )

  Process the data for a fixture (called a 'match' in the football-data
  API), inserting the teams and fixture data where necessary. Doesn't
  insert any competition data.The C<FIXTURE_DATA> paramater should be
  a hashref in the same format as the JSON shown in
  football-data.org/documentation/api#match - the C<season>,
  C<homeTeam>, C<awayTeam>, C<competition> and C<score> fields are all
  required.

=cut

sub process_fixture_data($self, $fixture_data) {
    for (qw(season homeTeam awayTeam competition score)) {
        croak "missing $_ attribute in fixture_data param"
            unless defined $fixture_data->{$_};
    }

    my $comp_id = $fixture_data->{competition}->{id};
    my $comp_data = $self->comps->get_by_football_data_id($comp_id);

    die "Unknown competition #$comp_id" unless defined $comp_data;

    my $home_team = $fixture_data->{homeTeam};
    my $away_team = $fixture_data->{awayTeam};

    my $home = $self->teams->get_or_insert(
        $home_team->{name}, $home_team->{id}
    );

    my $away = $self->teams->get_or_insert(
        $away_team->{name}, $away_team->{id}
    );

    my $season = $self->_calculate_season($fixture_data->{season});

    $self->teams->get_or_insert_team_comp(
        $home->{id}, $season, $comp_data->{id}
    );

    $self->teams->get_or_insert_team_comp(
        $away->{id}, $season, $comp_data->{id}
    );

    my $score = $fixture_data->{score}->{fullTime};
    my $match_info = {
        home_team_goals => $score->{homeTeam},
        away_team_goals => $score->{awayTeam},
    };

    die "Missing match result data" unless defined $score->{homeTeam};

    if ($score->{homeTeam} > $score->{awayTeam}) {
        $match_info->{winning_team_id} = $home->{id};
    } elsif ($score->{awayTeam} > $score->{homeTeam}) {
        $match_info->{winning_team_id} = $away->{id};
    }

    return $self->get_or_insert(
        $comp_data->{id}, $home->{id}, $away->{id}, $season, $match_info
    );
}

sub _calculate_season($self, $season_info) {
    my $start = $season_info->{startDate};
    my ($year) = $start =~ /^(\d{4})/;
    return $year;
}

=back

=cut

1;
