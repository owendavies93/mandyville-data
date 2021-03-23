#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::Countries;
use Mandyville::Competitions;
use Mandyville::Database;
use Mandyville::Teams;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use SQL::Abstract::More;
use Test::Exception;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Fixtures';
require_ok 'Mandyville::Fixtures';

use Mandyville::Fixtures;

######
# TEST get_or_insert
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;
    my $teams = Mandyville::Teams->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $countries = Mandyville::Countries->new({
        dbh => $dbh->rw_db_handle(),
    }); 

    my $comp = Mandyville::Competitions->new({
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
    });

    my $fixtures = Mandyville::Fixtures->new({
        dbh   => $dbh->rw_db_handle(),
        sqla  => $sqla,
        teams => $teams,
    });

    dies_ok { $fixtures->get_or_insert } 'get_or_insert: dies without args';

    my $season = '2018';
    my $country = 'Argentina';
    my $comp_name = 'Primera B Nacional';
    my $country_id = $countries->get_country_id($country);
    my $comp_data = $comp->get_or_insert($comp_name, $country_id, 2000, 1);

    my $home = 'Atlético de Rafaela';
    my $away = 'Villa Dálmine';
    my $home_team_data = $teams->get_or_insert($home, 1);
    my $away_team_data = $teams->get_or_insert($away, 2);
    my $home_team_id = $home_team_data->{id};
    my $away_team_id = $away_team_data->{id};

    dies_ok { $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, {}
    ) } 'get_or_insert: dies on insert without match info';

    my $match_info = {
        winning_team_id => $home_team_id,
        home_team_goals => 1,
    };

    dies_ok { $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, $match_info
    ) } 'get_or_insert: dies without full match info';

    $match_info->{away_team_goals} = 3;

    my $fixture_data = $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, $match_info
    );

    my $id = $fixture_data->{id};

    ok( $id, 'get_or_insert: inserts with correct data' );

    $fixture_data = $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, $match_info
    );

    cmp_ok( $fixture_data->{id}, '==', $id );
}

######
# TEST process_fixture_data
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;
    my $teams = Mandyville::Teams->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $countries = Mandyville::Countries->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $comp = Mandyville::Competitions->new({
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
    });

    my $fixtures = Mandyville::Fixtures->new({
        comps => $comp,
        dbh   => $dbh->rw_db_handle(),
        sqla  => $sqla,
        teams => $teams,
    });

    my $country_id = $countries->get_country_id('Europe');
    my $comp_id = $comp->get_or_insert(
        'UEFA Champions League', $country_id, '2001', 1
    );

    dies_ok { $fixtures->process_fixture_data() }
              'process_fixture_data: dies without args';

    my $fixture_info = _load_test_json('match.json');

    my $data = $fixtures->process_fixture_data($fixture_info);

    ok( $data->{id}, 'process_fixture_data: inserts correctly' );

    cmp_ok( $data->{away_team_goals}, '==', 1,
            'process_fixture_data: correct match info' );

    cmp_ok( $data->{season}, '==', '2017',
            'process_fixture_data: correct season returned' );

    delete $fixture_info->{score}->{fullTime};

    throws_ok { $fixtures->process_fixture_data($fixture_info) }
                qr/Missing match/, 'process_fixture_data: dies without score';
}

done_testing();

sub _load_test_json($filename) {
    my $full_path = find_file("t/data/$filename");
    my $json = Mojo::File->new($full_path)->slurp;
    return decode_json($json);
}
