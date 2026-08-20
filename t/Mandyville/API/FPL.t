#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use Mojo::Message::Response;
use Test::Exception;
use Test::MockObject::Extends;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::API::FPL';
require_ok 'Mandyville::API::FPL';

use Mandyville::API::FPL;

######
# TEST gameweeks
######

{
    my $api = Mandyville::API::FPL->new;

    my $json = Mojo::File->new(find_file('t/data/events.json'))->slurp;
    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    $mock_ua->mock( 'get', sub {
        return $api->_get_tx(decode_json($json));
    });

    $api->ua($mock_ua);

    my $gameweeks = $api->gameweeks;

    cmp_ok( scalar @$gameweeks, '==', 38, 'gameweeks: correct gameweeks' );
}

######
# TEST player_history
######

{
    my $api = Mandyville::API::FPL->new;

    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );

    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({
            detail => 'Not found.',
        });
    });

    $api->ua($mock_ua);

    dies_ok { $api->player_history } 'player_history: dies without args';

    throws_ok { $api->player_history(1) } qr/not found/,
                'player_history: dies with not found error';

    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({});
    });

    throws_ok { $api->player_history(2) } qr/Unknown error/,
                'player_history: dies with unknown error';

    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({
            history => [{
                element       => 4,
                fixture       => 2,
                opponent_team => 8,
            }]
        });
    });

    my $history = $api->player_history(3);

    cmp_ok( scalar @$history, '==', 1, 'player_history: returns history' );
}

######
# TEST entry, entry_history, entry_transfers and entry_picks
######

{
    my $api = Mandyville::API::FPL->new;

    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({ id => 123456, name => 'Test FC' });
    });

    $api->ua($mock_ua);

    is( $api->entry(123456)->{name}, 'Test FC', 'entry: returns profile' );

    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({ current => [], past => [], chips => [] });
    });

    is( ref $api->entry_history(123456)->{current}, 'ARRAY',
        'entry_history: returns history' );

    $mock_ua->mock( 'get', sub {
        return $api->_get_tx([]);
    });

    is( ref $api->entry_transfers(123456), 'ARRAY',
        'entry_transfers: returns transfers' );
}

{
    my $api = Mandyville::API::FPL->new;

    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );

    # entry_picks goes straight to the user agent, returning undef on 404.
    my $mock_res = Mojo::Message::Response->new;
    $mock_res->parse("HTTP/1.0 404 Not Found\x0d\x0a");

    my $mock_tx = Test::MockObject::Extends->new( 'Mojo::Transaction::HTTP' );
    $mock_tx->mock( 'res', sub { $mock_res });

    $mock_ua->mock( 'get', sub { return $mock_tx; });
    $api->ua($mock_ua);

    is( $api->entry_picks(123456, 1), undef,
        'entry_picks: returns undef for a 404' );

    my $mock_res_ok = Mojo::Message::Response->new;
    $mock_res_ok->parse("HTTP/1.0 200 OK\x0d\x0a\x0d\x0a");
    $mock_res_ok->parse('{"picks":[{"element":1}]}');

    $mock_tx->mock( 'res', sub { $mock_res_ok; });

    my $picks = $api->entry_picks(123456, 2);
    is( scalar @{$picks->{picks}}, 1, 'entry_picks: returns picks' );
}

######
# TEST players
######

{
    my $api = Mandyville::API::FPL->new;
    my $json = Mojo::File->new(find_file('t/data/elements.json'))->slurp;
    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    $mock_ua->mock( 'get', sub {
        return $api->_get_tx(decode_json($json));
    });

    $api->ua($mock_ua);

    my $players = $api->players;

    cmp_ok( scalar @$players, '==', 2, 'players, correct players' );
}

done_testing();

