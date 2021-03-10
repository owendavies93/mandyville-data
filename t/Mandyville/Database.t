#!/usr/bin/env perl

use Mojo::Base -strict;

use Test::More;
use Test::Exception;

######
# TEST requires/includes
######

use_ok 'Mandyville::Database';
require_ok 'Mandyville::Database';

######
# TEST _random_database_name
######

{
    my $db = Mandyville::Database->new;
    my $name = $db->_random_database_name;

    like( $name, qr/^mandyville_test_/,
          '_random_database_name: name matches expected' );

    cmp_ok( $name, 'ne', $db->_random_database_name,
            '_random_database_name: names are not equal' );
}

######
# TEST _find_meta_directory
######

{
    my $db  = Mandyville::Database->new;
    my $dir = $db->_find_meta_directory;

    ok( $dir, '_find_meta_directory: finds directory' );

    like( $dir, qr/meta\//, '_find_meta_directory: correct bottom level dir' );
}

######
# TEST _db_handle
######

{ 
    my $db = Mandyville::Database->new;
    my $test_dbh = $db->_db_handle();    

    my ($res) =  $test_dbh->selectrow_array(
        'SELECT 1 FROM countries LIMIT 1'
    );
    
    cmp_ok( $res, '==', 1, '_db_handle: test schema correctly created' );

    ($res) = $test_dbh->selectrow_array(
        'SELECT COUNT(1) FROM countries'
    );

    cmp_ok( $res, '>', 0, '_db_handle: test data correctly populated' );

    my $status = $test_dbh->do('CREATE TABLE test (test_col INT)' );

    ok( $status, '_db_handle: test db handle is read-write' );

    $test_dbh = $db->_db_handle();

    ($res) = $test_dbh->selectrow_array('SELECT COUNT(1) FROM test');

    cmp_ok( $res, '==', 0, '_db_handle: test db is not recreated' );
}

######
# TEST DESTROY
######

{
    my $db = Mandyville::Database->new;
    my $test_dbh = $db->_db_handle();
    $db->DESTROY;

    dies_ok { $test_dbh->do('SELECT 1'); } 'DESTROY: test dbh is destroyed';

    # Prevent a crash when we deconstruct the object for real
    delete $db->{test_db_handle};
}

######
# TEST ro_db_handle
######

{
    my $db = Mandyville::Database->new;
    my $test_dbh = $db->ro_db_handle();

    # ro is actually rw in a test environment...
    $test_dbh->do('CREATE TABLE test (test_col INT)' );

    $test_dbh = $db->ro_db_handle();

    my ($res) = $test_dbh->selectrow_array('SELECT COUNT(1) FROM test');

    cmp_ok( $res, '==', 0, 'ro_db_handle: handle is not recreated' );
}

######
# TEST rw_db_handle
######

{
    my $db = Mandyville::Database->new;
    my $test_dbh = $db->rw_db_handle();

    $test_dbh->do('CREATE TABLE test (test_col INT)' );

    $test_dbh = $db->rw_db_handle();

    my ($res) = $test_dbh->selectrow_array('SELECT COUNT(1) FROM test');

    cmp_ok( $res, '==', 0, 'rw_db_handle: handle is not recreated' );
}


done_testing();
