package Mandyville::Reminders;

use Mojo::Base -base, -signatures;

use Mandyville::Gameweeks;
use Mandyville::FPLClassic;
use Mandyville::Reminders::Message;
use Mandyville::Utils qw(current_season debug);

use Const::Fast;
use Time::Piece;

const my $DEFAULT_OFFSETS => {
    classic => [24, 12, 2],
    draft   => [24, 12, 2],
    waivers => [24, 2],
};

const my $HORIZON_SECONDS => 7 * 24 * 3600;

=head1 NAME

  Mandyville::Reminders - schedule and send FPL deadline reminders

=head1 SYNOPSIS

  use Mandyville::Reminders;
  my $reminders = Mandyville::Reminders->new({
      dbh      => $dbh,
      notifier => $notifier,
      config   => $config,
  });

  my $sent = $reminders->tick(time());

=head1 DESCRIPTION

  Evaluates the configured reminder offsets against the deadlines stored
  in the database, sends any that have come due via the configured
  notifier, and announces deadline changes. Reminders are recorded in the
  C<fpl_reminders> table so they are only sent once, and a moved deadline
  automatically re-arms its offsets because the reminder key includes the
  deadline value.

=head1 METHODS

=over

=item new ( OPTIONS )

  C<OPTIONS> is a hashref with C<dbh>, C<notifier>, C<config> and
  optionally C<gameweeks> (for injecting a mock), C<season> and
  C<dry_run>. The classic entry is read from C<config>'s
  C<fpl_classic.entry>.

=cut

has 'dbh'      => sub { shift->{dbh} };
has 'notifier' => sub { shift->{notifier} };
has 'config'   => sub { shift->{config} };
has 'season'   => sub { shift->{season} };
has 'dry_run'  => sub { shift->{dry_run} // 0 };

sub new($class, $options) {
    die 'Reminders requires a dbh'  unless defined $options->{dbh};
    die 'Reminders requires config' unless defined $options->{config};

    $options->{season} //= _current_season();
    $options->{gameweeks} //= Mandyville::Gameweeks->new({
        dbh => $options->{dbh},
    });
    $options->{classic} //= Mandyville::FPLClassic->new({
        dbh    => $options->{dbh},
        season => $options->{season},
        entry  => $options->{config}{fpl_classic}{entry},
    }) if defined $options->{config}{fpl_classic}{entry};

    my $self = {
        %$options,
        dbh      => $options->{dbh},
        notifier => $options->{notifier},
        config   => $options->{config},
        season   => $options->{season},
        dry_run  => $options->{dry_run},
    };

    bless $self, $class;
    return $self;
}

=item refresh

  Fetch the latest classic and draft deadlines and store any changes.
  Returns the list of changes (see Mandyville::Gameweeks).

=cut

sub refresh($self) {
    my $gameweeks = $self->{gameweeks};

    $gameweeks->process_gameweeks;
    $gameweeks->process_draft_gameweeks;

    return $gameweeks->last_changes;
}

=item announce_changes ( CHANGES )

  Send a "deadline moved" alert for each change in C<CHANGES>. Returns
  the number of alerts sent. Each alert is recorded with kind
  C<"${kind}_change"> and offset C<-1>, keyed on the new deadline so it
  is only sent once per change.

=cut

