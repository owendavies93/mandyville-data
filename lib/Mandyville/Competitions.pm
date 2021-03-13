package Mandyville::Competitions;

use Mojo::Base -base, -signatures;

use Mandyville::API::FootballData;
use Mandyville::Countries;
use Mandyville::Database;

use SQL::Abstract::More;

=head1 NAME

  Mandyville::Competitions - fetch and store competition data

=head1 SYNOPSIS

  use Mandyville::Competitions;
  my $api  = Mandyville::API::FootballData->new;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;
  my $comp = Mandyville::Competitions->new({
      api  => $api,
      dbh  => $dbh,
      sqla => $sqla,
  });
  $comp->get_competition_data;

=head1 DESCRIPTION

  This module provides methods for fetching and and storing competition
  data. Currently this is done using the football-data API.

=head1 METHODS

=over

=item api

  An instance of Mandyville::API::FootballData.

=item dbh

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=cut

has 'api'       => sub { shift->{api} };
has 'countries' => sub { shift->{countries} };
has 'dbh'       => sub { shift->{dbh} };
has 'sqla'      => sub { shift->{sqla} };

=item new ([ OPTIONS ])

  Creates a new instance of the module, and sets the C<dbh> and C<slqa>
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

    * api  => An instance of Mandyville::API::FootballData
    * dbh  => A read-write handle to the Mandyville database
    * sqla => An instance of SQL::Abstract::More

  If these options aren't passed in, they will be instantied by this
  method. However, it's recommended to pass these options in for 
  performance and memory usage reasons.

=cut

sub new($class, $options) {
    $options->{api}  //= Mandyville::API::FootballData->new;
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    $options->{countries} //= Mandyville::Countries->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    my $self = {
        api       => $options->{api},
        countries => $options->{countries},
        dbh       => $options->{dbh},
        sqla      => $options->{sqla},
    };

    bless $self, $class;
    return $self;
}

=item get_competition_data

  Fetch the data for all known competitions from the football data
  API. Returns an array of hashrefs of this data, with each item in the
  hashref containing the C<name>, C<id> and C<country_name> attributes.
  C<name> and C<id> both refer to the competition.

  Inserts any previously unseen competitions with valid countries into
  the competitions table of the mandyville database.

=cut

sub get_competition_data($self) {
    my $comps = $self->api->competitions;
    my $data = [];
    foreach my $comp (@{$comps->{competitions}}) {
        my $country_name = $comp->{area}->{name};
        my $country_id = $self->countries->get_country_id($country_name);

        if (!defined $country_id) {
            warn "Skipping unknown country $country_name";
            next;
        }

        my $comp_name = $comp->{name};
        my $comp_data = $self->get_or_insert($comp_name, $country_id);
        push @$data, $comp_data;
    }
    return $data;
}

=item get_or_insert( NAME, COUNTRY_ID )

  Fetch the competition associated with C<NAME> and C<COUNTRY_ID>. If the
  competition doesn't exist, insert it into the database. Returns a hashref
  of the competition data that was either fetched or inserted, with the 
  C<name>, C<id> and C<country_name> attributes.

=cut

sub get_or_insert($self, $name, $country_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(cp.id ct.name|country_name) ],
        -from    => [ -join => qw(
            competitions|cp <=>{cp.country_id=ct.id} countries|ct
        )],
        -where   => {
            'cp.name'       => $name,
            'cp.country_id' => $country_id,
        }
    );

    my ($id, $country) = $self->dbh->selectrow_array(
        $stmt, undef, @bind
    );

    if (!defined $id) {
        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'competitions',
            -values    => {
                name       => $name,
                country_id => $country_id,
            },
            -returning => 'id',
        );

        $id = $self->dbh->do($stmt, undef, @bind);

        $country = $self->countries->get_country_name($country_id);
    }

    return {
        id           => $id,
        name         => $name,
        country_name => $country,
    };
}

=back

=cut

1;
