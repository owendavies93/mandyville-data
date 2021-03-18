#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::Exception;
use Test::Output;
use Test::More;
use Test::Warn;

######
# TEST use/requires
######

use_ok 'Mandyville::Utils';
require_ok 'Mandyville::Utils';

use Mandyville::Utils qw(debug find_file msg);

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

done_testing();

