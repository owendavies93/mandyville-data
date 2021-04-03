package Mandyville::Gameweeks;

use Mojo::Base -base, -signatures;

use Mandyville::Database;
use Mandyville::Utils qw(current_season);

use SQL::Abstract::More;

=head1 NAME

  Mandyville::Gameweeks - fetch and store gameweek data

=head1 SYNOPSIS

  use Mandyville::Gameweeks;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $gameweeks = Mandyville::Gameweeks->new({
      api  => Mandyville::API::FPL->new,
      dbh  => $dbh,
      sqla => $sqla,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing gameweek data,
  where a 'gameweek' refers to a set of matches in the Fantasy Premier
  League game. It primarily uses data from the FPL API to achieve this.

=head1 METHODS

=over

=item api

  An instance of Mandyville::API::FPL.

=item dbh

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=cut

has 'api'  => sub { shift->{api} };
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
    $options->{api}  //= Mandyville::API::FPL->new;
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    my $self = {
        api  => $options->{api},
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    };

    bless $self, $class;
    return $self;
}

=item process_gameweeks

  Fetch the gameweek data for the current season from the FPL API, and
  store/update the information in the database.

  Return the number of gameweeks processed.

=cut

sub process_gameweeks($self) {
    my $gameweek_info = $self->api->gameweeks;
    my $season = current_season();
    my $updated = 0;

    foreach my $gw (@$gameweek_info) {
        my $gw_number = $gw->{id};
        my $deadline  = $gw->{deadline_time};

        my ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fpl_gameweeks',
            -where   => {
                gameweek => $gw_number,
                season   => $season,
            }
        );

        my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        if (defined $id) {
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
    }

    return $updated;
}

=back

=cut

1;

