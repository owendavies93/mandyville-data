#!/usr/bin/env perl

use Mojo::Base -strict;

use Mandyville::Competitions;
use Mandyville::Countries;
use Mandyville::Database;

use Test::Exception;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Teams';
require_ok 'Mandyville::Teams';

use Mandyville::Teams;

######
# TEST get_or_insert and find_from_name
######

{
    my $db = Mandyville::Database->new;

    my $teams = Mandyville::Teams->new({
        dbh => $db->rw_db_handle(),
    });

    my $football_data_id = 100;
    my $name = 'Chelsea';

    dies_ok { $teams->get_or_insert(); } 'get_or_insert: dies without args';

    my $data = $teams->get_or_insert($name, $football_data_id);
    my $id   = $data->{id};

    ok( $id, 'get_or_insert: id returned after insert' );

    cmp_ok( $data->{name}, 'eq', $name, 'get_or_insert: name matches' );

    $data = $teams->get_or_insert($name, $football_data_id);

    cmp_ok( $data->{id}, '==', $id, 'get_or_insert: id matches after get' );

    my $results = $teams->find_from_name('Chelsea');

    cmp_ok( scalar @$results, '==', 1, 'find_from_name: correct results' );

    $results = $teams->find_from_name('Chelsea FC');

    cmp_ok( scalar @$results, '==', 0, 'find_from_name: correct no results' );

    $results = $teams->find_from_name('hel');

    cmp_ok( scalar @$results, '==', 1, 'find_from_name: correct results' );
}

######
# TEST get_or_insert_team_comp
######

{
    my $db = Mandyville::Database->new;
    my $countries = Mandyville::Countries->new({
        dbh => $db->rw_db_handle(),
    });

    my $teams = Mandyville::Teams->new({
        dbh => $db->rw_db_handle(),
    });

    my $comps = Mandyville::Competitions->new({
        dbh => $db->rw_db_handle(),
    });
    
    my $football_data_id = 100;
    my $name = 'Chelsea';
    my $country_id = $countries->get_country_id('England');
    my $season = '2020';
    my $comp_name = 'Premier League';
    my $comp_id = '2000';

    my $comp    = $comps->get_or_insert($comp_name, $country_id, $comp_id, 1);
    my $team    = $teams->get_or_insert($name, $football_data_id);
    my $team_id = $team->{id};

    dies_ok { $teams->get_or_insert_team_comp() }
              'get_or_insert_team_comp: dies without args';

    my $team_comp = $teams->get_or_insert_team_comp(
        $team_id, $season, $comp->{id}
    );

    ok( $team_comp, 'get_or_insert_team_comp: inserts successfully' );

    cmp_ok( $team_comp->{team_id}, '==', $team_id,
            'get_or_insert_team_comp: team IDs match' );

    my $team_comp_id = $team_comp->{id};

    $team_comp = $teams->get_or_insert_team_comp(
        $team_id, $season, $comp->{id}
    );

    cmp_ok( $team_comp->{id}, '==', $team_comp_id,
            'get_or_insert_team_comp: team comp ID matches after get' );
}

done_testing();

