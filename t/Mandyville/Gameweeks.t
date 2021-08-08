#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

# This overrides at compile time, so needs to be included before
# any libs that may use time related functions
use Test::MockTime qw(set_absolute_time);

use Mandyville::API::FPL;
use Mandyville::Competitions;
use Mandyville::Countries;
use Mandyville::Fixtures;
use Mandyville::Utils qw(current_season find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use Test::Exception;
use Test::MockObject::Extends;
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

######
# TEST add_fixture_gameweeks and get_gameweek_id
######

{
    set_absolute_time('2021-01-01T00:00:00Z');
    my $season = current_season();

    my $mock_api = Test::MockObject::Extends->new(
        'Mandyville::API::FPL'
    );

    my $json = Mojo::File->new(find_file('t/data/events.json'))->slurp;

    $mock_api->mock( 'gameweeks', sub {
        return decode_json($json)->{events};
    });

    my $db = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;

    my $countries = Mandyville::Countries->new({
        dbh => $db->rw_db_handle(),
    });

    my $comp = Mandyville::Competitions->new({
        countries => $countries,
        dbh       => $db->rw_db_handle(),
    });

    my $teams = Mandyville::Teams->new({
        dbh => $db->rw_db_handle(),
    });

    my $fixtures = Mandyville::Fixtures->new({
        dbh   => $db->rw_db_handle(),
        teams => $teams,
    });

    my $country_id = $countries->get_country_id('England');
    my $comp_id = $comp->get_or_insert(
        'Premier League', $country_id, 1, 1
    )->{id};

    my $home = 'Liverpool FC';
    my $away = 'Chelsea FC';
    my $home_team_id = $teams->get_or_insert($home, 1)->{id};
    my $away_team_id = $teams->get_or_insert($away, 1)->{id};

    my $match_info = {
        winning_team_id => $away_team_id,
        home_team_goals => 0,
        away_team_goals => 5,
        fixture_date    => '2021-01-01',
    };

    my $fixture_id = $fixtures->get_or_insert(
        $comp_id, $home_team_id, $away_team_id, $season, $match_info
    )->{id};

    my $gameweeks = Mandyville::Gameweeks->new({
        api  => $mock_api,
        dbh  => $db->rw_db_handle(),
        sqla => $sqla,
    });

    $gameweeks->process_gameweeks;

    my $updated = $gameweeks->add_fixture_gameweeks;

    cmp_ok( $updated, '==', 1,
            'add_fixture_gameweeks: adds the only fixture' );

    my $updated_again = $gameweeks->add_fixture_gameweeks;

    cmp_ok( $updated, '==', $updated_again,
            'add_fixture_gameweeks: updates the only fixture' );

    my $gw = _get_gw_for_fixture($fixture_id, $sqla, $db);

    cmp_ok( $gw, '==', 17, 'add_fixture_gameweeks: adds correct gameweek' );

    my $tmp = $home_team_id;
    $home_team_id = $away_team_id;
    $away_team_id = $tmp;

    $match_info->{fixture_date} = '2021-06-01';

    $fixture_id = $fixtures->get_or_insert(
        $comp_id, $home_team_id, $away_team_id, $season, $match_info
    )->{id};

    $gameweeks->add_fixture_gameweeks;

    $gw = _get_gw_for_fixture($fixture_id, $sqla, $db);

    cmp_ok( $gw, '==', 38,
            'add_fixture_gameweeks: adds correct gameweek for season end' );

    my $gw_id = $gameweeks->get_gameweek_id($season, $gw);

    ok( $gw_id, 'get_gameweek_id: fetches ID for valid gameweek' );

    dies_ok { $gameweeks->get_gameweek_id($season, 100) }
              'get_gameweek_id: correctly dies for invalid gameweek';
}

sub _get_gw_for_fixture($fixture_id, $sqla, $db) {
    my ($stmt, @bind) = $sqla->select(
        -columns => 'g.gameweek',
        -from    => [ -join => qw{
            fpl_gameweeks|g <=>{g.id=f.gameweek_id} fixtures_fpl_gameweeks|f
        }],
        -where   => {
            'f.fixture_id' => $fixture_id,
        }
    );

    my ($gw) = $db->rw_db_handle()->selectrow_array($stmt, undef, @bind);
    return $gw;
}

done_testing();
