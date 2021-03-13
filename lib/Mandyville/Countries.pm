package Mandyville::Countries;

use Mojo::Base -base, -signatures;

use Mandyville::Database;

use Carp;
use SQL::Abstract::More;

=head1 NAME

  Mandyville::Countries - manage country data

=head1 SYNOPSIS

  use Mandyville::Countries;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;
  my $country = Mandyville::Countries->new({
      dbh  => $dbh,
      sqla => $sqla,
  });
  my $name = 'Argentina';
  $country->get_country_id($name);

=head1 DESCRIPTION

  This module provides methods for managing country data in the mandyville
  database.

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

  Creates a new instance of the module, and sets the C<dbh> and C<slqa>
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

=item get_country_id ( NAME )

  Get the ID associated with the country with the name C<NAME>. Returns
  undef if no country ID is found. Dies if C<NAME> is not provided.

=cut

sub get_country_id($self, $name) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => qw(id),
        -from    => 'countries',
        -where   => { name => $name },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return $id;
}

=item get_country_name ( ID )

  Get the name associated with the country with the ID C<ID>. Returns
  undef if no country ID matches. Dies if C<ID> is not provided.

=cut

sub get_country_name($self, $id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => qw(name),
        -from    => 'countries',
        -where   => { id => $id },
    );

    my ($name) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return $name;
}

=back

=cut

1;

