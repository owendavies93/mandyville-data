#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::Database;
use Mandyville::Reminders;

use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Reminders';
require_ok 'Mandyville::Reminders';

# A fake gameweeks backend whose deadlines can be driven from the tests.
package RemindersTest::Gameweeks {
    sub new($class, $rows) {
        return bless { rows => $rows }, $class;
    }

    sub upcoming_deadlines($self, $from, $horizon) {
        return [grep { $_->{deadline_epoch} > $from && $_->{deadline_epoch} <= $from + $horizon }
            @{$self->{rows}}];
    }
}

# A fake notifier that records what was sent and can be told to fail.
package RemindersTest::Notifier {
    sub new($class) {
        return bless { sent => [], fail => 0 }, $class;
    }

    sub deliver($self, $message) {
        return 0 if $self->{fail};
        push @{$self->{sent}}, $message;
        return 1;
    }
}

package main;

sub _scalar($dbh, $sql, @bind) {
    return $dbh->selectrow_array($sql, undef, @bind);
}

sub _reminders($dbh, $notifier, $rows) {
    return Mandyville::Reminders->new({
        dbh      => $dbh,
        notifier => $notifier,
        config   => {
            reminders => {
                offsets => {
                    classic => [24, 12, 2],
                    draft   => [24, 12, 2],
                    waivers => [24, 2],
                },
            },
        },
        season   => 2026,
        gameweeks => RemindersTest::Gameweeks->new($rows),
    });
}

sub _deadline($season, $gw, $kind, $epoch) {
    require Time::Piece;
    my $deadline = Time::Piece->gmtime($epoch)->strftime('%Y-%m-%dT%H:%M:%SZ');

    return {
        season         => $season,
        gameweek       => $gw,
        kind           => $kind,
        deadline       => $deadline,
        deadline_epoch => $epoch,
    };
}

my $NOW = 1_000_000_000;

######
# TEST due_reminders sends once and dedupes
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    my $notifier = RemindersTest::Notifier->new;
    my $rows = [
        _deadline(2026, 3, 'classic', $NOW + 2 * 3600),  # two hours away
    ];

    my $reminders = _reminders($dbh, $notifier, $rows);

    is( $reminders->due_reminders($NOW), 1,
        'due_reminders: sends the 2h offset' );

    is( scalar @{$notifier->{sent}}, 1,
        'due_reminders: one message sent' );

    is( $reminders->due_reminders($NOW), 0,
        'due_reminders: does not resend on the next tick' );

    is( _scalar( $dbh,
            'SELECT COUNT(*) FROM fpl_reminders WHERE gameweek = 3 AND status = ?',
            'sent' ),
        1, 'due_reminders: sent row recorded' );
}

######
# TEST several offsets due at once: only the nearest fires
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    my $notifier = RemindersTest::Notifier->new;
    my $rows = [
        _deadline(2026, 4, 'classic', $NOW + 1 * 3600),  # one hour away
    ];

    my $reminders = _reminders($dbh, $notifier, $rows);

    # The 24h, 12h and 2h offsets are all in the past; only 2h fires.
    is( $reminders->due_reminders($NOW), 1,
        'due_reminders: only one message despite several due offsets' );

    my ($sent, $suppressed) = $dbh->selectrow_array(
        'SELECT
            COUNT(*) FILTER (WHERE status = ?),
            COUNT(*) FILTER (WHERE status = ?)
         FROM fpl_reminders WHERE gameweek = 4',
        undef, 'sent', 'suppressed'
    );

    is( $sent, 1, 'due_reminders: nearest offset sent' );
    is( $suppressed, 2, 'due_reminders: other offsets suppressed' );
}

######
# TEST announce_changes dedupes
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    my $notifier = RemindersTest::Notifier->new;
    my $reminders = _reminders($dbh, $notifier, []);

    my $changes = [{
        season   => 2026,
        gameweek => 5,
        kind     => 'waivers',
        old      => '2026-09-03T17:30:00Z',
        new      => '2026-09-03T19:30:00Z',
    }];

    is( $reminders->announce_changes($changes), 1,
        'announce_changes: sends the moved alert' );

    is( $reminders->announce_changes($changes), 0,
        'announce_changes: does not repeat the same change' );

    like( $notifier->{sent}[0], qr/GW5 waivers deadline moved/,
        'announce_changes: message mentions the moved waiver deadline' );
}

######
# TEST notifier failure is retried
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    my $notifier = RemindersTest::Notifier->new;
    $notifier->{fail} = 1;

    my $rows = [ _deadline(2026, 6, 'classic', $NOW + 2 * 3600) ];
    my $reminders = _reminders($dbh, $notifier, $rows);

    is( $reminders->due_reminders($NOW), 0,
        'due_reminders: nothing sent when the notifier fails' );

    is( _scalar( $dbh,
            'SELECT COUNT(*) FROM fpl_reminders WHERE gameweek = 6 AND status = ?',
            'failed' ),
        1, 'due_reminders: failed row recorded' );

    $notifier->{fail} = 0;

    is( $reminders->due_reminders($NOW), 1,
        'due_reminders: retried on the next tick after a failure' );

    is( _scalar( $dbh,
            'SELECT COUNT(*) FROM fpl_reminders WHERE gameweek = 6 AND status = ?',
            'sent' ),
        1, 'due_reminders: sent row replaces the failed row' );
}

######
# TEST moved deadline re-arms its offsets
######

{
    my $db  = Mandyville::Database->new;
    my $dbh = $db->rw_db_handle();

    my $notifier = RemindersTest::Notifier->new;
    my $rows = [ _deadline(2026, 7, 'classic', $NOW + 2 * 3600) ];
    my $reminders = _reminders($dbh, $notifier, $rows);

    $reminders->due_reminders($NOW);
    is( scalar @{$notifier->{sent}}, 1, 'moved deadline: first reminder sent' );

    # The same gameweek now has a later deadline; the old 2h reminder row
    # no longer matches, so a fresh reminder fires for the new time.
    my $moved = [ _deadline(2026, 7, 'classic', $NOW + 3 * 3600) ];
    $reminders = _reminders($dbh, $notifier, $moved);

    is( $reminders->due_reminders($NOW + 3600), 1,
        'moved deadline: offset re-armed for the new deadline' );

    is( scalar @{$notifier->{sent}}, 2,
        'moved deadline: second message sent' );
}

done_testing();
