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

=item competition_season_matches( ID, SEASON )

  Fetch the matches for the competition associated with C<ID> in
  the season C<SEASON>. Note that C<ID> is the football data ID
  for the competition here, and not the C<id> field in the
  mandyville database.

  C<SEASON> should be defined as a YYYY format year, and is the
  year that the season started in. So for the 2020-2021 season,
  you would provide C<2020>.

=cut

# TODO: deal with error states when season is out of range
sub competition_season_matches($self, $id, $season) {
    my $response = $self->_get("competitions/$id/matches?season=$season");

    if (defined $response->{error}) {
        if ($response->{error} == 404) {
            croak "Not found: " . $response->{message};
        } elsif ($response->{error} == 403) {
            croak "Restricted: " . $response->{message};
        }

        die "Unknown error from API: $response->{message}";
    }

    return $response;
}

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
    )->res->body;

    my $fh = File::Temp->new( UNLINK => 0, SUFFIX => '.json' );
    $self->cache->{$path} = $fh->filename;
    print $fh $json;
    return decode_json($json);
}

1;
