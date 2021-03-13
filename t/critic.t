#!/usr/bin/env perl

use strict;
use warnings;

use Test::Perl::Critic (-profile => 't/criticrc');

all_critic_ok(qw( bin lib ));
