#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::API::FPLDraft;
use Mandyville::Database;
use Mandyville::FPLDraft;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use Test::MockObject::Extends;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::FPLDraft';
require_ok 'Mandyville::FPLDraft';

my $SEASON = 2026;

sub _fixture($name) {
    return decode_json(
        Mojo::File->new(find_file("t/data/$name.json"))->slurp
    );
}

sub _scalar($dbh, $sql, @bind) {
    return $dbh->selectrow_array($sql, undef, @bind);
}

sub _mock_api {
    my $bootstrap = _fixture('fpl-draft-bootstrap');
    my $details   = _fixture('fpl-draft-league-details');
    my $status    = _fixture('fpl-draft-element-status');
    my $choices   = _fixture('fpl-draft-choices');
    my $txns      = _fixture('fpl-draft-transactions');

    my $api = Test::MockObject::Extends->new(
        Mandyville::API::FPLDraft->new
    );

    $api->mock( 'bootstrap', sub { $bootstrap } );
    $api->mock( 'elements', sub { $bootstrap->{elements} } );
    $api->mock( 'league_details', sub { $details } );
    $api->mock( 'choices', sub { $choices->{choices} } );
    $api->mock( 'transactions', sub { $txns->{transactions} } );
    $api->mock( 'element_status', sub { $status->{element_status} } );
    $api->mock( 'entry_event', sub {
        my ($self, $entry_id, $event) = @_;
        my %picks = (
            1001 => [{ element => 10, position => 1 }],
            1002 => [{ element => 20, position => 1 }],
        );
        return { picks => $picks{$entry_id} // [] };
    });

    return ($api, $bootstrap, $details, $status);
}

######
# TEST sync - full league state
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    $dbh->do(q{
        INSERT INTO players (first_name, last_name, country_id, fpl_id)
        VALUES
            ('A', 'One',   (SELECT id FROM countries WHERE name = 'England'), 100),
            ('B', 'Two',   (SELECT id FROM countries WHERE name = 'England'), 200),
            ('C', 'Three', (SELECT id FROM countries WHERE name = 'England'), 300)
    });
    $dbh->do(q{
        INSERT INTO fpl_season_info (player_id, season, fpl_season_id, fpl_positions_id)
        VALUES (1, 2026, 101, 1), (2, 2026, 102, 1), (3, 2026, 103, 1)
    });

    my ($api) = _mock_api();
    my $fpl_draft = Mandyville::FPLDraft->new({
        api     => $api,
        dbh     => $dbh,
        leagues => [{ id => 1, entry => 1001 }],
        season  => $SEASON,
    });

    my $changes = $fpl_draft->sync;
    ok( $changes > 0, 'sync: returns changes' );

    my $league_id = _scalar( $dbh,
        'SELECT id FROM fpl_draft_leagues WHERE fpl_league_id = 1 AND season = ?',
        $SEASON
    );
    ok( $league_id, 'sync: league inserted' );

    my $entries = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_entries WHERE league_id = ?', $league_id
    );
    is( $entries, 2, 'sync: two entries' );

    my $mine = _scalar( $dbh,
        'SELECT is_mine FROM fpl_draft_entries WHERE league_id = ? AND entry_id = 1001',
        $league_id
    );
    ok( $mine, 'sync: my entry is flagged' );

    my $picks = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_picks WHERE league_id = ?', $league_id
    );
    is( $picks, 2, 'sync: two draft picks' );

    my $txns = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_transactions WHERE league_id = ?', $league_id
    );
    is( $txns, 1, 'sync: one transaction' );

    my $matches = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_matches WHERE league_id = ?', $league_id
    );
    is( $matches, 1, 'sync: one match' );

    my $standings = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_standings WHERE league_id = ?', $league_id
    );
    is( $standings, 2, 'sync: two standings rows' );

    my $waivers = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_waiver_order WHERE draft_entry_id IN
            (SELECT id FROM fpl_draft_entries WHERE league_id = ?) AND end_time IS NULL',
        $league_id
    );
    is( $waivers, 2, 'sync: two open waiver order rows' );

    my $open = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_ownership WHERE league_id = ? AND end_time IS NULL',
        $league_id
    );
    is( $open, 4, 'sync: four open ownership rows (incl. free agents)' );

    my $free = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_ownership
         WHERE league_id = ? AND end_time IS NULL AND draft_entry_id IS NULL',
        $league_id
    );
    is( $free, 2, 'sync: two free agents' );

    my $entry_picks = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_entry_picks WHERE league_id = ?', $league_id
    );
    is( $entry_picks, 2, 'sync: one starting pick per entry' );

    my $draft_id = _scalar( $dbh,
        'SELECT fpl_draft_id FROM fpl_season_info WHERE player_id = 1 AND season = ?',
        $SEASON
    );
    is( $draft_id, 10, 'sync: fpl_draft_id mapped via code for player 1' );
}

