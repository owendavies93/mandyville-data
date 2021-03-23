package Mandyville::Players;

use Mojo::Base -base, -signatures;

use Mandyville::Countries;
use Mandyville::Database;

use Carp;
use SQL::Abstract::More;

=head1 NAME

  Mandyville::Players - fetch and store player data

=head1 SYNOPSIS

  use Mandyville::Players;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $teams = Mandyville::Teams->new({
      dbh  => $dbh,
      sqla => $sqla,
  });

  my $comps = Mandyville::Competitions->new({});

  my $fixtures = Mandyville::Fixtures->new({
      comps => $comps,
      dbh   => $dbh,
      sqla  => $sqla,
      teams => $teams,
  });

  my $players = Mandyville::Players->new({
      api       => Mandyville::API::FootballData->new,
      comps     => $comps,
      countries => Mandyville::Countries->new,
      fixtures  => $fixtures,
      dbh       => $dbh,
      sqla      => $sqla,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing player data,
  including player fixture data. It currently uses the football-data
  API for this, but will eventually use the understat data and the FPL
  API as well.

=head1 METHODS

=over

=item api

  An instance of Mandyville::API::FootballData

=item comps

  An instance of Mandyville::Competitions.

=item countries

  An instance of Mandyville::Countries.

=item dbh

  A read-write handle to the Mandyville database.

=item fixtures

  An instance of Mandyville::Fixtures.

=item sqla

  An instance of SQL::Abstract::More.

=item teams

  An instance of Mandyville::Teams.

=cut

has 'api'       => sub { shift->{api} };
has 'comps'     => sub { shift->{comps} };
has 'countries' => sub { shift->{countries} };
has 'dbh'       => sub { shift->{dbh} };
has 'fixtures'  => sub { shift->{fixtures} };
has 'sqla'      => sub { shift->{sqla} };
has 'teams'     => sub { shift->{teams} };

=item new ([ OPTIONS ])

  Creates a new instance of the module, and sets the various required
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

    * dbh  => A read-write handle to the Mandyville database
    * sqla => An instance of SQL::Abstract::More

  If these options aren't passed in, they will be instantied by this
  method. However, it's recommended to pass these options in for
  performance and memory usage reasons.

=cut

sub new($class, $options) {
    $options->{api}  //= Mandyville::API::FootballData->new;
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    $options->{countries} //= Mandyville::Countries->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{comps} //= Mandyville::Competitions->new({
        api       => $options->{api},
        countries => $options->{countries},
        dbh       => $options->{dbh},
        sqla      => $options->{sqla},
    });

    $options->{teams} //= Mandyville::Teams->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{fixtures} //=Mandyville::Fixtures->new({
        comps => $options->{comps},
        dbh   => $options->{dbh},
        sqla  => $options->{sqla},
        teams => $options->{teams},
    });

    my $self = {
        api       => $options->{api},
        comps     => $options->{comps},
        countries => $options->{countries},
        dbh       => $options->{dbh},
        fixtures  => $options->{fixtures},
        sqla      => $options->{sqla},
        teams     => $options->{teams},
    };

    bless $self, $class;
    return $self;
}

=item get_by_football_data_id ( FOOTBALL_DATA_ID )

  Fetch the player associated with the given C<FOOTBALL_DATA_ID>. Does
  no insertion into the database; returns undef if no player is found,
  returns the mandyville database ID of the found player if a player is
  found.

=cut

sub get_by_football_data_id($self, $football_data_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'players',
        -where   => {
            football_data_id => $football_data_id,
        },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return $id;
}

=item get_or_insert ( FOOTBALL_DATA_ID, PLAYER_INFO )

  Fetch the player associated with the given C<FOOTBALL_DATA_ID>. If no
  such player is found, insert the player into the database using the
  fields provided in C<PLAYER_INFO>. The C<first_name>, C<last_name>
  and C<country_name> attributes are required for insertion. The
  C<country_name> field should refer to the player's nationality, not
  their country of birth. Returns a hashref of the fetched or inserted
  player information.

=cut

sub get_or_insert($self, $football_data_id, $player_info) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(p.id p.first_name p.last_name c.name) ],
        -from    => [ -join => qw(
            players|p <=>{p.country_id=c.id} countries|c
        )],
        -where   => {
            'p.football_data_id' => $football_data_id,
        }
    );

    my ($id, $first_name, $last_name, $country_name) =
        $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        for (qw(first_name last_name country_name)) {
            croak "missing $_ attribute in player_info param"
                unless defined $player_info->{$_};
        }

        my $country_id =
            $self->countries->get_country_id($player_info->{country_name});

        if (!defined $country_id) {
            $country_id = $self->countries->get_id_for_alternate_name(
                $player_info->{country_name}
            );
        }

        die 'No country with name ' . $player_info->{country_name} . ' found'
            unless defined $country_id;

        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'players',
            -values    => {
                first_name       => $player_info->{first_name},
                last_name        => $player_info->{last_name},
                country_id       => $country_id,
                football_data_id => $football_data_id,
            },
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return {
        id           => $id,
        first_name   => $player_info->{first_name},
        last_name    => $player_info->{last_name},
        country_name => $player_info->{country_name},
    };
}

