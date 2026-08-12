package Mandyville::API::Understat;

use Mojo::Base 'Mandyville::API', -signatures;

use Const::Fast;
use Mojo::DOM;

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

=cut

sub match($self, $id) {
    return $self->get("match/$id");
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
    my $body = $self->ua->get($BASE_URL . $path => $headers)->res->body;

    return _parse_single_match_info($body) if $path =~ /^match\//;

    return $body;
}

sub _extract_JSON_from_text($text) {
    $text =~ s/^.*JSON\.parse\('//s;
    $text =~ s/'\);\s*$//s;
    $text =~ s/\\\\x(\w{2})/chr(hex($1))/eg;
    $text =~ s/\\x(\w{2})/chr(hex($1))/eg;

    return $text;
}

sub _parse_single_match_info($body) {
    my $scripts = Mojo::DOM->new->parse($body)->find('script');

    foreach my $script (@$scripts) {
        my $text = $script->text // '';
        next unless $text =~ /match_info\s*=\s*JSON\.parse/;
        return _extract_JSON_from_text($text);
    }

    die "No match info found in script tag";
}

sub _rate_limit($self) {
    return 1;
}

1;

