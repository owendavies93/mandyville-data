package Mandyville::Healthcheck;

use Mojo::Base -base, -signatures;

use Mandyville::Config qw(config);

use Const::Fast;
use Mojo::UserAgent;

const my $BASE_URL => 'https://hc-ping.com/';

=head1 NAME

  Mandyville::Healthcheck - send healthchecks.io pings

=head1 SYNOPSIS

  use Mandyville::Healthcheck;
  Mandyville::Healthcheck->new->ping('update-fpl-draft');

=head1 DESCRIPTION

  Sends a healthchecks.io ping for the named job. The ping path is read
  from the C<healthcheck> section of the mandyville config, matching the
  C<bin/send-healthcheck> script's behaviour so crons and the reminder
  daemon share one implementation.

=head1 METHODS

=over

=item ping ( NAME )

  Send a ping for C<NAME>. Dies if there is no ping path configured for
  it.

=cut

sub ping($self, $name) {
    my $config = config();
    my $path = $config->{healthcheck}{$name};

    die "Can't find ping path for $name" unless defined $path;

    my $ua = Mojo::UserAgent->new->connect_timeout(20);
    $ua->get($BASE_URL . $path);

    return;
}

=back

=cut

1;
