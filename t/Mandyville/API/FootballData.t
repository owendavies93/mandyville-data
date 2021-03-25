#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mojo::JSON qw(decode_json encode_json);
use Mojo::Message::Response;
use Overload::FileCheck qw(mock_file_check unmock_file_check);
use Test::Exception;
use Test::MockModule;
use Test::MockObject::Extends;
use Test::MockSleep;
use Test::More;
use Test::Warn;

######
# TEST includes/requires
######

use_ok 'Mandyville::API::FootballData';
require_ok 'Mandyville::API::FootballData';

use Mandyville::API::FootballData;

######
# TEST new
######

{
    ok( Mandyville::API::FootballData->new, 'new: initialises okay' );

    my $mock = Test::MockModule->new('Mandyville::API::FootballData');
    $mock->mock(config => { test => 1 });

    dies_ok { Mandyville::API::FootballData->new->conf }
            'new: dies without correct config';
}

######
# TEST _get
######

{
    my $path = 'test';
    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );

    my $call_count = 0;

    $mock_ua->mock( 'get', sub {
        $call_count++;
        return _get_tx({ called => 1 })
    });

    my $api = Mandyville::API::FootballData->new;
    $api->ua($mock_ua);
    my $response = $api->get($path);

    cmp_ok( $response->{called}, '==', 1, '_get: response matches' );

    cmp_ok( $call_count, '==', 1, '_get: mocked UA was correctly called' );

    $api->get($path);

    cmp_ok( $call_count, '==', 1, '_get: UA not called for same path' );

    unlink $api->cache->{$path};
    $api->get($path);

    cmp_ok( $call_count, '==', 2, '_get: UA called if cache not found' );

    mock_file_check( '-M' => sub { 61 / 24 / 60 } );

    $api->get($path);

    cmp_ok( $call_count, '==', 3, '_get: UA called after cache expiry' );

    unmock_file_check('-M');

    # Test rate limiting
    # turn off caching to do this

    mock_file_check( '-f' => sub { 0 } );

    warning_like {
        for (1..28) { $api->get($path) };
    } qr/hit rate limit: sleeping/, '_get: correct rate limit warning';

    cmp_ok( slept(), '>', 59,
            '_get: rate limiting caused sleep for over 59 seconds' );

    unmock_file_check('-f');
}

######
# TEST competitions
######

{
    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            count => 1,
            competitions => [{
                id   => 1,
                name => 'Premier League',
            }]
        })
    });

    my $api = Mandyville::API::FootballData->new;
    $api->ua($mock_ua);
    my $response = $api->competitions;

    cmp_ok( $response->{count}, '==', 1, 'competitions: correct count' );

    my $name = $response->{competitions}->[0]->{name};

    cmp_ok( $name, 'eq', 'Premier League', 'competitions: correct count' );
}

######
# TEST competition_season_matches
######

{
    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );

    my $message = 'Problem Problem!';
    $mock_ua->mock( 'get', sub {
        return _get_tx({
            error   => 404,
            message => $message,
        });
    });

    my $api = Mandyville::API::FootballData->new;
    $api->ua($mock_ua);

    dies_ok { $api->competition_season_matches() }
              'competition_season_matches: dies without args';

    throws_ok { $api->competition_season_matches(10, 300) } qr/Not found/,
                'competition_season_matches: croaks on 404';

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            errorCode => 403,
            message   => $message,
        });
    });

    throws_ok { $api->competition_season_matches(20, 300) } qr/Restricted/,
                'competition_season_matches: croaks on 403';

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            error   => 503,
            message => $message,
        });
    });

    throws_ok { $api->competition_season_matches(20, 400) } qr/Unknown error/,
                'competition_season_matches: dies on unknown error';

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            errorCode => 503,
            message   => $message,
        });
    });

    throws_ok { $api->competition_season_matches(25, 400) } qr/Unknown error/,
                'competition_season_matches: dies on unknown errorCode';

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            match => {
                id => 1,
            }
        });
    });

    my $data = $api->competition_season_matches(30, 400);

    ok( $data->{match}, 'competition_season_matches: data returned' );
}

######
# TEST player
######

{
    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );

    my $message = 'Problem Problem!';
    $mock_ua->mock( 'get', sub {
        return _get_tx({
            error   => 404,
            message => $message,
        });
    });

    my $api = Mandyville::API::FootballData->new;
    $api->ua($mock_ua);

    dies_ok { $api->player() } 'player: dies without args';

    throws_ok { $api->player(10) } qr/Not found/, 'player: croaks on 404';

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            error   => 503,
            message => $message,
        });
    });

    throws_ok { $api->player(15) } qr/Unknown/, 'player: dies on unkown error';

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            errorCode => 404,
            message   => $message,
        });
    });

    throws_ok { $api->player(20) } qr/Unknown/, 'player: dies on unkown error';

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            errorCode => 429,
            message   => 'You reached your request limit. Wait 60 seconds.',
        });
    });

    warning_is { $api->player(25) } "hit rate limit from API: sleeping 60\n",
                 'player: correctly warns on 429 error';

    cmp_ok( slept(), '==', 60, 'player: slept for correct time' );

    $mock_ua->mock( 'get', sub {
        return _get_tx({
            id         => 44,
            first_name => 'Owen',
            last_name  => 'Davies',
        });
    });

    my $data = $api->player(30);

    ok( $data->{first_name}, 'player: data returned' );
}

sub _get_tx($body) {
    my $mock_tx = Test::MockObject::Extends->new( 'Mojo::Transaction::HTTP' );

    $mock_tx->mock( 'res', sub {
        my $res = Mojo::Message::Response->new;
        $res->parse("HTTP/1.0 200 OK\x0d\x0a");
        $res->parse("Content-Type: text/plain\x0d\x0a\x0d\x0a");
        $res->parse(encode_json($body));
        return $res;
    });

    return $mock_tx;
}

done_testing;

