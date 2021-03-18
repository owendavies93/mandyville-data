package Mandyville::Utils;

use Mojo::Base 'Exporter', -signatures;

use Const::Fast;
use Cwd qw(realpath);
use Dir::Self;

our @EXPORT_OK = qw(debug find_file msg);

const my $MAX_DEPTH => 5;

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

=item find_file ( FILE )

  Finds the relative path to C<FILE> from the current directory. Searches
  upwards to 5 levels. If the full relative path from a parent of the
  current directory isn't provided, the file won't be found.

=cut

sub find_file($file) {
    return _find($file, 0, __DIR__);
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

sub _find($file, $depth = 0, $dir = __DIR__) {
    if (-f "$dir/$file") {
        return "$dir/$file";
    } elsif ($dir ne '/' && $depth < $MAX_DEPTH) {
        return _find($file, $depth + 1, realpath("$dir/.."));
    } else {
        die "Could not find '$file' relative to '" . __DIR__ . "'.";
    }
}

sub _script {
    my $name = $0;
    $name =~ s/.*\///g;
    return $name;
}

=back

=cut

1;
