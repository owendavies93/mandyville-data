#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
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

done_testing();

