#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::Output;
use Test::More;
use Test::Warn;

######
# TEST use/requires
######

use_ok 'Mandyville::Utils';
require_ok 'Mandyville::Utils';

use Mandyville::Utils qw(debug msg);

######
# TEST debug
######

{
    my $msg = 'hello';
    warning_is { debug($msg) } "Utils.t: hello\n", 'debug: correct message';
}

######
# TEST msg
######
{
    my $msg = 'hello';
    stdout_is { msg($msg) } "Utils.t: hello\n", 'msg: correct message';
}

done_testing();

