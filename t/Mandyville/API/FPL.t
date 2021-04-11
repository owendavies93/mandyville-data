#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
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

