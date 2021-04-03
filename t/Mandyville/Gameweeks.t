#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::API::FPL;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use Test::MockObject::Extends;
use Test::MockTime qw(set_absolute_time);
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Gameweeks';
require_ok 'Mandyville::Gameweeks';

use Mandyville::Gameweeks;

######
# TEST process_gameweeks
######

{
    set_absolute_time('2020-01-01T00:00:00Z');

    my $mock_api = Test::MockObject::Extends->new(
        'Mandyville::API::FPL'
    );

    my $json = Mojo::File->new(find_file('t/data/events.json'))->slurp;

    $mock_api->mock( 'gameweeks', sub {
        return decode_json($json)->{events};
    });

    my $db = Mandyville::Database->new;
    my $gameweeks = Mandyville::Gameweeks->new({
        api => $mock_api,
        dbh => $db->rw_db_handle(),
    });

    my $processed = $gameweeks->process_gameweeks;

    ok( $processed, 'process_gameweeks: correctly returns' );

    my $processed_again = $gameweeks->process_gameweeks;

    cmp_ok( $processed, '==', $processed_again,
            'process_gameweeks: all records updated' );
}

done_testing();
