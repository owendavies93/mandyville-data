#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::Reminders::Message;

use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Reminders::Message';
require_ok 'Mandyville::Reminders::Message';

my $CONFIG = {
    reminders => { timezone => 'Europe/London' },
};

######
# TEST render
######

{
    my $deadline = {
        season         => 2026,
        gameweek       => 3,
        kinds          => [qw(classic draft)],
        deadline       => '2026-09-04T17:30:00Z',
        deadline_epoch => 1_765_000_000,
    };

    my $context = {
        now     => 1_764_999_000,
        classic => ['Classic squad: 15 players', '≈ 1 free transfer(s) available'],
        draft   => ['Draft squad: 15 players'],
        waivers => [],
    };

    my $text = Mandyville::Reminders::Message->render(
        $deadline, $context, $CONFIG
    );

    like( $text, qr/⏰ FPL GW3 deadline:/, 'render: combined classic+draft label' );
    like( $text, qr/Classic squad: 15 players/, 'render: classic section included' );
    like( $text, qr/Draft squad: 15 players/, 'render: draft section included' );
    like( $text, qr/Time remaining: 16m/, 'render: time remaining rounded down' );
}

{
    my $deadline = {
        season         => 2026,
        gameweek       => 3,
        kinds          => ['waivers'],
        deadline       => '2026-09-03T17:30:00Z',
        deadline_epoch => 1_764_913_800,
    };

    my $context = {
        now     => 1_764_913_000,
        classic => [],
        draft   => [],
        waivers => ['Waiver pick: 3'],
    };

    my $text = Mandyville::Reminders::Message->render(
        $deadline, $context, $CONFIG
    );

    like( $text, qr/⏰ Waivers GW3 deadline:/, 'render: waiver label' );
    like( $text, qr/Waiver pick: 3/, 'render: waiver section included' );
}

{
    my $deadline = {
        season         => 2026,
        gameweek       => 4,
        kinds          => ['draft'],
        deadline       => '2026-09-11T17:30:00Z',
        deadline_epoch => 1_765_512_000,
    };

    my $text = Mandyville::Reminders::Message->render(
        $deadline, { now => 1_765_512_001 }, $CONFIG
    );

    like( $text, qr/Deadline has passed/, 'render: past deadline noted' );
}

done_testing();