=item update_fixture_info ( FIXTURE_DATA )

  Process the player data for a fixture, inserting player data where
  necessary. The C<FIXTURE_DATA> paramater should be hashref in the
  same format as the JSON shown in
  football-data.org/documentation/api#match.

  Calls out to the football-data API to fetch player info if the
  player isn't previously known.

=cut

sub update_fixture_info($self, $fixture_data) {
    my $fixture_info = $self->fixtures->process_fixture_data($fixture_data);
    my $fixture_id   = $fixture_info->{id};

    my $home_id = $fixture_info->{home_team_id};
    $self->_process_team_info(
        $fixture_id, $home_id, $fixture_data, $fixture_data->{homeTeam});

    my $away_id = $fixture_info->{away_team_id};
    return $self->_process_team_info(
        $fixture_id, $away_id, $fixture_data, $fixture_data->{awayTeam});
}

sub _process_team_info($self, $fixture_id, $team_id, $fixture_data, $team_info) {
    my $starters = $team_info->{lineup};
    my $subs     = $team_info->{bench};

    my %bookings = map {
        $_->{player}->{id} => $_->{card}
    } @{$fixture_data->{bookings}};

    my %subsOff = map {
        $_->{playerOut}->{id} => $_->{minute}
    } @{$fixture_data->{substitutions}};

    my %subsOn = map {
        $_->{playerIn}->{id} => $_->{minute}
    } @{$fixture_data->{substitutions}};

    # TODO: reduce duplication
    foreach my $player (@$starters) {
        my $player_id = $self->get_by_football_data_id($player->{id});

        $player_id = $self->_get_api_info_and_store($player->{id})->{id}
            if !defined $player_id;

        my $yellow = $self->_has_card($player->{id}, \%bookings, 'YELLOW');
        my $red    = $self->_has_card($player->{id}, \%bookings, 'RED');

        my $minutes_played = exists $subsOff{$player->{id}} ?
                             $subsOff{$player->{id}} : 90;

        my $info = {
            player_id   => $player_id,
            fixture_id  => $fixture_id,
            team_id     => $team_id,
            minutes     => $minutes_played,
            yellow_card => $yellow || 0,
            red_card    => $red || 0,
        };

        $self->_insert_player_fixture($info);
    }

    foreach my $player (@$subs) {
        my $player_id = $self->get_by_football_data_id($player->{id});

        $player_id = $self->_get_api_info_and_store($player->{id})->{id}
            if !defined $player_id;

        my $yellow = $self->_has_card($player->{id}, \%bookings, 'YELLOW');
        my $red    = $self->_has_card($player->{id}, \%bookings, 'RED');

        my $minutes_played = exists $subsOn{$player->{id}} ?
                             90 - $subsOn{$player->{id}} : 0;

        my $info = {
            player_id   => $player_id,
            fixture_id  => $fixture_id,
            team_id     => $team_id,
            minutes     => $minutes_played,
            yellow_card => $yellow || 0,
            red_card    => $red || 0,
        };

        $self->_insert_player_fixture($info);
    }

    return 1;
}

sub _get_api_info_and_store($self, $player_id) {
    my $player_info = $self->_sanitise_name($self->api->player($player_id));

    my $to_insert = {
        first_name   => $player_info->{firstName},
        last_name    => $player_info->{lastName},
        country_name => $player_info->{nationality},
    };
    # TODO: Add insert only mode to save a query
    my $id = $self->get_or_insert($player_id, $to_insert);
    return $id;
}

sub _sanitise_name($self, $player_info) {
    my $first = $player_info->{firstName};
    my $last  = $player_info->{lastName};
    my $full  = $player_info->{name};

    return $player_info if defined $first && defined $last;

    if ($full =~ /\s/) {
        ($first, $last) = split /\s/, $full;
    } elsif (!defined $last) {
        $last = '';
    } elsif (!defined $first) {
        $first = '';
    }

    return {
        firstName   => $first,
        lastName    => $last,
        name        => $full,
        nationality => $player_info->{nationality},
    };
}

sub _has_card($self, $player_id, $booking_info, $colour) {
    return (exists $booking_info->{$player_id}) &&
           ($booking_info->{$player_id} eq $colour . "_CARD");
}

sub _insert_player_fixture($self, $info) {
    my ($stmt, @bind) = $self->sqla->insert(
        -into   => 'players_fixtures',
        -values => $info,
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=back

=cut

1;
