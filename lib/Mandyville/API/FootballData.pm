package Mandyville::API::FootballData;

use Mojo::Base -base, -signatures;

use Mandyville::Config qw(config);

use Carp;
use Const::Fast;
use File::Temp;
use Mojo::File;
use Mojo::JSON qw(decode_json);
use Mojo::UserAgent;
use Time::HiRes qw(time sleep);

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
const my $MAX_REQS    => 30;

has 'conf' => sub {
    my $config_hash = config();
    croak "Missing football-data API token"
        unless defined $config_hash->{football_data}->{api_token};
    return $config_hash;
};

has 'cache' => sub { {} };
has 'ua'    => sub { Mojo::UserAgent->new->connect_timeout(20) };

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
        }

        die "Unknown error from API: $response->{message}";
    } elsif (defined $response->{errorCode}) {
        if ($response->{errorCode} == 403) {
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

=item player ( ID )

  Fetch the player data associated with C<ID>

=cut

sub player($self, $id) {
    my $response = $self->_get("players/$id");

    if (defined $response->{error}) {
        if ($response->{error} == 404) {
            croak "Not found: " . $response->{message};
        }

        die "Unknown error from API: $response->{message}";
    } elsif (defined $response->{errorCode}) {
        # We're not expecting 403s from this endpoint so always
        # die with an unknown error
        die "Unknown error from API: $response->{message}";
    }

    return $response;
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

    # If we've made the maximum allowed requests in the last minute,
    # limit ourselves for the minimum required time.
    $self->_rate_limit;

    my $json = $self->ua->get(
        $BASE_URL . $path,
        { 'X-Auth-Token' => $self->conf->{football_data}->{api_token} }
    )->res->body;

    my $fh = File::Temp->new( UNLINK => 0, SUFFIX => '.json' );
    $self->cache->{$path} = $fh->filename;
    print $fh $json;
    return decode_json($json);
}

sub _rate_limit($self) {
    if (!defined $self->{timings}) {
        $self->{timings} = [ time ];
        return 1;
    }

    if (scalar @{$self->{timings}} >= $MAX_REQS) {
        my $now = time;
        my $last_min = $now - 60;

        # TODO: You could probably be cleverer about how long to sleep
        # for, but this will do for now.
        if ($self->{timings}->[0] >= $last_min) {
            my $diff = 60 - ($now - $self->{timings}->[0]);
            warn "hit rate limit: sleeping $diff";
            sleep($diff);
        }

        while (scalar @{$self->{timings}} > 0 && $self->{timings}->[0] < $now) {
            shift @{$self->{timings}};
        }

        push @{$self->{timings}}, $now;
    } else {
        push @{$self->{timings}}, time;
    }

    return scalar @{$self->{timings}};
}

1;
