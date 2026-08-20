package Mandyville::API::FPLDraft;

use Mojo::Base 'Mandyville::API', -signatures;

use Const::Fast;
use Mojo::JSON qw(decode_json);

=head1 NAME

  Mandyville::API::FPLDraft - interact with the FPL Draft API

=head1 SYNOPSIS

  use Mandyville::API::FPLDraft;
  my $api = Mandyville::API::FPLDraft->new;

=head1 DESCRIPTION

  This module provides methods for fetching information from the
  Fantasy Premier League Draft API. Unlike the main FPL API, the draft
  API is entirely public and requires no authentication. Responses are
  cached for a short time only, since a lot of the data (ownership,
  waiver order, current gameweek state) changes rapidly.

=cut

const my $BASE_URL => 'https://draft.premierleague.com/api/';
const my $EXPIRY   => 5 / 24 / 60; # 5 minutes in days

has 'expiry' => sub { $EXPIRY };

=head1 METHODS

=over

=item bootstrap

  Fetch the full bootstrap-static payload, including C<elements>,
  C<teams>, C<events> and the scoring C<settings>.

=cut

sub bootstrap($self) {
    return $self->get('bootstrap-static');
}

=item elements

  Fetch the elements from bootstrap-static.

=cut

sub elements($self) {
    return $self->bootstrap->{elements};
}

=item events

  Fetch the events (gameweeks) from bootstrap-static, including their
  C<deadline_time>, C<waivers_time> and C<trades_time>.

=cut

sub events($self) {
    return $self->bootstrap->{events};
}

=item league_details ( LEAGUE_ID )

  Fetch the details for a draft league, including league configuration,
  league entries (with their current waiver picks), fixtures (C<matches>)
  and C<standings>.

=cut

sub league_details($self, $league_id) {
    return $self->get("league/$league_id/details");
}

=item element_status ( LEAGUE_ID )

  Fetch the ownership status of every element in the game, indicating
  which league entry (if any) currently owns each player. The C<owner>
  field is the global entry id, and is C<undef> for free agents.

  This endpoint changes constantly (free agents are first-come
  first-served), so it bypasses the cache.

=cut

sub element_status($self, $league_id) {
    return $self->_get_uncached("league/$league_id/element-status")->{element_status};
}

=item choices ( LEAGUE_ID )

  Fetch the full draft pick history for a league.

=cut

sub choices($self, $league_id) {
    return $self->get("draft/$league_id/choices")->{choices};
}

=item transactions ( LEAGUE_ID )

  Fetch the transaction history (waivers, free agent moves and trades)
  for a league. This bypasses the cache because it changes as soon as a
  free agent move is made.

=cut

sub transactions($self, $league_id) {
    return $self->_get_uncached("draft/league/$league_id/transactions")->{transactions};
}

=item game

  Fetch the current game state, including the current and next
  gameweeks and whether waivers have been processed for the current
  gameweek. This bypasses the cache.

=cut

sub game($self) {
    return $self->_get_uncached('game');
}

=item entry_event ( ENTRY_ID, EVENT_ID )

  Fetch the squad and starting lineup for the given C<ENTRY_ID> (the
  global entry id) in the given C<EVENT_ID> (gameweek). Returns C<undef>
  if the lineup isn't available yet, which is the case before the
  gameweek's deadline.

=cut

sub entry_event($self, $entry_id, $event_id) {
    my $res = $self->ua->get("$BASE_URL/entry/$entry_id/event/$event_id")->res;

    return if $res->code == 404;

    die "FPL Draft API returned " . $res->code . " for entry/$entry_id/event/$event_id"
        if $res->code >= 400;

    return decode_json($res->body);
}

=back

=cut

# Fetch and decode a JSON path without touching the disk cache. Used for
# endpoints whose data goes stale within seconds.
sub _get_uncached($self, $path) {
    my $json = $self->_get($path);
    return decode_json($json);
}

sub _get($self, $path, $headers={}) {
    return $self->ua->get($BASE_URL . $path)->res->body;
}

sub _rate_limit($self) {
    return 1;
}

1;
