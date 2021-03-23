#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::API::FootballData;
use Mandyville::Countries;
use Mandyville::Competitions;
use Mandyville::Database;
use Mandyville::Fixtures;
use Mandyville::Teams;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use SQL::Abstract::More;
use Test::Exception;
use Test::MockObject::Extends;
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

    my $data = $players->get_or_insert(10, $player_info);

    ok( $data, 'get_or_insert: data inserted correctly' );

    my $fetched_data = $players->get_or_insert(10, {});

    cmp_ok( $data->{id}, '==', $fetched_data->{id},
            'get_or_insert: correctly fetches player from db' );

    $player_info = {
        first_name   => 'Moeen',
        last_name    => 'Ali',
        country_name => 'United States',
    };

    ok( $players->get_or_insert(11, $player_info),
        'get_or_insert: data inserted with alternate country' );
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
        api       => Mandyville::API::FootballData->new,
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
# TEST update_fixture_info
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
        _mock_player_api($id)
    } );

    my $players = Mandyville::Players->new({
        api       => $mock_api,
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

    $comps->get_or_insert('Europe', 250, 2001, 1);

    ok( $players->update_fixture_info($fixture_info),
        'update_fixture_info: updates successfully' );

    my ($count) = $dbh->rw_db_handle()->selectrow_array(
        'SELECT COUNT(1) FROM players_fixtures'
    );

    # Match the number of players in the test JSON
    cmp_ok( $count, '==', 4,
            'update_fixture_info: all player fixtures added' );
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
    } else {
        die "Unknown player ID $id";
    }
}

# TODO: Move into utils or similar
sub _load_test_json($filename) {
    my $full_path = find_file("t/data/$filename");
    my $json = Mojo::File->new($full_path)->slurp;
    return decode_json($json);
}

