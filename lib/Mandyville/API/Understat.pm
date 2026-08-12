package Mandyville::API::Understat;

use Mojo::Base 'Mandyville::API', -signatures;

use Const::Fast;

=head1 NAME

  Mandyville::API::Understat - interact with the understat.com

=head1 SYNOPSIS

  use Mandyville::API::Understat;
  my $api = Mandyville::API::Understat->new;

=head1 DESCRIPTION

  This module provides methods for fetching and parsing information
  from understat.com. Since understat doesn't have an API, we parse
  the JSON returned in the pages.

=cut

const my $BASE_URL => "https://understat.com/";
const my $XHR_HEADER => { 'X-Requested-With' => 'XMLHttpRequest' };

=head1 METHODS

=over

=item player ( ID )

  Returns the understat match history for the player represented by
  C<ID>, where C<ID> is the understat ID of the player, not the
  mandyville database ID.

=cut

sub player($self, $id) {
    return $self->get("getPlayerData/$id", $XHR_HEADER)->{matches};
}

=item match ( ID )

  Returns the understat data for the fixture represented by C<ID>.
  C<ID> is the understat match ID, not the mandyville database fixture
  ID.

  Note: the old match page endpoint no longer exists. This method is
  deprecated and will die if called. Use league team history data
  instead.

=cut

sub match($self, $id) {
    die "Understat match endpoint no longer available. " .
        "Use league team history data instead.";
}

=item search ( NAME )

  Searches for a player with the given C<NAME>. Name should be the
  full name of the player to get the most accurate reuslts, but
  partial searches will work as well.

  Returns an arrayref of matching results. Dies if a success key
  isn't returned from the API.

=cut

sub search($self, $name) {
    $name =~ s/'//g;
    my $response = $self->get(
        'main/getPlayersName/' . $name, $XHR_HEADER
    );

    return $response->{response}->{players}
        if defined $response->{response}->{success};

    die "Unknown error from understat: search for $name";
}

=back

=cut

sub _get($self, $path, $headers={}) {
    return $self->ua->get($BASE_URL . $path => $headers)->res->body;
}

sub _rate_limit($self) {
    return 1;
}

1;

