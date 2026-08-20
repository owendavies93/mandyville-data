package Mandyville::Reminders::Message;

use Mojo::Base -base, -signatures;

use Const::Fast;
use DateTime;
use DateTime::TimeZone;

const my $DEFAULT_TIMEZONE => 'Europe/London';

=head1 NAME

  Mandyville::Reminders::Message - build reminder message text

=head1 SYNOPSIS

  use Mandyville::Reminders::Message;
  my $text = Mandyville::Reminders::Message->render(
      $deadline, $context, $config
  );

=head1 DESCRIPTION

  Renders the text of a reminder from a deadline and a context hashref of
  already-gathered enrichment data. The context is built by
  Mandyville::Reminders so that this module stays a pure formatter and is
  easy to unit test.

=head1 METHODS

=over

=item render ( DEADLINE, CONTEXT, CONFIG )

  Return the reminder text for C<DEADLINE> (a hashref with C<season>,
  C<gameweek>, C<kinds>, C<deadline> and C<deadline_epoch>), using the
  enrichment data in C<CONTEXT>. C<CONFIG> is the full mandyville config,
  used for the display timezone.

=cut

sub render($class, $deadline, $context, $config) {
    my $tz_name = $config->{reminders}{timezone} // $DEFAULT_TIMEZONE;
    my $tz = DateTime::TimeZone->new(name => $tz_name);

    my $dt = DateTime->from_epoch(epoch => $deadline->{deadline_epoch})
        ->set_time_zone($tz);

    my $label = _kind_label($deadline->{kinds});

    my @lines = (
        sprintf('⏰ %s GW%d deadline: %s',
            $label, $deadline->{gameweek}, $dt->strftime('%a %d %b %H:%M %Z')),
    );

    my $remaining = $deadline->{deadline_epoch} - ($context->{now} // time());
    push @lines, _remaining($remaining);

    foreach my $section (qw(classic draft waivers)) {
        push @lines, @{$context->{$section} // []};
    }

    return join "\n", @lines;
}

sub _kind_label($kinds) {
    my @kinds = @{$kinds // []};

    return 'FPL' if _has(\@kinds, 'classic') && _has(\@kinds, 'draft');
    return 'Draft' if _has(\@kinds, 'draft');
    return 'FPL' if _has(\@kinds, 'classic');
    return 'Waivers' if _has(\@kinds, 'waivers');
    return 'FPL';
}

sub _has($kinds, $wanted) {
    return grep { $_ eq $wanted } @$kinds;
}

sub _remaining($seconds) {
    return 'Deadline has passed' if $seconds <= 0;

    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);

    return sprintf('Time remaining: %dh %dm', $hours, $minutes)
        if $hours > 0;
    return sprintf('Time remaining: %dm', $minutes);
}

=back

=cut

1;
