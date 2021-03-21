#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::Countries;
use Mandyville::Database;

use Test::Exception;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Players';
require_ok 'Mandyville::Players';

use Mandyville::Players;

######
# TEST get_or_insert
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;

    my $countries = Mandyville::Countries->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $players = Mandyville::Players->new({
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    }); 

    dies_ok { $players->get_or_insert() } 'get_or_insert: dies with args';

    throws_ok { $players->get_or_insert(10, {}) }
                qr/missing first_name attribute/,
                'get_or_insert: dies on insert without correct player info';

    my $player_info = {
        first_name   => 'Cristiano Ronaldo',
        last_name    => '',
        country_name => 'Portugal',
    };

    my $data = $players->get_or_insert(10, $player_info);

    ok( $data, 'get_or_insert: data inserted correctly' );

    my $fetched_data = $players->get_or_insert(10, {});

    cmp_ok( $data->{id}, '==', $fetched_data->{id},
            'get_or_insert: correctly fetches player from db' );
}

done_testing();

