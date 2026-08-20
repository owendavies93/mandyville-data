#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

# This overrides at compile time, so needs to be included before
# any libs that may use time related functions
use Test::MockTime qw(set_absolute_time);

use Mandyville::API::FPL;
use Mandyville::API::FPLDraft;
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

    cmp_ok( $processed_again, '==', 0,
            'process_gameweeks: no changes on a second run' );

    is( scalar @{$gameweeks->last_changes}, 0,
        'process_gameweeks: no changes reported when nothing changed' );

    $mock_api->mock( 'gameweeks', sub {
        my $data = decode_json($json)->{events};
        $data->[0]->{deadline_time} = '2021-09-12T10:00:00Z';
        return $data;
    });

    throws_ok { $gameweeks->process_gameweeks } qr/Deadline for first/,
                'process_gameweeks: dies on season mismatch';
}

######
# TEST process_draft_gameweeks
######

{
    set_absolute_time('2021-01-01T00:00:00Z');

    my $mock_api = Test::MockObject::Extends->new(
        'Mandyville::API::FPL'
    );

    my $classic_json = Mojo::File->new(find_file('t/data/events.json'))->slurp;

    $mock_api->mock( 'gameweeks', sub {
        return decode_json($classic_json)->{events};
    });

    my $mock_draft_api = Test::MockObject::Extends->new(
        'Mandyville::API::FPLDraft'
    );

    my $draft_json =
        Mojo::File->new(find_file('t/data/fpl-draft-bootstrap-events.json'))->slurp;

    $mock_draft_api->mock( 'events', sub {
        return decode_json($draft_json);
    });

    my $db = Mandyville::Database->new;
    my $gameweeks = Mandyville::Gameweeks->new({
        api       => $mock_api,
        draft_api => $mock_draft_api,
        dbh       => $db->rw_db_handle(),
    });

    my $updated = $gameweeks->process_draft_gameweeks;

    cmp_ok( $updated, '==', 38 * 3,
            'process_draft_gameweeks: writes draft, waiver and trade times' );

    my $dbh = $db->rw_db_handle();

    my ($draft_deadline, $waivers, $trades) = $dbh->selectrow_array(
        'SELECT extract(epoch from draft_deadline)::bigint,
                extract(epoch from waivers_time)::bigint,
                extract(epoch from trades_time)::bigint
         FROM fpl_gameweeks WHERE season = 2020 AND gameweek = 1'
    );

    is( $draft_deadline, 1599904800,
        'process_draft_gameweeks: draft deadline stored' );
    is( $waivers, 1599818400,
        'process_draft_gameweeks: waiver time stored' );
    is( $trades, 1599732000,
        'process_draft_gameweeks: trade time stored' );

    my $history = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM fpl_gameweek_deadline_history'
    );
    cmp_ok( $history, '==', 38 * 4,
            'process_draft_gameweeks: history rows for every kind and gameweek' );

    # A changed waiver deadline is recorded and closes the old history row.
    my $data = decode_json($draft_json);
    $data->{data}[0]{waivers_time} = '2020-09-11T18:00:00Z';
    $mock_draft_api->mock( 'events', sub { $data } );

    my $changed = $gameweeks->process_draft_gameweeks;
    cmp_ok( $changed, '==', 1,
            'process_draft_gameweeks: one change when a waiver time moves' );

    my @changes = @{$gameweeks->last_changes};
    is( scalar @changes, 1, 'process_draft_gameweeks: one change reported' );
    is( $changes[0]{kind}, 'waivers',
        'process_draft_gameweeks: change is the waiver time' );
    is( $gameweeks->_timestamp_epoch($changes[0]{old}), 1599818400,
        'process_draft_gameweeks: old waiver time reported' );
    is( $gameweeks->_timestamp_epoch($changes[0]{new}), 1599847200,
        'process_draft_gameweeks: new waiver time reported' );

    my ($open, $closed) = $dbh->selectrow_array(q{
        SELECT
            COUNT(*) FILTER (WHERE end_time IS NULL),
            COUNT(*) FILTER (WHERE end_time IS NOT NULL)
        FROM fpl_gameweek_deadline_history
        WHERE fpl_gameweek_id = (SELECT id FROM fpl_gameweeks
                                  WHERE season = 2020 AND gameweek = 1)
          AND kind = 'waivers'
    });
    is( $open, 1, 'process_draft_gameweeks: one open waiver history row' );
    is( $closed, 1, 'process_draft_gameweeks: old waiver history row closed' );
}

