#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Test::MockTime qw(set_absolute_time);

use Mandyville::API::FPL;
use Mandyville::Database;
use Mandyville::FPLClassic;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use Test::MockObject::Extends;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::FPLClassic';
require_ok 'Mandyville::FPLClassic';

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
    my $api = Test::MockObject::Extends->new(
        Mandyville::API::FPL->new
    );

    $api->mock( 'entry', sub { _fixture('fpl-classic-entry') } );
    $api->mock( 'entry_history', sub { _fixture('fpl-classic-entry-history') } );
    $api->mock( 'entry_transfers', sub { _fixture('fpl-classic-entry-transfers') } );
    $api->mock( 'entry_picks', sub {
        my ($self, $entry, $event) = @_;
        return $event == 1 ? _fixture('fpl-classic-entry-picks') : undef;
    });

    return $api;
}

sub _setup_players($dbh) {
    $dbh->do(q{
        INSERT INTO players (first_name, last_name, country_id, fpl_id)
        SELECT 'P' || gs, 'Player', (SELECT id FROM countries WHERE name = 'England'), 100 + gs
        FROM generate_series(0, 15) AS gs
    });

    # Classic elements 100..115 map to player ids 1..16.
    $dbh->do(q{
        INSERT INTO fpl_season_info (player_id, season, fpl_season_id, fpl_positions_id)
        SELECT id, 2026, 99 + id, 2 FROM players WHERE fpl_id >= 100
    });

    # GW1 deadline in the past, GW2 deadline in the future.
    $dbh->do(q{
        INSERT INTO fpl_gameweeks (season, gameweek, deadline)
        VALUES
            (2026, 1, '2026-08-21 17:30:00+00'),
            (2026, 2, '2026-08-28 17:30:00+00')
    });
}

######
# TEST sync
######

{
    set_absolute_time('2026-08-25T00:00:00Z');

    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();
    _setup_players($dbh);

    my $api = _mock_api();
    my $classic = Mandyville::FPLClassic->new({
        api    => $api,
        dbh    => $dbh,
        entry  => 123456,
        season => $SEASON,
    });

    my $changes = $classic->sync;
    ok( $changes > 0, 'sync: returns changes' );

    my $entry_id = _scalar( $dbh,
        'SELECT id FROM fpl_classic_entries WHERE fpl_entry_id = 123456 AND season = ?',
        $SEASON
    );
    ok( $entry_id, 'sync: entry inserted' );

    is( _scalar( $dbh,
            'SELECT is_mine FROM fpl_classic_entries WHERE id = ?', $entry_id ),
        1, 'sync: entry flagged as mine' );

    is( _scalar( $dbh,
            'SELECT COUNT(*) FROM fpl_classic_entry_history WHERE classic_entry_id = ?',
            $entry_id ),
        1, 'sync: one history row' );

    is( _scalar( $dbh,
            'SELECT COUNT(*) FROM fpl_classic_chips WHERE classic_entry_id = ?',
            $entry_id ),
        1, 'sync: one chip row' );

    is( _scalar( $dbh,
            'SELECT COUNT(*) FROM fpl_classic_transfers WHERE classic_entry_id = ?',
            $entry_id ),
        1, 'sync: one transfer row' );

    is( _scalar( $dbh,
            'SELECT COUNT(*) FROM fpl_classic_picks WHERE classic_entry_id = ?',
            $entry_id ),
        15, 'sync: fifteen picks stored' );

    # Idempotent: a second sync writes nothing new.
    is( $classic->sync, 0, 'sync: second run writes nothing' );

    # Element 100 maps to the player with fpl_id 100.
    my ($player_id) = $dbh->selectrow_array(
        'SELECT player_id FROM fpl_classic_picks
         WHERE classic_entry_id = ? AND fpl_element = 100', undef, $entry_id
    );
    is( $player_id, 1, 'sync: element mapped to player' );
}

######
# TEST current_squad
######

{
    set_absolute_time('2026-08-25T00:00:00Z');

    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();
    _setup_players($dbh);

    my $classic = Mandyville::FPLClassic->new({
        api    => _mock_api(),
        dbh    => $dbh,
        entry  => 123456,
        season => $SEASON,
    });

    $classic->sync;

    my $squad = $classic->current_squad;

    is( scalar @{$squad->{players}}, 15,
        'current_squad: fifteen players after the transfer' );

    is( $squad->{upcoming}, 2, 'current_squad: next gameweek is 2' );

    is( $squad->{captain}, 110, 'current_squad: captain from last lineup' );

    my $in = grep { $_ == 16 } @{$squad->{players}};
    is( $in, 1, 'current_squad: transferred-in player present' );

    my $out = grep { $_ == 1 } @{$squad->{players}};
    is( $out, 0, 'current_squad: transferred-out player absent' );

    # One free transfer earned for the completed gameweek, but the
    # upcoming gameweek's transfer has already used it.
    is( $classic->estimated_free_transfers, 0,
        'estimated_free_transfers: earned transfer is already used' );

    my $chips = $classic->chips_remaining;
    ok( !grep({ $_ eq 'wildcard' } @$chips),
        'chips_remaining: played chip excluded' );
    ok( grep({ $_ eq 'freehit' } @$chips),
        'chips_remaining: unplayed chip included' );
}

done_testing();