######
# TEST ownership change detection (range closing)
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    $dbh->do(q{
        INSERT INTO players (first_name, last_name, country_id, fpl_id)
        VALUES
            ('A', 'One',   (SELECT id FROM countries WHERE name = 'England'), 100),
            ('B', 'Two',   (SELECT id FROM countries WHERE name = 'England'), 200),
            ('C', 'Three', (SELECT id FROM countries WHERE name = 'England'), 300)
    });

    my ($api, $bootstrap, $details, $status) = _mock_api();
    my $fpl_draft = Mandyville::FPLDraft->new({
        api     => $api,
        dbh     => $dbh,
        leagues => [{ id => 1, entry => 1001 }],
        season  => $SEASON,
    });

    $fpl_draft->sync;

    my $league_id = _scalar( $dbh,
        'SELECT id FROM fpl_draft_leagues WHERE fpl_league_id = 1 AND season = ?',
        $SEASON
    );

    # Element 30 becomes owned by entry 1001.
    $status->{element_status}[2]{owner} = 1001;

    my $changes = $fpl_draft->sync;
    is( $changes, 2, 'ownership change: close + reopen = 2 changes' );

    my $total = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_ownership WHERE league_id = ?', $league_id
    );
    is( $total, 5, 'ownership change: previous row kept, new row added' );

    my $open = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_draft_ownership WHERE league_id = ? AND end_time IS NULL',
        $league_id
    );
    is( $open, 4, 'ownership change: still four open rows' );

    my $owner = _scalar( $dbh, q{
        SELECT e.entry_id FROM fpl_draft_ownership o
        JOIN fpl_draft_entries e ON e.id = o.draft_entry_id
        WHERE o.league_id = ? AND o.fpl_draft_element = 30 AND o.end_time IS NULL
    }, $league_id );
    is( $owner, 1001, 'ownership change: element 30 now owned by entry 1001' );
}

######
# TEST waiver order change detection
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    $dbh->do(q{
        INSERT INTO players (first_name, last_name, country_id, fpl_id)
        VALUES
            ('A', 'One',   (SELECT id FROM countries WHERE name = 'England'), 100),
            ('B', 'Two',   (SELECT id FROM countries WHERE name = 'England'), 200),
            ('C', 'Three', (SELECT id FROM countries WHERE name = 'England'), 300)
    });

    my ($api, $bootstrap, $details, $status) = _mock_api();
    my $fpl_draft = Mandyville::FPLDraft->new({
        api     => $api,
        dbh     => $dbh,
        leagues => [{ id => 1, entry => 1001 }],
        season  => $SEASON,
    });

    $fpl_draft->sync;

    # Entry 1001 drops from waiver pick 1 to 2.
    $details->{league_entries}[0]{waiver_pick} = 2;

    my $changes = $fpl_draft->sync;
    is( $changes, 2, 'waiver change: close + reopen = 2 changes' );

    my $pick = _scalar( $dbh, q{
        SELECT wo.waiver_pick FROM fpl_draft_waiver_order wo
        JOIN fpl_draft_entries e ON e.id = wo.draft_entry_id
        WHERE e.entry_id = 1001 AND wo.end_time IS NULL
    } );
    is( $pick, 2, 'waiver change: new open row has updated pick' );

    my $closed = _scalar( $dbh, q{
        SELECT COUNT(*) FROM fpl_draft_waiver_order wo
        JOIN fpl_draft_entries e ON e.id = wo.draft_entry_id
        WHERE e.entry_id = 1001 AND wo.end_time IS NOT NULL
    } );
    is( $closed, 1, 'waiver change: old row closed' );
}

######
# TEST availability
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    $dbh->do(q{
        INSERT INTO players (first_name, last_name, country_id, fpl_id)
        VALUES
            ('A', 'One',   (SELECT id FROM countries WHERE name = 'England'), 100),
            ('B', 'Two',   (SELECT id FROM countries WHERE name = 'England'), 200),
            ('C', 'Three', (SELECT id FROM countries WHERE name = 'England'), 300)
    });

    my ($api, $bootstrap) = _mock_api();
    my $fpl_draft = Mandyville::FPLDraft->new({
        api    => $api,
        dbh    => $dbh,
        season => $SEASON,
    });

    my $changes = $fpl_draft->sync_availability;
    is( $changes, 4, 'availability: one row per element' );

    my $matched = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_player_availability
         WHERE season = ? AND end_time IS NULL AND player_id IS NOT NULL',
        $SEASON
    );
    is( $matched, 3, 'availability: three matched to players' );

    my $injured = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_player_availability
         WHERE season = ? AND end_time IS NULL AND status = ?',
        $SEASON, 'i'
    );
    is( $injured, 1, 'availability: one injured player' );

    # Element 20 becomes injured.
    $bootstrap->{elements}[1]{status} = 'i';
    $bootstrap->{elements}[1]{news}   = 'Knee injury';

    my $second = $fpl_draft->sync_availability;
    is( $second, 2, 'availability: change closes and reopens one row' );

    my $total = _scalar( $dbh,
        'SELECT COUNT(*) FROM fpl_player_availability WHERE season = ?', $SEASON
    );
    is( $total, 5, 'availability: five rows total after change' );
}

done_testing();
