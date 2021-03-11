package Mandyville::Database;

use Mojo::Base -base, -signatures;

use Mandyville::Config qw(config);

use Capture::Tiny qw(capture_merged);
use Carp;
use Const::Fast;
use Cwd qw(realpath);
use Dir::Self;
use DBI;
use Try::Tiny;

const my $BASE_DATA => 'base_data.sql';
const my $MAX_DEPTH => 5;
const my $META_DIR  => $ENV{MANDYVILLE_META} // 'meta/';

=head1 NAME

  Mandyville::Database - interact with the mandyville database in perl

=head1 SYNOPSIS

  use Mandyville::Database;
  my $db = Mandyville::Database->new;

=head1 DESCRIPTION

  Provides a handle for accessing the mandyville database with perl code.
  Also provides an interface to a testing database when running in a test
  environment. The testing database handle will always be read-write, since
  it's used to create the database.

  To use this module in testing mode, ensure that the meta submodule is
  checked out and synced. The name of this checkout can be overridden with the
  MANDYVILLE_META environment variable.

  The database host and the database password can be overriden with the
  MANDYVILLE_DB_HOST and MANDYVILLE_DB_PASS environment variables respectively.
  Alternatively, you can override these more permanently in your local YAML
  config file.

=cut

has 'conf' => sub {
    my $config_hash = config();
    croak 'Missing database config' unless defined $config_hash->{database};
    return $config_hash->{database};
};

=head1 METHODS

=over

=item DESTROY

  Drop the test database, if it exists. Returns the output status of this drop
  command. Also disconnect from the control database.

=cut

sub DESTROY($self) {
    # XXX: the Mandyville::Database object needs to be predeclared, otherwise
    #      this is called too early.
    if (defined $Test::Builder::VERSION && defined $self->{test_db_handle}) {
        $self->{test_db_handle}->disconnect
            or warn $self->{test_db_handle}->errstr;

        my $sth = $self->{control_db_handle}->prepare(
            'DROP DATABASE ' . $self->{test_db_name}
        );
        my $status = $sth->execute;

        $self->{control_db_handle}->disconnect
            or warn $self->{control_db_handle}->errstr;

        return $status;
    }
}

=item ro_db_handle
  
  Returns a read-only handle to the mandyville database. Note that in a testing
  environment, this is not a read-only handle! It will have exactly the same
  permissions as the read-write handle.

=cut

sub ro_db_handle($self) {
    return $self->{ro} if defined $self->{ro};
    $self->{ro} = $self->_db_handle(1);
    return $self->{ro};
}

=item rw_db_handle

  Returns a read-write handle to the mandyville database.

=cut

sub rw_db_handle($self) {
    return $self->{rw} if defined $self->{rw};
    $self->{rw} = $self->_db_handle;
    return $self->{rw};
}

=back

=cut

sub _db_handle($self, $ro = 0) {
    my $user = $ro ? $self->conf->{read_user} : $self->conf->{write_user};

    my $db   = $self->conf->{db};
    my $host = $ENV{MANDYVILLE_DB_HOST} // $self->conf->{host};
    my $port = $self->conf->{port}      // 5432;
    my $pass = $ENV{MANDYVILLE_DB_PASS} // $self->conf->{pass};

    my $dsn = $self->_dsn($db, $host, $port);

    my $options = {
        # Automatically commit changes to the database unless transactions
        # are explicity enabled in a scope.
        AutoCommit => 1,

        # Don't print error messages, we're throwing them.
        PrintError => 0,

        # Throw an exception when a database error occurs.
        RaiseError => 1,

        # Include the raw SQL statement that caused the error in the error
        # message.
        ShowErrorStatement => 1,
    };

    # If we're under a testing environment, attempt to create and return
    # a handle to a new database on the same host, which will be dropped
    # when this instance is destroyed
    if (defined $Test::Builder::VERSION) {
        return $self->{test_db_handle} if defined $self->{test_db_handle};

        my $test_dsn  = $self->_dsn('postgres', $host, $port);
        my $test_user = $self->conf->{write_user};
        my $test_dbh  = DBI->connect($test_dsn, $test_user, $pass, $options);

        my $test_db_name = $self->_random_database_name;

        # Create the test database
        try {
            my $sth = $test_dbh->prepare('CREATE DATABASE ' . $test_db_name);
            $sth->execute;
        } catch {
            my $error = $_;
            if ($error =~ /exists/) {
                die $self->_random_database_name . ' already exists!';
            } else {
                die $error;
            }
        };

        # Run the migrations to create the schema
        my $migration_dsn = "postgres://$test_user:$pass" . '@' .
                            "$host:$port/$test_db_name?sslmode=disable";

        my $meta_directory = $self->_find_meta_directory();
        my $path = $meta_directory . "/migrations";

        capture_merged {
            my $status = system(
                'migrate', '-database', $migration_dsn, '-path', $path, 'up'
            );

            if ($status != 0) {
                die "Populating test schema failed: $status";
            }
        };

        # Add the base data to the database
        my $base_data_file = $meta_directory . $BASE_DATA;
        my $status = system(
            "psql $migration_dsn < \Q$base_data_file\E"
        );

        if ($status != 0) {
            die "Loading base data failed: $status";
        }

        # Update the main handle details with the test database
        # Cache the database handle and the database name
        $dsn  = $self->_dsn($test_db_name, $host, $port);
        $user = $test_user;

        $self->{test_db_handle}    = DBI->connect($dsn, $user, $pass, $options);
        $self->{test_db_name}      = $test_db_name;
        $self->{control_db_handle} = $test_dbh;

        return $self->{test_db_handle};
    }

    return DBI->connect($dsn, $user, $pass, $options);
}

sub _dsn($self, $db, $host, $port) {
    return "dbi:Pg:database=$db;host=$host;port=$port";
}

sub _find_meta_directory($self, $depth = 0, $dir = __DIR__) {
    if (-d "$dir/$META_DIR") {
        return "$dir/$META_DIR";
    } elsif ($dir ne '/' && $depth < $MAX_DEPTH) {
        return $self->_find_meta_directory($depth + 1, realpath("$dir/.."));
    } else {
        die "Could not find '$META_DIR' directory relative to '" . __DIR__ . "'";
    }
}

sub _random_database_name($self) {
    my $rand_int = int(rand(1_000_000));
    return "mandyville_test_$rand_int";
}

1;
