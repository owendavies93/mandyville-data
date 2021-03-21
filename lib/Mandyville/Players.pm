package Mandyville::Players;

use Mojo::Base -base, -signatures;

use Mandyville::Countries;
use Mandyville::Database;

use Carp;
use SQL::Abstract::More;

=head1 NAME

  Mandyville::Players - fetch and store player data

=head1 SYNOPSIS

  use Mandyville::Players;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $players = Mandyville::Players->new({
      countries => Mandyville::Countries->new,
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

=item countries

  An instance of Mandyville::Countries.

=item dbh 

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=cut

has 'countries' => sub { shift->{countries} };
has 'dbh'       => sub { shift->{dbh} };
has 'sqla'      => sub { shift->{sqla} };

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

    $options->{countries} //= Mandyville::Countries->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    my $self = {
        countries => $options->{countries},
        dbh       => $options->{dbh},
        sqla      => $options->{sqla},
    };

    bless $self, $class;
    return $self;
}

=item get_or_insert ( FOOTBALL_DATA_ID, PLAYER_INFO )

  Fetch the player associated with the given C<FOOTBALL_DATA_ID>. If no
  such player is found, insert the player into the database using the
  fields provided in C<PLAYER_INFO>. The C<first_name>, C<last_name>
  and C<country_name> attributes are required for insertion. The
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

        die "No country with name $country_name found"
            unless defined $country_id;

        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'players',
            -values    => {
                first_name       => $player_info->{first_name},
                last_name        => $player_info->{last_name},
                country_id       => $country_id,
                football_data_id => $football_data_id,
            },
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return {
        id           => $id,
        first_name   => $player_info->{first_name},
        last_name    => $player_info->{last_name},
        country_name => $player_info->{country_name},
    };
}

=back

=cut

1;
