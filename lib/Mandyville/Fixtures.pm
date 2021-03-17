package Mandyville::Fixtures;

use Mojo::Base -base, -signatures;

use Mandyville::Database;
use Mandyville::Teams;

use Carp;
use SQL::Abstract::More;

=head1 NAME

  Mandyville::Fixtures - fetch and store fixture data

=head1 SYNOPSIS

  use Mandyville::Fixtures;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;
  my $teams = Mandyville::Teams->new({
      dbh  => $dbh,
      sqla => $sqla,
  });
  my $fixtures = Mandyville::Fixtures->new({
      dbh   => $dbh,
      sqla  => $sqla,
      teams => $teams,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing fixture data.
  It primarly uses match data from the football-data API to achieve
  this.

=head1 METHODS

=over

=item dbh

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=item teams

  An instance of Mandyville::Teams.

=cut

has 'dbh'   => sub { shift->{dbh} };
has 'sqla'  => sub { shift->{sqla} };
has 'teams' => sub { shift->{teams} };

=item new ([ OPTIONS ])

  Creates a new instance of the module, and sets the various required
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

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

    my $self = {
        dbh   => $options->{dbh},
        sqla  => $options->{sqla},
        teams => $options->{teams},
    };

    bless $self, $class;
    return $self;
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

=back

=cut

1;
