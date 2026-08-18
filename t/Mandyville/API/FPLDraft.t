#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::API::FPLDraft;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use Test::Exception;
use Test::MockObject;
use Test::MockObject::Extends;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::API::FPLDraft';
require_ok 'Mandyville::API::FPLDraft';

sub _fixture($name) {
    return Mojo::File->new(find_file("t/data/$name.json"))->slurp;
}

sub _mocked_api {
    my $api = Test::MockObject::Extends->new(
        Mandyville::API::FPLDraft->new
    );

    my %fixtures = (
        'bootstrap-static'               => _fixture('fpl-draft-bootstrap'),
        'league/1/details'               => _fixture('fpl-draft-league-details'),
        'league/1/element-status'        => _fixture('fpl-draft-element-status'),
        'draft/1/choices'                => _fixture('fpl-draft-choices'),
        'draft/league/1/transactions'    => _fixture('fpl-draft-transactions'),
        'game'                           => _fixture('fpl-draft-game'),
    );

    $api->mock( '_get', sub {
        my ($self, $path) = @_;
        return $fixtures{$path} // die "unexpected path: $path";
    });

    return $api;
}

######
# TEST cached getters
######

{
    my $api = _mocked_api();

    my $bootstrap = $api->bootstrap;
    is( ref $bootstrap, 'HASH', 'bootstrap: returns a hashref' );

    my $elements = $api->elements;
    is( ref $elements, 'ARRAY', 'elements: returns an arrayref' );
    is( scalar @$elements, 4, 'elements: has all four elements' );

    my $details = $api->league_details(1);
    is( $details->{league}{name}, 'Test Draft', 'league_details: league name' );
    is( scalar @{$details->{league_entries}}, 2, 'league_details: two entries' );

    my $choices = $api->choices(1);
    is( scalar @$choices, 2, 'choices: two picks' );

    my $txns = $api->transactions(1);
    is( scalar @$txns, 1, 'transactions: one transaction' );

    my $game = $api->game;
    is( $game->{next_event}, 2, 'game: next event' );
}

######
# TEST element_status bypasses the cache (uses _get directly)
######

{
    my $api = _mocked_api();

    my $status = $api->element_status(1);
    is( ref $status, 'ARRAY', 'element_status: returns an arrayref' );
    is( scalar @$status, 4, 'element_status: all four elements' );
    is( $status->[0]{element}, 10, 'element_status: first element id' );
}

######
# TEST entry_event
######

sub _entry_event_response($code, $body) {
    my $res = Test::MockObject->new;
    $res->set_always( 'code', $code );
    $res->set_always( 'body', $body );

    my $tx = Test::MockObject->new;
    $tx->set_always( 'res', $res );

    my $ua = Test::MockObject->new;
    $ua->set_always( 'get', $tx );

    return $ua;
}

{
    my $api = Test::MockObject::Extends->new(
        Mandyville::API::FPLDraft->new
    );

    $api->mock( 'ua', sub { _entry_event_response(404, '"No pick history"') } );
    my $result = $api->entry_event(1001, 1);
    is( $result, undef, 'entry_event: returns undef on 404' );

    $api->mock( 'ua', sub {
        _entry_event_response(200, _fixture('fpl-draft-entry-event'))
    });
    $result = $api->entry_event(1001, 1);
    is( ref $result, 'HASH', 'entry_event: returns a hashref on 200' );
    is( scalar @{$result->{picks}}, 2, 'entry_event: parses picks' );

    $api->mock( 'ua', sub { _entry_event_response(500, 'boom') } );
    throws_ok { $api->entry_event(1001, 1) } qr/returned 500/,
                'entry_event: dies on server error';
}

done_testing();
