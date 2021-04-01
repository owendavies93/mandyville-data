#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::Exception;
use Test::Output;
use Test::MockTime qw(set_absolute_time);
use Test::More;
use Test::Warn;

######
# TEST use/requires
######

use_ok 'Mandyville::Utils';
require_ok 'Mandyville::Utils';

use Mandyville::Utils qw(current_season debug find_file msg);

######
# TEST debug
######

{
    my $msg = 'hello';
    warning_is { debug($msg) } "Utils.t: hello\n", 'debug: correct message';
}

######
# TEST find_file
######

{
    my $filename = 'etc/not_found.yaml';

    dies_ok { find_file($filename) } 'find_file: dies with invalid filename';

    $filename = '/tmp';

    dies_ok { find_file($filename) } 'find_file: dies with file at high depth';

    $filename = 'etc/mandyville/config.yaml';

    ok( find_file($filename), 'find_file: finds valid path' );
}

######
# TEST msg
######

{
    my $msg = 'hello';
    stdout_is { msg($msg) } "Utils.t: hello\n", 'msg: correct message';
}

######
# TEST current_season
######

{
    set_absolute_time('2020-01-01T00:00:00Z');
    cmp_ok( current_season, '==', 2019, 'current_season: correct year' );

    set_absolute_time('2020-08-01T00:00:00Z');
    cmp_ok( current_season, '==', 2020, 'current_season: correct year' );
}

done_testing();

