package Mandyville::API::FootballData;

use Mojo::Base 'Mandyville::API', -signatures;

use Mandyville::Config qw(config);

use Carp;
use Const::Fast;
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
const my $MAX_REQS    => 30;

has 'conf' => sub {
    my $config_hash = config();
    croak "Missing football-data API token"
        unless defined $config_hash->{football_data}->{api_token};
    return $config_hash;
};

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

sub competition_season_matches($self, $id, $season) {
    my $response = $self->get("competitions/$id/matches?season=$season");

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
    return $self->get('competitions');
}

=item player ( ID )

  Fetch the player data associated with C<ID>

=cut

sub player($self, $id) {
    my $path = "players/$id";
    my $response = $self->get($path);

    if (defined $response->{error}) {
        if ($response->{error} == 404) {
            croak "Not found: " . $response->{message};
        }

        die "Unknown error from API: $response->{message}";
    } elsif (defined $response->{errorCode}) {
        if ($response->{errorCode} == 429) {
            my ($time) = $response->{message} =~ /(\d+)/;
            warn "hit rate limit from API: sleeping $time\n";
            sleep($time);

            delete $self->cache->{$path};
            $response = $self->get($path);
        } else {
            die "Unknown error from API: $response->{message}";
        }
    }

    return $response;
}

=back

=cut

sub _get($self, $path) {
    return $self->ua->get(
        $BASE_URL . $path,
        { 'X-Auth-Token' => $self->conf->{football_data}->{api_token} }
    )->res->body;
}

sub _rate_limit($self) {
    if (!defined $self->{timings}) {
        $self->{timings} = [ time ];
        return 1;
    }

    if (scalar @{$self->{timings}} >= $MAX_REQS) {
        my $now = time;
        my $last_min = $now - 60;

        if ($self->{timings}->[0] >= $last_min) {
            my $diff = 60 - ($now - $self->{timings}->[0]);
            warn "hit rate limit: sleeping $diff\n";
            sleep($diff);
            $now = time;
            $last_min = $now - 60;
        }

        while (scalar @{$self->{timings}} > 0 &&
               $self->{timings}->[0] < $last_min) {
            shift @{$self->{timings}};
        }

        push @{$self->{timings}}, $now;
    } else {
        push @{$self->{timings}}, time;
    }

    return scalar @{$self->{timings}};
}

1;
