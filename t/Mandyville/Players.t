#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

# This overrides at compile time, so needs to be included before
# any libs that may use time related functions
use Test::MockTime qw(set_absolute_time);

use Mandyville::API::FootballData;
use Mandyville::Countries;
use Mandyville::Competitions;
use Mandyville::Database;
use Mandyville::Fixtures;
use Mandyville::Teams;
use Mandyville::Utils qw(find_file);

use Clone qw(clone);
use Mojo::File;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(encode decode);
use SQL::Abstract::More;
use Test::Exception;
use Test::MockObject::Extends;
use Test::More;
use Test::Warn;

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
        api       => Mandyville::API::FootballData->new,
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

    my $fd_id = 10;

    my $data = $players->get_or_insert($fd_id, $player_info);

    ok( $data, 'get_or_insert: data inserted correctly' );

    my $fetched_data = $players->get_or_insert($fd_id, {});

    cmp_ok( $data->{id}, '==', $fetched_data->{id},
            'get_or_insert: correctly fetches player from db' );

    cmp_ok( $data->{country_name}, 'eq', $player_info->{country_name},
            'get_or_insret: country name matches' );

    $player_info = {
        first_name   => 'Moeen',
        last_name    => 'Ali',
        country_name => 'United States',
    };

    ok( $players->get_or_insert(11, $player_info),
        'get_or_insert: data inserted with alternate country' );

    my $from_json = _load_test_json('player.json');

    my $mock_api = Test::MockObject::Extends->new(
        'Mandyville::API::FootballData'
    );

    $mock_api->mock( 'player', sub { $from_json } );

    $players = Mandyville::Players->new({
        fapi      => $mock_api,
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    });

    my $before = $players->get_or_insert($fd_id, $player_info);

    $players->_update_name($before->{id}, $fd_id);

    my $updated = $players->get_or_insert($fd_id, {});

    cmp_ok( $before->{first_name}, 'ne', $updated->{first_name},
            '_update_name: name is updated' );

    ok( $data = $players->_get_api_info_and_store(56100),
        '_get_api_info_and_store: correctly deals with UTF-8 player data' );
}

######
# TEST get_by_football_data_id
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;

    my $countries = Mandyville::Countries->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $players = Mandyville::Players->new({
        fapi      => Mandyville::API::FootballData->new,
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    });

    dies_ok { $players->get_by_football_data_id() }
              'get_by_football_data_id: dies without args';

    my $f_d_id = 10;

    my $id = $players->get_by_football_data_id($f_d_id);

    ok( !$id, 'get_by_football_data_id: returns undef for unknown player' );

    my $player_info = {
        first_name   => 'Cristiano Ronaldo',
        last_name    => '',
        country_name => 'Portugal',
    };

    $players->get_or_insert($f_d_id, $player_info);

    $id = $players->get_by_football_data_id($f_d_id);

    ok( $id, 'get_by_football_data_id: returns ID for valid player' );
}

