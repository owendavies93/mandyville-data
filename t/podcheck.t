#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Pod;

all_pod_files_ok(qw( bin lib ));

done_testing();
