package Mandyville::Config;

use Mojo::Base 'Exporter', -signatures;

use Mandyville::Utils qw(find_file);

use YAML::XS qw(LoadFile);
use Const::Fast;

our @EXPORT_OK = qw(config);

const my $PATH => $ENV{MANDYVILLE_CONFIG} || '/etc/mandyville/config.yaml';

=head1 NAME

  Mandyville::Config - read the mandyville config

=head1 SYNOPSIS

  use Mandville::Config qw(config);
  my $config_hash = config();

=head1 DESCRIPTION

  This module provides a read-only interface to the mandyville configuration
  stored in a YAML file on disk.

=head1 METHODS

=over

=item config ( [ PATH ] )

  Return a hashref representing the config parsed from YAML. Will prioritise
  the PATH parameter if provided, then the MANDYVILLE_CONFIG environement
  variable, then the default path in /etc/mandyville/.

  If we're found to be under a test environment (that is, the
  $Test::Builder::VERSION variable is defined), attempt to load the local
  config from the current repo. If we can't find the local config, die.

=cut

sub config($path = $PATH) {
    if (defined $Test::Builder::VERSION) {
        return LoadFile(find_file($path));
    }

    return LoadFile($path)
}

=back

=cut

1;

