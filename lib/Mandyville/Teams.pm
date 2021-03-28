package Mandyville::Teams;

use Mojo::Base -base, -signatures;

use Mandyville::Database;
use Mandyville::Countries;

use SQL::Abstract::More;

=head1 NAME

  Mandyville::Teams - fetch and store team data

=head1 SYNOPSIS

  use Mandyville::Teams;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;
  my $teams = Mandyville::Teams->new({
      dbh  => $dbh,
      sqla => $sqla,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing team
  data. It primarily uses match data from the football-data
  API to achieve this.

=head1 METHODS

=over

=item dbh 

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=cut

has 'dbh'  => sub { shift->{dbh} };
has 'sqla' => sub { shift->{sqla} };

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
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    my $self = {
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    };

    bless $self, $class;
    return $self;
}

=item find_from_name ( NAME )

  Attemps to find the team based on the provided C<NAME>. Returns all
  team IDs that contain C<NAME>.

=cut

sub find_from_name($self, $name) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'teams',
        -where   => {
            'name' => { like => "%$name%" }
        }
    );

    my $team_ids = $self->dbh->selectcol_arrayref($stmt, undef, @bind);
    return $team_ids;
}

=item get_or_insert ( NAME, FOOTBAL_DATA_ID )

  Fetch the team assoicated with the C<NAME> and C<FOOTBAL_DATA_ID>.
  If the team isn't found, the team is inserted into the database.
  Returns a hashref of the team data that was either fetched or
  inserted, with the C<name>, C<id> and C<football_data_id> attributes.

=cut

sub get_or_insert($self, $name, $football_data_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'teams',
        -where   => {
            'football_data_id' => $football_data_id,
            'name'             => $name,
        }
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'teams',
            -values    => {
                'football_data_id' => $football_data_id,
                'name'             => $name,
            },
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return {
        id               => $id,
        name             => $name,
        football_data_id => $football_data_id,
    };
}

=item get_or_insert_team_comp ( TEAM_ID, SEASON, COMP_ID )

  Fetch the team's season assoicated with the given C<TEAM_ID>,
  C<SEASON> and C<COMP_ID>. C<COMP_ID> is the mandyville database
  competition ID, C<TEAM_ID> is the mandyville database team ID,
  C<SEASON> is the starting year of the season. If the team's season
  isn't found, it's inserted into the database. Returns a hashref of
  the team's season data that was either fetched or inserted, wth the 
  C<id>, C<team_id>, C<season> and C<competition_id> attributes.

=cut

sub get_or_insert_team_comp($self, $team_id, $season, $comp_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'teams_competitions',
        -where   => {
            'competition_id' => $comp_id,
            'season'         => $season,
            'team_id'        => $team_id,
        }
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        ($stmt, @bind) = $self->sqla->insert(
            -into   => 'teams_competitions',
            -values => {
                'competition_id' => $comp_id,
                'season'         => $season,
                'team_id'        => $team_id,
            },
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return {
        id      => $id,
        team_id => $team_id,
        season  => $season,
        comp_id => $comp_id,
    };
}

=back

=cut

1;

