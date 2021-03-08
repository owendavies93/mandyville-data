#!/usr/bin/env perl

use Mojo::Base -strict;

use Mojo::JSON qw(decode_json encode_json);
use Overload::FileCheck qw(mock_file_check unmock_file_check);
use Test::MockObject::Extends;
use Test::More;

######
# TEST includes/requires
######

use_ok 'Mandyville::API::FootballData';
require_ok 'Mandyville::API::FootballData';

use Mandyville::API::FootballData;

######
# TEST _get
######

{
    my $path = 'test';
    my $mock_ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    my $call_count = 0;

    $mock_ua->mock( 'get', sub {
        $call_count++;
        return encode_json({ "called" => 1 })
    });

    my $api = Mandyville::API::FootballData->new;
    $api->ua($mock_ua);
    my $response = $api->_get($path);

    cmp_ok( $response->{called}, '==', 1, '_get: response matches' );

    cmp_ok( $call_count, '==', 1, '_get: mocked UA was correctly called' );

    $api->_get($path);

    cmp_ok( $call_count, '==', 1, '_get: UA not called for same path' );

    unlink $api->cache->{$path};
    $api->_get($path);

    cmp_ok( $call_count, '==', 2, '_get: UA called if cache not found' );

    mock_file_check( '-M' => sub { 61 / 24 / 60 } );

    $api->_get($path);

    cmp_ok( $call_count, '==', 3, '_get: UA called after cache expiry' );

    unmock_file_check('-M');
}

done_testing;

