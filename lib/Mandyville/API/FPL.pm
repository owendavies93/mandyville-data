package Mandyville::API::FPL;

use Mojo::Base 'Mandyville::API', -signatures;

use Const::Fast;
use Mojo::JSON qw(decode_json);

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

=item entry ( ID )

  Fetch the public profile for the classic FPL entry C<ID>.

=cut

sub entry($self, $id) {
    return $self->get("entry/$id/");
}

=item entry_history ( ID )

  Fetch the season history for the classic FPL entry C<ID>, including
  the per-gameweek C<current> records and the C<chips> played.

=cut

sub entry_history($self, $id) {
    return $self->get("entry/$id/history/");
}

=item entry_transfers ( ID )

  Fetch the transfer history for the classic FPL entry C<ID>. This
  endpoint updates as soon as a transfer is made, unlike the picks.

=cut

sub entry_transfers($self, $id) {
    return $self->get("entry/$id/transfers/");
}

=item entry_picks ( ID, EVENT )

  Fetch the squad and lineup for the classic FPL entry C<ID> in the
  given C<EVENT> (gameweek). Returns C<undef> if the lineup isn't
  available yet, which is the case before the gameweek's deadline.

=cut

sub entry_picks($self, $id, $event) {
    my $res = $self->ua->get("$BASE_URL/entry/$id/event/$event/picks/")->res;

    return if $res->code == 404;

    die "FPL API returned " . $res->code . " for entry/$id/event/$event/picks/"
        if $res->code >= 400;

    return decode_json($res->body);
}

=item players

  Fetch the players in the game for the current season.

=cut

sub players($self) {
    my $bootstrap = $self->get('bootstrap-static/');
    return $bootstrap->{elements};
}

=item teams

  Fetch the teams in the game for the current season.

=cut

sub teams($self) {
    my $bootstrap = $self->get('bootstrap-static/');
    return $bootstrap->{teams};
}

=back

=cut

sub _get($self, $path, $headers={}) {
    return $self->ua->get($BASE_URL . $path)->res->body;
}

sub _rate_limit($self) {
    return 1;
}

1;
