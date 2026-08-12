#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::Message::Response;
use Test::Exception;
use Test::MockObject::Extends;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::API::Understat';
require_ok 'Mandyville::API::Understat';

use Mandyville::API::Understat;

######
# TEST search
######

{
    my $api = Mandyville::API::Understat->new;

    dies_ok { $api->search } 'search: dies without args';

    my $name = 'Mohamed Salah';

    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({
            response => {
                success => 'true',
                players => [{
                    id     => 1250,
                    player => $name,
                    team   => 'Liverpool',
                }]
            }
        })
    });

    $api->ua($mock_ua);
    my $response = $api->search($name);

    cmp_ok( scalar @$response, '==', 1, 'search: correct number of results' );

    cmp_ok( $response->[0]->{player}, 'eq', $name, 'search: correct data' );

    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({
            response => {
                error => 404,
            }
        })
    });

    my $new_name = 'Joe Cole';

    throws_ok { $api->search($new_name) } qr/Unknown error/,
                'search: dies on non-success response';
}

######
# TEST player
######

{
    my $api = Mandyville::API::Understat->new;

    dies_ok { $api->player } 'player: dies without args';

    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    $mock_ua->mock( 'get', sub {
        return $api->_get_tx({
            matches => [{
                id       => 1,
                h_team   => 'Liverpool',
                a_team   => 'Chelsea',
                goals    => 1,
                xG       => '0.85',
                season   => '2023',
            }],
        });
    });

    $api->ua($mock_ua);

    my $matches = $api->player(1);

    cmp_ok( scalar @$matches, '==', 1, 'player: correct matches' );
    cmp_ok( $matches->[0]->{h_team}, 'eq', 'Liverpool',
            'player: correct match data' );
}

######
# TEST match
######

{
    my $api = Mandyville::API::Understat->new;

    dies_ok { $api->match } 'match: dies without args';

    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    my $mock_tx = Test::MockObject::Extends->new( 'Mojo::Transaction::HTTP' );
    $mock_tx->mock( 'res', sub {
        my $res = Mojo::Message::Response->new;
        $res->parse("HTTP/1.0 200 OK\x0d\x0a");
        $res->parse("Content-Type: text/html\x0d\x0a\x0d\x0a");
        $res->parse("<script>var match_info = JSON.parse('\\x7B\\x22h_goals\\x22\\x3A\\x221\\x22\\x7D');</script>");
        return $res;
    });
    $mock_ua->mock( 'get', sub { return $mock_tx; });

    $api->ua($mock_ua);

    my $match_info = $api->match(1);

    cmp_ok( $match_info->{h_goals}, '==', 1, 'match: returns data' );
}

done_testing();

