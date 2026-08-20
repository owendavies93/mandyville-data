package Mandyville::Notifier;

use Mojo::Base -base, -signatures;

use Carp;

=head1 NAME

  Mandyville::Notifier - base class for reminder delivery backends

=head1 SYNOPSIS

  use Mandyville::Notifier;
  my $notifier = Mandyville::Notifier->factory($config);

=head1 DESCRIPTION

  Provides the common interface for delivering reminder messages. The
  concrete delivery backends (Telegram, and potentially ntfy or email in
  the future) are subclasses that implement C<deliver>. C<factory> builds
  the backend named in the config's C<reminders.notifier> key.

=head1 METHODS

=over

=item factory ( CONFIG )

  Build and return a notifier for the backend configured in
  C<CONFIG>'s C<reminders.notifier> key (defaults to C<telegram>).

=cut

sub factory($class, $config) {
    my $name = $config->{reminders}{notifier} // 'telegram';

    my %backends = (
        telegram => 'Mandyville::Notifier::Telegram',
    );

    croak "Unknown notifier backend '$name'" unless exists $backends{$name};

    require Mandyville::Notifier::Telegram if $name eq 'telegram';

    my $backend = $backends{$name};
    return $backend->new({ config => $config });
}

=item new ( OPTIONS )

  Create a notifier, storing C<OPTIONS> as attributes. Subclasses may
  call this via C<SUPER::new> before validating their own options.

=cut

sub new($class, $options) {
    my $self = { %$options };
    bless $self, $class;
    return $self;
}

=item deliver ( TEXT )

  Deliver C<TEXT>. Subclasses must implement this; the base class croaks.

=cut

sub deliver($self, $text) {
    croak 'deliver() is not implemented in the notifier superclass';
}

=back

=cut

1;
