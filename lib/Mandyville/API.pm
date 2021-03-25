package Mandyville::API;

use Mojo::Base -base, -signatures;

use Carp;
use Const::Fast;
use Mojo::File;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Message::Response;
use Mojo::UserAgent;
use Test::MockObject::Extends;

=head1 NAME

  Mandyville::API - base class for all API interaction

=head1 SYNOPSIS

  use Mandyville::API::Foo;
  my $api = Mandyville::API::Foo->new;
  $api->get('bar') // calls Mandyville::API::get()

=head1 DESCRIPTION

  This module provides methods for fetching and parsing information
  from various APIs. Handles all the caching and JSON decoding. API
  modules should extend this module, call get() to fetch information
  from APIs, and implement _get() to actually deal with any
  API-specific fetching logic.

=cut

const my $EXPIRY_TIME => 60 / 24 / 60; # 60 minutes in days

has 'cache' => sub { {} };
has 'ua'    => sub { Mojo::UserAgent->new->connect_timeout(20) };

=head1 METHODS

=over

=item get ( PATH )

  Get the JSON response from C<PATH>. First check the cache to see
  if it exists in there. If the exact path has been fetched by this
  instance in the past hour, return the cached JSON from disk. Else,
  call _rate_limit(), call _get(), and stores the response in the
  cache on disk. Finally, decodes and returns the JSON.

=cut

sub get($self, $path) {
    if (defined $self->cache->{$path}) {
        my $cache_path = $self->cache->{$path};
        if (-f $cache_path && -M $cache_path <= $EXPIRY_TIME) {
            my $json = Mojo::File->new($cache_path)->slurp;
            return decode_json($json);
        }
    }

    # If we've made the maximum allowed requests in the last minute,
    # limit ourselves for the minimum required time.
    $self->_rate_limit;

    my $json = $self->_get($path);

    my $fh = File::Temp->new( UNLINK => 0, SUFFIX => '.json' );
    $self->cache->{$path} = $fh->filename;
    print $fh $json;
    return decode_json($json);
}

=back

=cut

sub _get($self, $path) {
    croak "_get() is not implemented in superclass!";
}

sub _get_tx($self, $body) {
    my $mock_tx = Test::MockObject::Extends->new( 'Mojo::Transaction::HTTP' );

    $mock_tx->mock( 'res', sub {
        my $res = Mojo::Message::Response->new;
        $res->parse("HTTP/1.0 200 OK\x0d\x0a");
        $res->parse("Content-Type: text/plain\x0d\x0a\x0d\x0a");
        $res->parse(encode_json($body));
        return $res;
    });

    return $mock_tx;
}

sub _rate_limit($self) {
    croak "_rate_limit() is not implemented in superclass!";
}

1;