######
# TEST update_fixture_info, find_understat_id,
#      get_with_missing_understat_ids, update_understat_fixture_info,
#      get_without_understat_data
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;

    my $teams = Mandyville::Teams->new({
        dbh  => $dbh->rw_db_handle(),
        sqla => $sqla,
    });

    my $countries = Mandyville::Countries->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $comps = Mandyville::Competitions->new({
        api       => Mandyville::API::FootballData->new,
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    });

    my $fixtures = Mandyville::Fixtures->new({
        comps => $comps,
        dbh   => $dbh->rw_db_handle(),
        sqla  => $sqla,
        teams => $teams,
    });

    my $mock_api = Test::MockObject::Extends->new(
        'Mandyville::API::FootballData'
    );

    $mock_api->mock( 'player', sub {
        my ($self, $id) = @_;
        _mock_player_api($id);
    } );

    my $players = Mandyville::Players->new({
        fapi      => $mock_api,
        comps     => $comps,
        countries => $countries,
        fixtures  => $fixtures,
        dbh       => $dbh->rw_db_handle(),
        sqla      => $sqla,
    });

    dies_ok { $players->update_fixture_info }
              'update_fixture_info: dies without args';

    my $fixture_info = _load_test_json('players.json');

    throws_ok { $players->update_fixture_info($fixture_info) }
                qr/Unknown competition/,
                'update_fixture_info: dies on unknown competition';

    my $comp = $comps->get_or_insert('Europe', 250, 2001, 1);
    my $comp_id = $comp->{id};

    my $copy = clone($fixture_info);

    delete $copy->{score}->{fullTime}->{homeTeam};

    ok( !$players->update_fixture_info($copy),
        'update_fixture_info: returns early for incomplete fixture' );

    ok( $players->update_fixture_info($fixture_info),
        'update_fixture_info: updates successfully' );

    my ($count) = $dbh->rw_db_handle()->selectrow_array(
        'SELECT COUNT(1) FROM players_fixtures'
    );

    # Match the number of players in the test JSON
    my $player_count = 4;

    cmp_ok( $count, '==', $player_count,
            'update_fixture_info: all player fixtures added' );

    dies_ok { $players->get_team_for_player_fixture }
              'get_team_for_player_fixture: dies without args';

    my $team_id = $players->get_team_for_player_fixture(1, 1);

    ok( $team_id, 'get_team_for_player_fixture: returns ID' );

    # Test find_understat_id using the boilerplate from the existing
    # test
    my $mock_understat = Test::MockObject::Extends->new(
        'Mandyville::API::Understat'
    );

    my $name = 'Dani Carvajal';
    my $last = 'Carvajal';
    my $football_data_id = 3194;
    my $mandyville_id = $players->get_by_football_data_id($football_data_id);

    my $ids = $players->get_with_missing_understat_ids;

    cmp_ok( scalar @$ids, '==', $player_count,
            'find_understat_id: correct player count without IDs' );

    $mock_understat->mock( 'search', sub {
        my ($self, $name) = @_;
        _mock_search_api($name);
    } );

    $players->uapi($mock_understat);

    my $result = $players->find_understat_id($mandyville_id);

    ok( $result->{id}, 'find_understat_id: ID is returned' );
    cmp_ok( $result->{player}, 'ne', $name,
            'find_understat_id: matched on non-identical name' );

    my ($fetched_last) = $result->{player} =~ / (\w+)$/;

    cmp_ok( $fetched_last, 'eq', $last,
            'find_understat_id: last names match on non-identical name' );

    # Change to a valid football data ID from the current test data, but one
    # that the mock API doesn't know about
    $football_data_id = 50;
    $mandyville_id = $players->get_by_football_data_id($football_data_id);

    throws_ok { $players->find_understat_id($mandyville_id) }
                qr/Couldn't find understat ID/,
                'find_understat_id: dies on unknown player';

    $ids = $players->get_with_missing_understat_ids;

    cmp_ok( scalar @$ids, '==', $player_count - 1,
            'find_understat_id: correct count without IDs after insert' );

    my $with_comp_id = $players->get_with_missing_understat_ids([1]);

    cmp_ok( scalar @$with_comp_id, '==', scalar @$ids,
            'find_understat_id: matches with competition IDs' );

    dies_ok { $players->get_without_understat_data }
              'get_without_understat_data: dies without args';

    my $without_data = $players->get_without_understat_data(2018, [$comp_id]);

    cmp_ok( scalar @$without_data, '==', 1,
            'get_without_understat_data: returns players with IDs' );

    cmp_ok( $result->{id}, '==', $without_data->[0]->{understat_id},
            'get_without_understat_data: correct understat ID returned' );

    my $understat_data = {
        a_goals => "2",
        a_team => "Liverpool",
        assists => "0",
        date => "2021-03-06",
        goals => "0",
        h_goals => "1",
        h_team => "Real Madrid",
        id => "14696",
        key_passes => "0",
        npg => "0",
        npxG => "0.02079845406115055",
        position => "MC",
        roster_id => "454921",
        season => "2018",
        shots => "1",
        time => "72",
        xA => "0",
        xG => "0.02079845406115055",
        xGBuildup => "0",
        xGChain => "0.02079845406115055"
    };

    my $fixture_id = $fixtures->find_fixture_from_understat_data(
        $understat_data, [ $comp_id ]
    );

    dies_ok { players->update_understat_fixture_info }
              'update_understat_fixture_info: dies without args';

    throws_ok {
        $players->update_understat_fixture_info(
            $mandyville_id, $fixture_id, 1, {}
        )
    } qr/not provided/,
      'update_understat_fixture_info: dies without fixture info';

    my $status = $players->update_understat_fixture_info(
        $mandyville_id, $fixture_id, 1, $understat_data
    );

    cmp_ok( $status, '==', 1,
            'update_understat_fixture_info: correctly updates' );
}

