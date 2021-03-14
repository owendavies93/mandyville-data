#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::More;

use Mandyville::Database;

use SQL::Abstract::More;
use Test::Exception;

######
# TEST use/require
######

use_ok 'Mandyville::Countries';
require_ok 'Mandyville::Countries';

use Mandyville::Countries;

######
# TEST new
######

{
    dies_ok { Mandyville::Countries->new } 'new: dies without options';

    my $countries = Mandyville::Countries->new({});

    ok( $countries->dbh,  'new: dbh is defined' );
    ok( $countries->sqla, 'new: sqla is defined' );
}

######
# TEST get_country_id
######

{
    my $db = Mandyville::Database->new;
    my $countries = Mandyville::Countries->new({
        dbh  => $db->rw_db_handle(),
        sqla => SQL::Abstract::More->new,
    });

    dies_ok { $countries->get_country_id() }
            'get_country_id: dies without name parameter';

    my $id = $countries->get_country_id('Fictional');

    ok( !$id, 'get_country_id: fictional country returns no ID' );

    $id = $countries->get_country_id('Botswana');

    cmp_ok( $id, '>', 0, 'get_country_id: positive ID returned' );
}

######
# TEST get_country_name
######

{
    my $db = Mandyville::Database->new;
    my $countries = Mandyville::Countries->new({
        dbh  => $db->rw_db_handle(),
        sqla => SQL::Abstract::More->new,
    });

    dies_ok { $countries->get_country_name() }
            'get_country_name: dies without name parameter';

    my $name = $countries->get_country_name(-1);

    ok( !$name, 'get_country_name: invalid ID returns no name' );

    $name = $countries->get_country_name(1);

    ok( $name, 'get_country_name: country returned' );
}

######
# TEST get_id_for_alternate_name
######

{
    my $db = Mandyville::Database->new;
    my $countries = Mandyville::Countries->new({
        dbh  => $db->rw_db_handle(),
        sqla => SQL::Abstract::More->new,
    });

    dies_ok { $countries->get_id_for_alternate_name() }
            'get_id_for_alternate_name: dies without name parameter';

    my $id = $countries->get_id_for_alternate_name('Fictional');

    ok( !$id, 'get_id_for_alternate_name: invalid name returns no ID' );

    $id = $countries->get_id_for_alternate_name('United States');

    cmp_ok( $id, '==', 237, 'get_id_for_alternate_name: correct ID returned' );
}

done_testing();

