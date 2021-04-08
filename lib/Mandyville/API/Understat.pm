package Mandyville::API::Understat;

use Mojo::Base 'Mandyville::API', -signatures;

use Const::Fast;
use Mojo::DOM;
use Mojo::JSON qw(decode_json);

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
const my $PARSERS  => {
    'main/getPlayersName' => sub { return $_[1] },
    'player'              => \&_parse_match_info,
    'match'               => \&_parse_single_match_info,
};

=head1 METHODS

=over

=item dom

  An instance of Mojo::DOM

=cut

has 'dom' => sub { Mojo::DOM->new };

=item player ( ID )

  Returns the understat match history for the player represented by
  C<ID>, where C<ID> is the understat ID of the player, not the
  mandyville database ID.

=cut

sub player($self, $id) {
    return $self->get("player/$id");
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
    my $response = $self->get('main/getPlayersName/' . $name);

    return $response->{response}->{players}
        if defined $response->{response}->{success};

    die "Unknown error from understat: search for $name";
}

=back

=cut

sub _extract_JSON_from_text($text) {
    # Strip everything away except the JSON string and attempt to parse it
    # Convert the hex escape sequences to their ASCII versions
    $text =~ s/'\);//g;
    $text =~ s/\\\\x(\w{2})/chr(hex($1))/eg;
    $text =~ s/\\x(\w{2})/chr(hex($1))/eg;

    return $text;
}

sub _get($self, $path) {
    my $body = $self->ua->get($BASE_URL . $path)->res->body;

    $path =~ s/\/[^\/]+(?:\/?)$//;

    return $PARSERS->{$path}->($self, $body);
}

sub _parse_match_info($self, $body) {
    my $match_info = $self->dom->parse($body)->find('script')->[4]->text;
    $match_info =~ /matchesData/ or die "No match data found in script tag";
    $match_info =~ s/var matchesData\s*=\s*JSON.parse\('//;

    return _extract_JSON_from_text($match_info);
}

sub _parse_single_match_info($self, $body) {
    my $script = $self->dom->parse($body)->find('script')->[1]->text;
    $script =~ /match_info/ or die "No match info found in script tag";
    $script =~ s/.*match_info\s*=\s*JSON.parse\('//g;

    return _extract_JSON_from_text($script);
}

sub _rate_limit($self) {
    return 1;
}

1;