######
# TEST find_player_by_fpl_info, update_fpl_id, add_fpl_season_info,
#      process_fpl_season_history
######

{
    my $db = Mandyville::Database->new;
    my $countries = Mandyville::Countries->new({
        dbh => $db->rw_db_handle(),
    });
    my $comp = Mandyville::Competitions->new({
        countries => $countries,
        dbh       => $db->rw_db_handle(),
    });

    my $country_id = $countries->get_country_id('England');
    my $comp_id = $comp->get_or_insert(
        'Premier League', $country_id, 2021, 1
    )->{id};

    my $teams = Mandyville::Teams->new({
        dbh => $db->rw_db_handle(),
    });

    my $fixtures = Mandyville::Fixtures->new({
        comps => $comp,
        dbh   => $db->rw_db_handle(),
        teams => $teams,
    });

    my $mock_api = Test::MockObject::Extends->new(
        'Mandyville::API::FootballData'
    );

    $mock_api->mock( 'player', sub {
        my ($self, $id) = @_;
        _mock_player_api($id);
    } );

    my $players = Mandyville::Players->new({
        fapi => $mock_api,
        dbh  => $db->rw_db_handle(),
    });

    my $fixture_info = _load_test_json("pl-match.json");

    $players->update_fixture_info($fixture_info);

    my $fpl_id = 1;
    my $fpl_info = {
        code        => $fpl_id,
        first_name  => 'Benjamin',
        second_name => 'Mendy',
        web_name    => 'Mendy',
    };

    my $info = $players->find_player_by_fpl_info($fpl_info);

    cmp_ok( $players->update_fpl_id($info->{id}, $fpl_id), '==', 1,
            'update_fpl_id: updates succesfully');

    cmp_ok( $players->update_fpl_id($info->{id}, $fpl_id), '==', 0,
            'update_fpl_id: doesn\'t update the same player again' );

    cmp_ok( $info->{first_name}, 'eq', $fpl_info->{first_name},
            'find_player_by_fpl_info: simple match returns correct name' );

    $fpl_info = {
        first_name  => 'Gabriel Fernando',
        second_name => 'de Jesus',
        web_name    => 'Jesus',
    };

    $info = $players->find_player_by_fpl_info($fpl_info);

    cmp_ok( $info->{first_name}, 'eq', 'Gabriel',
            'find_player_by_fpl_info: match on webname and first first name' );

    $fpl_info = {
        first_name  => 'Test',
        second_name => 'Test',
        web_name    => 'Testing Testing',
    };

    throws_ok { $players->find_player_by_fpl_info($fpl_info) } qr/No match/,
                'find_player_by_fpl_info: dies on no match';

    $fpl_info->{web_name} = 'Test';

    throws_ok { $players->find_player_by_fpl_info($fpl_info) } qr/No match/,
                'find_player_by_fpl_info: dies on no match';

    my $player_id = 1;
    $db->rw_db_handle->do(qq(
        INSERT INTO fpl_names (player_id, name)
        VALUES ($player_id, 'Test Test')
    ));

    $info = $players->find_player_by_fpl_info($fpl_info);

    cmp_ok( $info->{id}, '==', $player_id,
            'find_player_by_fpl_info: returns correct values after mapping' );

    dies_ok { $players->add_fpl_season_info }
              'add_fpl_season_info: dies without args';

    my $info_id = $players->add_fpl_season_info($player_id, 2020, 1, 1);

    ok( $info_id, 'add_fpl_season_info: correctly inserts' );

    my $new_id = $players->add_fpl_season_info($player_id, 2020, 1, 1);

    cmp_ok( $info_id, '==', $new_id,
            'add_fpl_season_info: correctly returns same id' );

    set_absolute_time('2020-01-01T00:00:00Z');
    $db->rw_db_handle->do(qq(
        INSERT INTO fpl_gameweeks (season, gameweek, deadline)
        VALUES (2020, 30, NOW())
    ));

    my $event_history = _load_test_json('fpl-event-history.json')->{history};

    warnings_like {
        my $count = $players->process_fpl_season_history(1, $event_history);

        cmp_ok( $count, '==', 1,
                'process_fpl_season_history: correct number of rows inserted' );

        $count = $players->process_fpl_season_history(1, $event_history);

        cmp_ok( $count, '==', 0,
                'process_fpl_season_history: no new rows inserted' );

    } [qr/Skipping GW31/, qr/Skipping GW31/],
       'process_fpl_season_history: correct warnings';
}

