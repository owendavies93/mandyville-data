#!/usr/bin/env perl

use Mojo::Base -strict;

use SQL::Abstract::More;
use Test::Exception;
use Test::MockObject::Extends;
use Test::More;
use Test::Warn;

use Mandyville::API::FootballData;
use Mandyville::Countries;
use Mandyville::Database;

######
# TEST use/require
######

use_ok 'Mandyville::Competitions';
require_ok 'Mandyville::Competitions';

use Mandyville::Competitions;

######
# TEST new
######

{
    dies_ok { Mandyville::Competitions->new; } 'new: dies with options';
    my $comp = Mandyville::Competitions->new({});
    
    ok( $comp->api,       'new: api is defined');
    ok( $comp->countries, 'new: countries is defined');
    ok( $comp->dbh,       'new: dbh is defined');
    ok( $comp->sqla,      'new: sqla is defined');
}

######
# TEST get_or_insert
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;
    my $countries = Mandyville::Countries->new({
        dbh  => $dbh->rw_db_handle(),
        sqla => $sqla,
    });
    my $comp = Mandyville::Competitions->new({
        api       => Mandyville::API::FootballData->new,
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    });

    dies_ok { $comp->get_or_insert } 'get_or_insert: dies without arguments';

    my $country = 'Argentina';
    my $comp_name = 'Primera B Nacional';
    my $country_id = $countries->get_country_id($country);
    my $comp_data = $comp->get_or_insert($comp_name, $country_id);

    cmp_ok( $comp_data->{country_name}, 'eq', $country,
            'get_or_insert: data matches' );

    my $id = $comp_data->{id};

    $comp_data = $comp->get_or_insert($comp_name, $country_id);

    cmp_ok( $comp_data->{id}, '==', $id, 'get_or_insert: get matches insert' );
}

######
# TEST get_competition_data
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;
    my $countries = Mandyville::Countries->new({
        dbh  => $dbh->rw_db_handle(),
        sqla => $sqla,
    });

    my $country = 'Argentina';
    my $comp_name = 'Primera B Nacional';

    my $mock_api = Test::MockObject::Extends->new(
        'Mandyville::API::FootballData'
    );

    $mock_api->mock( 'competitions', sub {
        my $hash = {
            competitions => [{
                area => {
                    name => $country,
                },
                name => $comp_name,
            }]
        };
        return $hash; 
    });

    my $comp = Mandyville::Competitions->new({
        api       => $mock_api,
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    });

    my $data = $comp->get_competition_data;

    cmp_ok( scalar @$data, '==', 1, 'get_competition_data: correct length' );

    cmp_ok( $data->[0]->{country_name}, 'eq', $country,
            'get_competition_data: correct country' );

    my $fake_name = 'Fictional';

    $mock_api->mock( 'competitions', sub {
        my $hash = {
            competitions => [{
                area => {
                    name => $fake_name,
                },
                name => $comp_name,
            }]
        };
        return $hash; 
    });

    warning_is { $comp->get_competition_data }
               "Skipping unknown country $fake_name",
               'get_competition_data: correctly warns for unknown country';
}

done_testing();

