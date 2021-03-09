package Mandyville::API::FootballData;

use Mojo::Base -base, -signatures;

use Mandyville::Config qw(config);

use Carp;
use Const::Fast;
use File::Temp;
use Mojo::File;
use Mojo::JSON qw(decode_json);
use Mojo::UserAgent;

=head1 NAME

  Mandyville::API::FootballData - interact with the football-data.org API

=head1 SYNOPSIS

  use Mandyville::API::FootballData;
  my $api = Mandyville::API::FootballData->new;

=head1 DESCRIPTION

  This module provides methods for fetching and parsing information from the
  football-data.org API. It does a lot of caching to avoid hitting the API
  too regularly. Kudos to Daniel from football-data.org for providing such
  a rich source of data for no cost!

=cut

const my $BASE_URL    => "http://api.football-data.org/v2/";
const my $EXPIRY_TIME => 60 / 24 / 60; # 60 minutes in days

has 'conf' => sub {
    my $config_hash = config();
    croak "Missing football-data API token"
        unless defined $config_hash->{football_data}->{api_token};
    return $config_hash;
};

has 'cache'  => sub { {} };
has 'ua'     => sub { Mojo::UserAgent->new->connect_timeout(20) };

=head1 METHODS

=over

=item competitions

  Fetch the top level competition data for all known competitions

=cut

sub competitions($self) {
    return $self->_get('competitions');
}

=back

=cut

sub _get($self, $path) {
    if (defined $self->cache->{$path}) {
        my $cache_path = $self->cache->{$path};
        if (-f $cache_path && -M $cache_path <= $EXPIRY_TIME) {
            my $json = Mojo::File->new($cache_path)->slurp;
            return decode_json($json);
        }
    }

    my $json = $self->ua->get(
        $BASE_URL . $path,
        { 'X-Auth-Token' => $self->conf->{football_data}->{api_token} }
    );

    my $fh = File::Temp->new( UNLINK => 0, SUFFIX => '.json' );
    $self->cache->{$path} = $fh->filename;
    print $fh $json;
    return decode_json($json);
}

1;
