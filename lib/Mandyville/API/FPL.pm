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

=item player_history ( ID )

  Fetch the FPL game history for a given player. C<ID> should be the
  ID of the player in the current season of the game, not the 'code'
  number.

  Dies if the player history is not found.

=cut

sub player_history($self, $id) {
    my $elem_summary = $self->get("element-summary/$id/");

    if (!defined $elem_summary->{history}) {
        if (defined $elem_summary->{detail} && $elem_summary->{detail} =~ /Not found/) {
            die "Player history for $id not found";
        } else {
            die "Unknown error from FPL API player_history";
        }
    }

    return $elem_summary->{history};
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