######
# TEST upcoming_deadlines
######

{
    set_absolute_time('2021-01-01T00:00:00Z');

    my $db = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    $dbh->do(q{
        INSERT INTO fpl_gameweeks (season, gameweek, deadline,
                                   draft_deadline, waivers_time, trades_time)
        VALUES
            (2020, 17, '2021-01-01 11:00:00+00',
             '2021-01-01 11:00:00+00', '2020-12-31 11:00:00+00',
             '2020-12-30 11:00:00+00'),
            (2020, 18, '2021-01-12 16:30:00+00',
             '2021-01-12 16:30:00+00', '2021-01-11 16:30:00+00',
             '2021-01-10 16:30:00+00')
        ON CONFLICT (season, gameweek) DO UPDATE SET
            deadline       = EXCLUDED.deadline,
            draft_deadline = EXCLUDED.draft_deadline,
            waivers_time   = EXCLUDED.waivers_time,
            trades_time    = EXCLUDED.trades_time
    });

    my $gameweeks = Mandyville::Gameweeks->new({ dbh => $dbh });

    my ($gw17_deadline) = $dbh->selectrow_array(
        'SELECT extract(epoch from deadline)::bigint
         FROM fpl_gameweeks WHERE season = 2020 AND gameweek = 17'
    );

    # Look forward from just after the GW17 deadline, so every GW17 entry
    # is in the past and only the four GW18 entries remain.
    my $now = $gw17_deadline + 1;

    my $upcoming = $gameweeks->upcoming_deadlines($now, 30 * 24 * 3600);

    is( scalar @$upcoming, 4,
        'upcoming_deadlines: only GW18 entries remain after the GW17 deadline' );

    is( $upcoming->[0]{kind}, 'trades',
        'upcoming_deadlines: earliest upcoming deadline is the trade time' );
    is( $upcoming->[0]{gameweek}, 18,
        'upcoming_deadlines: GW18 trade time comes first' );

    my @kinds = map { $_->{kind} } @$upcoming;
    is( scalar @kinds, 4, 'upcoming_deadlines: four upcoming kinds' );
    my $waivers = grep { $_ eq 'waivers' } @kinds;
    is( $waivers, 1, 'upcoming_deadlines: waiver time included' );
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

######
# TEST add_fixture_gameweeks with explicit season
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

    my $home = 'Tottenham Hotspur FC';
    my $away = 'Arsenal FC';
    my $home_team_id = $teams->get_or_insert($home, 1)->{id};
    my $away_team_id = $teams->get_or_insert($away, 1)->{id};

    my $gameweeks = Mandyville::Gameweeks->new({
        api  => $mock_api,
        dbh  => $db->rw_db_handle(),
        sqla => $sqla,
    });

    $gameweeks->process_gameweeks;

    my $season = current_season();

    my $match_info = {
        winning_team_id => $home_team_id,
        home_team_goals => 2,
        away_team_goals => 0,
        fixture_date    => '2020-12-06',
    };

    my $fixture_id = $fixtures->get_or_insert(
        $comp_id, $home_team_id, $away_team_id, $season, $match_info
    )->{id};

    my $updated = $gameweeks->add_fixture_gameweeks($season);

    ok( $updated, 'add_fixture_gameweeks: works with explicit season' );

    my $gw = _get_gw_for_fixture($fixture_id, $sqla, $db);

    cmp_ok( $gw, '==', 11,
            'add_fixture_gameweeks: correct gameweek with explicit season' );

    # A different season should not pick up these fixtures
    my $other_updated = $gameweeks->add_fixture_gameweeks($season - 1);

    cmp_ok( $other_updated, '==', 0,
            'add_fixture_gameweeks: no fixtures for different season' );
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
