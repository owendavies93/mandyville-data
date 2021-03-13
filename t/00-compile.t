#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::Compile;

my $test = Test::Compile->new();
$test->all_files_ok();
$test->done_testing();

