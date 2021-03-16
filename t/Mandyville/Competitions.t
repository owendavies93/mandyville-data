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
    my $comp_data = $comp->get_or_insert($comp_name, $country_id, 2000, 1);

    cmp_ok( $comp_data->{country_name}, 'eq', $country,
            'get_or_insert: data matches' );

    my $id = $comp_data->{id};

    $comp_data = $comp->get_or_insert($comp_name, $country_id, 2000, 1);

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
    my $plan = 'TIER_ONE';
    my $football_data_id = 2003;

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
                plan => $plan,
                id   => $football_data_id,
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

    cmp_ok( $data->[0]->{football_data_id}, '==', $football_data_id,
            'get_competition_data: correct football data ID' );

    cmp_ok( $data->[0]->{football_data_plan}, '==',
            $comp->_plan_name_to_number($plan),
            'get_competition_data: correct football data plan number' );

    my $first_id = $data->[0]->{id};

    $country = 'Fictional';

    warning_is { $comp->get_competition_data }
               "Skipping unknown country $country\n",
               'get_competition_data: correctly warns for unknown country';

    $country = 'United States';
    my $country_full_name = 'United States of America';

    $data = $comp->get_competition_data;

    cmp_ok( scalar @$data, '==', 1, 'get_competition_data: correct length' );

    cmp_ok( $data->[0]->{id}, '!=', $first_id,
            'get_competition_data: inserted IDs are different' );

    cmp_ok( $data->[0]->{country_name}, 'eq', $country_full_name,
            'get_competition_data: returns full name not alternative name' );
}

######
# TEST get_by_football_data_id
######

{
    my $country = 'Argentina';
    my $comp_name = 'Primera B Nacional';
    my $plan = 'TIER_ONE';
    my $football_data_id = 2003;

    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;
    my $countries = Mandyville::Countries->new({
        dbh  => $dbh->rw_db_handle(),
        sqla => $sqla,
    });

    my $comp = Mandyville::Competitions->new({
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    });

    dies_ok { $comp->get_by_football_data_id() }
            'get_by_football_data_id: dies without id param';

    my $data = $comp->get_by_football_data_id($football_data_id);

    ok( !$data, 'get_by_football_data_id: returns undef when ID not found' );

    my $country_id = $countries->get_country_id($country);
    my $plan_id = $comp->_plan_name_to_number($plan);
    my $comp_data = $comp->get_or_insert(
        $comp_name, $country_id, $football_data_id, $plan_id
    );

    $data = $comp->get_by_football_data_id($football_data_id);

    cmp_ok( $data->{id}, '==', $comp_data->{id},
          'get_by_football_data_id: correct ID returned' );
}

######
# TEST _plan_name_to_number
######

{
    my $comp = Mandyville::Competitions->new({});
    my $plan_map = {
        'TIER_ONE'   => 1,
        'TIER_TWO'   => 2,
        'TIER_THREE' => 3,
        'TIER_FOUR'  => 4,
    };

    foreach my $p (keys %$plan_map) {
        my $num = $plan_map->{$p};
        cmp_ok( $comp->_plan_name_to_number($p), '==', $num,
                "_plan_name_to_number: $p mapping matches" );
    }

    dies_ok { $comp->_plan_name_to_number('foo') }
            '_plan_name_to_number: croaks on invalid tier nanme';
}

done_testing();

