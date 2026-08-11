#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::Exception;
use Test::MockObject::Extends;
use Test::More;

######
# TEST includes/requires
######

use_ok 'Mandyville::API';
require_ok 'Mandyville::API';

use Mandyville::API;

######
# TEST _get
######

{
    my $api = Mandyville::API->new;

    throws_ok { $api->_get('test') } qr/not implemented/,
                '_get: correctly dies';
}

######
# TEST _rate_limit
######

{
    my $api = Mandyville::API->new;

    throws_ok { $api->_rate_limit() } qr/not implemented/,
                '_rate_limit: correctly dies';
}

######
# TEST get - invalid JSON response
######

{
    my $api = Test::MockObject::Extends->new(
        Mandyville::API->new
    );

    $api->mock( '_rate_limit', sub { return 1; } );
    $api->mock( '_get', sub { return '<html>Error</html>'; } );

    throws_ok { $api->get('test') } qr/Failed to decode JSON.*after retry.*Response:.*<html>/s,
                'get: dies with response body after retry fails';
}

######
# TEST get - retry succeeds
######

{
    my $api = Test::MockObject::Extends->new(
        Mandyville::API->new
    );

    my $call_count = 0;

    $api->mock( '_rate_limit', sub { return 1; } );
    $api->mock( '_get', sub {
        $call_count++;
        return $call_count == 1 ? '' : '{"ok":true}';
    });

    my $result;
    lives_ok { $result = $api->get('test') }
               'get: succeeds on retry after invalid JSON';

    is( $result->{ok}, 1, 'get: returns correct data after retry' );
    cmp_ok( $call_count, '==', 2, 'get: called _get twice' );
}

done_testing();

