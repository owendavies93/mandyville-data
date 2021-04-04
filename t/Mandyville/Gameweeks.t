#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::API::FPL;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use Test::Exception;
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
    set_absolute_time('2021-01-01T00:00:00Z');

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

    $mock_api->mock( 'gameweeks', sub {
        my $data = decode_json($json)->{events};
        $data->[0]->{deadline_time} = '2021-09-12T10:00:00Z';
        return $data;
    });

    throws_ok { $gameweeks->process_gameweeks } qr/Deadline for first/,
                'process_gameweeks: dies on season mismatch';
}

done_testing();
