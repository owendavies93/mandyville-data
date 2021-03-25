#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::Exception;
use Test::More;

######
# TEST includes/requires
######

use_ok 'Mandyville::API';
require_ok 'Mandyville::API';

use Mandyville::API;

######
# TEST _get
######

{
    my $api = Mandyville::API->new;

    throws_ok { $api->_get('test') } qr/not implemented/,
                '_get: correctly dies';
}

######
# TEST _rate_limit
######

{
    my $api = Mandyville::API->new;

    throws_ok { $api->_rate_limit() } qr/not implemented/,
                '_rate_limit: correctly dies';
}

done_testing();

