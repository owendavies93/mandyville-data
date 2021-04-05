package Mandyville::API::FPL;

use Mojo::Base 'Mandyville::API', -signatures;

use Const::Fast;

=head1 NAME
  
  Mandyville::API::FPL - interact with the FPL API

=head1 SYNOPSIS

  use Mandyville::API::FPL;
  my $api = Mandyville::API::FPL->new;

=head1 DESCRIPTION

  This module provides methods for fetching and parsing information
  from the Fantasy Premier League API.

=cut

const my $BASE_URL => 'https://fantasy.premierleague.com/api/';

=head1 METHODS

=over

=item gameweeks

  Fetch the gameweek information for the current season.

=cut

sub gameweeks($self) {
    my $bootstrap = $self->get('bootstrap-static/');
    return $bootstrap->{events};
}

=item players

  Fetch the players in the game for the current season.

=cut

sub players($self) {
    my $bootstrap = $self->get('bootstrap-static/');
    return $bootstrap->{elements};
}

=back

=cut

sub _get($self, $path) {
    return $self->ua->get($BASE_URL . $path)->res->body;
}

sub _rate_limit($self) {
    return 1;
}

1;
