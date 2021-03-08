#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::More;
use Test::Exception;

######
# TEST requires/includes
######

use_ok 'Mandyville::Config';
require_ok 'Mandyville::Config';

use Mandyville::Config qw(config);

######
# TEST config
######

{
    my $filename = 'etc/not_found.yaml';

    dies_ok { config($filename) } 'config: dies with invalid filename';

    $filename = '/tmp';

    dies_ok { config($filename) } 'config: dies with file at high depth';

    ok( config(), 'config: finds valid config' );

    my $config_hash = config();

    cmp_ok( $config_hash->{football_data}->{api_token}, 'eq', 'changeme',
            'config: correct values are loaded' );
}

done_testing();
