package Mandyville::Competitions;

use Mojo::Base -base, -signatures;

use Mandyville::API::FootballData;
use Mandyville::Countries;
use Mandyville::Database;

use Carp;
use SQL::Abstract::More;

=head1 NAME

  Mandyville::Competitions - fetch and store competition data

=head1 SYNOPSIS

  use Mandyville::Competitions;
  my $api  = Mandyville::API::FootballData->new;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;
  my $countries = Mandyville::Countries->new({
      dbh  => $dbh->rw_db_handle(),
      sqla => $sqla,
  });

  my $comp = Mandyville::Competitions->new({
      api       => $api,
      countries => $countries,
      dbh       => $dbh,
      sqla      => $sqla,
  });
  $comp->get_competition_data;

=head1 DESCRIPTION

  This module provides methods for fetching and and storing competition
  data. Currently this is done using the football-data API.

=head1 METHODS

=over

=item api

  An instance of Mandyville::API::FootballData.

=item countries

  An instance of Mandyville::Countries.

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

  Creates a new instance of the module, and sets the various required
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

    * api       => An instance of Mandyville::API::FootballData
    * countries => An instance of Mandyville::Countries
    * dbh       => A read-write handle to the Mandyville database
    * sqla      => An instance of SQL::Abstract::More

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
        my $football_data_id = $comp->{id};
        my $football_data_plan = $self->_plan_name_to_number($comp->{plan});
        my $country_id = $self->countries->get_country_id($country_name);

        if (!defined $country_id) {
            my $alternate_id =
                $self->countries->get_id_for_alternate_name($country_name);

            if (!defined $alternate_id) {
                warn "Skipping unknown country $country_name\n";
                next;
            } else {
                $country_id = $alternate_id;
            }
        }

        my $comp_name = $comp->{name};
        my $comp_data = $self->get_or_insert(
            $comp_name, $country_id, $football_data_id, $football_data_plan
        );

        push @$data, $comp_data;
    }
    return $data;
}

=item get_by_football_data_id ( FOOTBAL_DATA_ID )

  Get the competition associated with the given C<FOOTBAL_DATA_ID>. Returns
  undef if no competition is found. Returns a hashref of the competition
  data with the C<name>, C<id>, C<country_name>, C<football_data_id> and
  C<football_data_plan> attributes.

=cut

sub get_by_football_data_id($self, $football_data_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(cp.id cp.name ct.name|country_name
                         cp.football_data_plan) ],
        -from    => [ -join => qw(
            competitions|cp <=>{cp.country_id=ct.id} countries|ct
        )],
        -where   => {
            'cp.football_data_id' => $football_data_id
        }
    );

    my ($id, $name, $country_name, $plan) = $self->dbh->selectrow_array(
        $stmt, undef, @bind
    );

    return unless defined $id;

    return {
        id                 => $id,
        name               => $name,
        country_name       => $country_name,
        football_data_id   => $football_data_id,
        football_data_plan => $plan,
    };
}

=item get_by_plan ( PLAN )

  Get all competitions at the given football-data C<PLAN> tier. Returns an
  arrayref of hashes, each member of which represents a competition.

=cut

sub get_by_plan($self, $plan) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(id football_data_id country_id) ],
        -from    => 'competitions',
        -where   => {
            'football_data_plan' => $plan,
        }
    );

    my $comps = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);
    return $comps;
}

=item get_or_insert ( NAME, COUNTRY_ID, FOOTBAL_DATA_ID, FOOTBALL_DATA_PLAN )

  Fetch the competition associated with C<NAME> and C<COUNTRY_ID>. If the
  competition doesn't exist, insert it into the database. Returns a hashref
  of the competition data that was either fetched or inserted, with the 
  C<name>, C<id>, C<country_name>, C<football_data_id> and
  C<football_data_plan> attributes.

=cut

sub get_or_insert(
    $self, $name, $country_id, $football_data_id, $football_data_plan) {

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
                name               => $name,
                country_id         => $country_id,
                football_data_id   => $football_data_id,
                football_data_plan => $football_data_plan,
            },
            -returning => 'id',
        );

        # This looks unusual but because the insert statement returns an
        # ID, you actually need to use a DBI method that returns data,
        # and you can't just use do() like one normally would in this
        # situation
        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        $country = $self->countries->get_country_name($country_id);
    }

    return {
        id                 => $id,
        name               => $name,
        country_name       => $country,
        football_data_id   => $football_data_id,
        football_data_plan => $football_data_plan,
    };
}

=back

=cut

sub _plan_name_to_number($self, $plan_name) {
    return 1 if $plan_name eq 'TIER_ONE';
    return 2 if $plan_name eq 'TIER_TWO';
    return 3 if $plan_name eq 'TIER_THREE';
    return 4 if $plan_name eq 'TIER_FOUR';

    croak "Invalid plan name $plan_name";
}

1;