sub announce_changes($self, $changes) {
    my $sent = 0;

    foreach my $change (@{$changes // []}) {
        next unless defined $change->{new};

        my $kind = $change->{kind} . '_change';

        my $message = sprintf(
            '⚠️ GW%d %s deadline moved: %s → %s',
            $change->{gameweek}, $change->{kind},
            _format_ts($change->{old} // 'unknown'),
            _format_ts($change->{new}),
        );

        next if $self->_already_recorded(
            $change->{season}, $change->{gameweek}, $kind, -1, $change->{new}
        );

        my $ok = $self->_deliver($message);

        $self->_record(
            $change->{season}, $change->{gameweek}, $kind, -1,
            $change->{new}, $ok ? 'sent' : 'failed', $message
        );

        $sent++ if $ok;
    }

    return $sent;
}

=item due_reminders ( NOW )

  Evaluate every configured reminder offset for the upcoming deadlines
  and send any that are due. If several offsets for the same deadline are
  due at once (for example after a deadline moved or the daemon was
  down), only the one closest to the deadline is sent and the others are
  recorded as suppressed. Returns the number of reminders sent.

=cut

sub due_reminders($self, $now) {
    my $deadlines = $self->{gameweeks}->upcoming_deadlines($now, $HORIZON_SECONDS);
    my $groups = $self->_merge_deadlines($deadlines);

    my $sent = 0;

    foreach my $group (@$groups) {
        my $offsets = $self->_offsets_for($group->{kinds});
        next unless @$offsets;

        my @due;
        foreach my $hours (@$offsets) {
            my $offset_minutes = $hours * 60;
            my $fire = $group->{deadline_epoch} - $hours * 3600;

            next unless $fire <= $now && $now < $group->{deadline_epoch};
            next if $self->_already_recorded(
                $group->{season}, $group->{gameweek}, $group->{kind},
                $offset_minutes, $group->{deadline}
            );

            push @due, {
                offset_minutes => $offset_minutes,
                fire           => $fire,
                hours          => $hours,
            };
        }

        next unless @due;

        # Only the offset closest to the deadline fires; the rest are
        # suppressed so a burst of catch-up reminders becomes one message.
        my @sorted = sort { $b->{fire} <=> $a->{fire} } @due;
        my $send = shift @sorted;

        my $context = $self->_build_context($group);
        my $message = Mandyville::Reminders::Message->render(
            $group, $context, $self->config
        );

        my $ok = $self->_deliver($message);

        $self->_record(
            $group->{season}, $group->{gameweek}, $group->{kind},
            $send->{offset_minutes}, $group->{deadline},
            $ok ? 'sent' : 'failed', $message
        );
        $sent++ if $ok;

        foreach my $skipped (@sorted) {
            $self->_record(
                $group->{season}, $group->{gameweek}, $group->{kind},
                $skipped->{offset_minutes}, $group->{deadline},
                'suppressed', $message
            );
        }
    }

    return $sent;
}

=item tick ( NOW )

  Refresh deadlines, announce any changes and send any due reminders.
  Returns the number of messages sent.

=cut

sub tick($self, $now) {
    my $changes = $self->refresh;
    my $sent = $self->announce_changes($changes);
    $sent += $self->due_reminders($now);
    return $sent;
}

=item pending ( NOW, HORIZON )

  Return the upcoming deadlines and their scheduled reminder times, for
  C<--list> output.

=cut

sub pending($self, $now, $horizon = $HORIZON_SECONDS) {
    my $deadlines = $self->{gameweeks}->upcoming_deadlines($now, $horizon);
    my $groups = $self->_merge_deadlines($deadlines);

    my @pending;
    foreach my $group (@$groups) {
        my $offsets = $self->_offsets_for($group->{kinds});

        my @fires = map {
            { offset_minutes => $_ * 60, fire => $group->{deadline_epoch} - $_ * 3600 }
        } @$offsets;

        push @pending, {
            %$group,
            fires => \@fires,
        };
    }

    return \@pending;
}

=back

=cut

sub _offsets_for($self, $kinds) {
    my $config = $self->config->{reminders}{offsets} // {};
    my @kinds = @{$kinds // []};

    # When the classic and draft deadlines are identical we send one
    # combined message using the classic offsets.
    my $kind = 'classic';
    if (@kinds == 1) {
        $kind = $kinds[0];
    } elsif (@kinds > 1 && !grep({ $_ eq 'classic' } @kinds)) {
        $kind = $kinds[0];
    }

    my $offsets = defined $config->{$kind}
        ? $config->{$kind}
        : $DEFAULT_OFFSETS->{$kind} // [];

    return $offsets // [];
}

sub _merge_deadlines($self, $rows) {
    my %by_epoch;

    foreach my $row (@{$rows // []}) {
        # The trades deadline is stored but we do not remind about it.
        next if $row->{kind} eq 'trades';

        my $key = join ':', $row->{season}, $row->{gameweek}, $row->{deadline_epoch};
        $by_epoch{$key} //= {
            season         => $row->{season},
            gameweek       => $row->{gameweek},
            deadline       => $row->{deadline},
            deadline_epoch => $row->{deadline_epoch},
            kinds          => [],
        };

        push @{$by_epoch{$key}{kinds}}, $row->{kind}
            unless grep { $_ eq $row->{kind} } @{$by_epoch{$key}{kinds}};
    }

    my @groups;
    foreach my $group (values %by_epoch) {
        $group->{kinds} = [sort @{$group->{kinds}}];
        $group->{kind}  = $group->{kinds}[0];
        push @groups, $group;
    }

    return [sort { $a->{deadline_epoch} <=> $b->{deadline_epoch} } @groups];
}

sub _build_context($self, $group) {
    my @kinds = @{$group->{kinds} // []};

    my $context = {
        now => time(),
    };

    if (grep { $_ eq 'classic' } @kinds) {
        $context->{classic} = $self->_classic_context;
    }
    if (grep { $_ eq 'draft' } @kinds) {
        $context->{draft} = $self->_draft_context($group);
    }
    if (grep { $_ eq 'waivers' } @kinds) {
        $context->{waivers} = $self->_waiver_context($group);
    }

    return $context;
}

sub _classic_context($self) {
    return [] unless defined $self->{classic};

    my @lines;
    my $squad = $self->{classic}->current_squad;

    if (@{$squad->{players} // []}) {
        push @lines, sprintf('Classic squad: %d players', scalar @{$squad->{players}});
    }

    push @lines, sprintf('≈ %d free transfer(s) available',
        $self->{classic}->estimated_free_transfers);

    my $chips = $self->{classic}->chips_remaining;
    push @lines, 'Chips remaining: ' . join(', ', @$chips) if @$chips;

    return \@lines;
}

sub _draft_context($self, $group) {
    my $leagues = $self->config->{fpl_draft}{leagues} // [];
    return [] unless @$leagues;

    my @lines;
    foreach my $league (@$leagues) {
        my $entry = $league->{entry};
        next unless defined $entry;

        my $rows = $self->dbh->selectall_arrayref(
            'SELECT p.first_name, p.last_name, a.status, a.chance_of_playing_next,
                    a.news, a.news_return
             FROM fpl_draft_ownership o
             JOIN fpl_draft_entries e ON e.id = o.draft_entry_id
             JOIN players p ON p.id = o.player_id
             LEFT JOIN fpl_player_availability a
                 ON a.player_id = o.player_id AND a.end_time IS NULL
             WHERE e.entry_id = ? AND o.end_time IS NULL
             ORDER BY p.last_name',
            { Slice => {} }, $entry
        );

        my @concerns;
        foreach my $r (@$rows) {
            my $status = $r->{status} // 'a';
            my $chance = $r->{chance_of_playing_next};

            if ($status ne 'a' || (defined $chance && $chance < 100)) {
                my $note = $r->{news} // '';
                $note .= " (back $r->{news_return})" if defined $r->{news_return};
                push @concerns, "$r->{first_name} $r->{last_name}: $note";
            }
        }

        push @lines, 'Draft squad: ' . scalar(@$rows) . ' players';
        push @lines, 'Draft concerns:', @concerns if @concerns;
    }

    return \@lines;
}

sub _waiver_context($self, $group) {
    return [] unless grep { $_ eq 'waivers' } @{$group->{kinds} // []};

    my $leagues = $self->config->{fpl_draft}{leagues} // [];
    return [] unless @$leagues;

    my @lines;
    foreach my $league (@$leagues) {
        my $entry = $league->{entry};
        next unless defined $entry;

        my ($pick) = $self->dbh->selectrow_array(
            'SELECT wo.waiver_pick
             FROM fpl_draft_waiver_order wo
             JOIN fpl_draft_entries e ON e.id = wo.draft_entry_id
             WHERE e.entry_id = ? AND wo.end_time IS NULL',
            undef, $entry
        );

        push @lines, sprintf('Waiver pick: %s', defined $pick ? $pick : 'unknown');
    }

    return \@lines;
}

sub _already_recorded($self, $season, $gameweek, $kind, $offset, $deadline) {
    my ($status) = $self->dbh->selectrow_array(
        'SELECT status FROM fpl_reminders
         WHERE season = ? AND gameweek = ? AND kind = ?
           AND offset_minutes = ? AND deadline = ?',
        undef, $season, $gameweek, $kind, $offset, $deadline
    );

    return 0 unless defined $status;
    return $status eq 'sent' || $status eq 'suppressed';
}

sub _record($self, $season, $gameweek, $kind, $offset, $deadline, $status, $message) {
    return 1 if $self->dry_run;

    $self->dbh->do(
        'INSERT INTO fpl_reminders
           (season, gameweek, kind, offset_minutes, deadline, status,
            channel, message)
         VALUES (?,?,?,?,?,?,?,?)
         ON CONFLICT (season, gameweek, kind, offset_minutes, deadline)
         DO UPDATE SET status = EXCLUDED.status, message = EXCLUDED.message,
                       channel = EXCLUDED.channel, created_at = now()',
        undef, $season, $gameweek, $kind, $offset, $deadline, $status,
        'telegram', $message
    );

    return;
}

sub _deliver($self, $message) {
    if ($self->dry_run || !defined $self->notifier) {
        debug "DRY RUN (no delivery): $message";
        return 1;
    }

    return $self->notifier->deliver($message) ? 1 : 0;
}

sub _current_season {
    return current_season();
}

sub _format_ts($ts) {
    return 'unknown' unless defined $ts;

    my $epoch = _ts_epoch($ts);
    return 'unknown' unless defined $epoch;

    my $t = Time::Piece->gmtime($epoch);
    return $t->strftime('%a %d %b %H:%M');
}

sub _ts_epoch($ts) {
    return $ts if $ts =~ /^\d+$/;

    my $offset;
    if ($ts =~ s/Z$//) {
        $offset = '+0000';
    } elsif ($ts =~ s/([+-]\d\d)(?::?(\d\d))?$//) {
        $offset = sprintf('%s%02d', $1, $2 // 0);
    }

    $ts =~ s/T/ /;

    my $parsed = defined $offset
        ? eval { Time::Piece->strptime("$ts $offset", '%Y-%m-%d %H:%M:%S %z') }
        : eval { Time::Piece->strptime($ts, '%Y-%m-%d %H:%M:%S') };

    return unless $parsed;
    return $parsed->epoch;
}

1;