######
# TEST _sanitise_name
######

{
    my $players = Mandyville::Players->new({});

    my $info = {
        name        => 'Cristiano Ronaldo',
        firstName   => 'Cristiano Ronaldo',
        lastName    => undef,
        nationality => 'Portugal',
    };

    $info = $players->_sanitise_name($info);

    cmp_ok( $info->{firstName}, 'eq', 'Cristiano',
            '_sanitise_name: correct first name' );

    cmp_ok( $info->{lastName}, 'eq', 'Ronaldo',
            '_sanitise_name: correct last name' );

    $info = {
        name        => 'Marcelo',
        firstName   => 'Marcelo',
        lastName    => undef,
        nationality => 'Brazil',
    };

    $info = $players->_sanitise_name($info);

    cmp_ok( $info->{firstName}, 'eq', 'Marcelo',
            '_sanitise_name: correct first name' );

    cmp_ok( $info->{lastName}, 'eq', '',
            '_sanitise_name: correct last name' );

    $info = {
        name        => 'Marcelo',
        firstName   => undef,
        lastName    => 'Marcelo',
        nationality => 'Brazil',
    };

    $info = $players->_sanitise_name($info);

    cmp_ok( $info->{firstName}, 'eq', '',
            '_sanitise_name: correct first name' );

    cmp_ok( $info->{lastName}, 'eq', 'Marcelo',
            '_sanitise_name: correct last name' );

    $info = {
        name        => 'Dani Carvajal',
        firstName   => 'Dani',
        lastName    => 'Carvajal',
        nationality => 'Spain',
    };

    $info = $players->_sanitise_name($info);

    cmp_ok( $info->{firstName}, 'eq', 'Dani',
            '_sanitise_name: correct first name' );

    cmp_ok( $info->{lastName}, 'eq', 'Carvajal',
            '_sanitise_name: correct last name' );

    $info = {
        name        => 'Hakim El Mokeddem',
        firstName   => 'Hakim',
        lastName    => undef,
        nationality => 'France',
    };

    $info = $players->_sanitise_name($info);

    cmp_ok( $info->{firstName}, 'eq', 'Hakim',
            '_sanitise_name: correct first name' );

    cmp_ok( $info->{lastName}, 'eq', 'El Mokeddem',
            '_sanitise_name: correct last name' );
}

done_testing();

sub _mock_player_api($id) {
    if ($id == 3194) {
        return {
            firstName   => 'Dani',
            lastName    => 'Carvajal',
            nationality => 'Spain',
        };
    } elsif ($id == 50) {
        return {
            name        => 'Nacho',
            firstName   => 'Nacho',
            lastName    => undef,
            nationality => 'Spain',
        };
    } elsif ($id == 3754) {
        return {
            firstName   => 'Mohamed',
            lastName    => 'Salah',
            nationality => 'Egypt',
        };
    } elsif ($id == 3318) {
        return {
            firstName   => 'Adam',
            lastName    => 'Lallana',
            nationality => 'England',
        };
    } elsif ($id == 7882) {
        return {
            name        => 'Benjamin Mendy',
            firstName   => 'Benjamin',
            lastName    => undef,
            nationality => 'France',
        };
    } elsif ($id == 3236) {
        return {
            name        => 'Gabriel Jesus',
            firstName   => 'Gabriel Fernando',
            lastName    => undef,
            nationality => 'Brazil',
        };
    } elsif ($id == 124826) {
        return {
            name        => 'Vontae Daley Campbell',
            firstName   => 'Vontae',
            lastName    => undef,
            nationality => 'England',
        };
    } elsif ($id == 3222) {
        return {
            name        => 'Ederson',
            firstName   => 'Ederson',
            lastName    => undef,
            nationality => 'Brazil',
        };
    } else {
        die "Unknown player ID $id";
    }
}

sub _mock_search_api($name) {
    if ($name eq 'Dani Carvajal') {
        return [];
    } elsif ($name eq 'Carvajal') {
        return [{
            id     => '2260',
            player => 'Daniel Carvajal',
            team   => 'Real Madrid'
        }]
    } else {
        return [];
    }
}

# TODO: Move into utils or similar
sub _load_test_json($filename) {
    my $full_path = find_file("t/data/$filename");
    my $json = Mojo::File->new($full_path)->slurp;
    return decode_json($json);
}

