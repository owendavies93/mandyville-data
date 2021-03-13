package Mandyville::Utils;

use Mojo::Base 'Exporter', -signatures;

our @EXPORT_OK = qw(debug msg);

=head1 NAME

  Mandyville::Utils - provide utility methods

=head1 SYNOPSIS

  use Mandyville::Utils qw(msg);
  ...
  msg('we did it!');

=head1 DESCRIPTION

  This module provides common utility methods for use across mandyville
  perl code.

=head1 METHODS

=over

=item debug ( TEXT )

  Print a message to STDERR, including the name of the script that the
  message originated from. Returns the warned message including the 
  script name.

=cut

sub debug($text) {
    my $msg = _script() . ": $text";
    warn "$msg\n";
    return $msg;
}

=item msg ( TEXT )

  Print a message to STDOUT, including the name of the script that the
  message originated from. Returns the printed message including the
  script name.

=cut

sub msg($text) {
    my $msg = _script() . ": $text";
    say $msg;
    return $msg;
}

sub _script {
    my $name = $0;
    $name =~ s/.*\///g;
    return $name;
}

=back

=cut

1;
