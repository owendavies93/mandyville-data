#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::Notifier::Telegram;

use Mojo::Message::Response;
use Test::Exception;
use Test::MockObject::Extends;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Notifier::Telegram';
require_ok 'Mandyville::Notifier::Telegram';

my $CONFIG = {
    telegram => {
        token   => '123:abc',
        chat_id => '456',
    },
};

sub _res($code, $body = '') {
    my $res = Mojo::Message::Response->new;
    $res->parse("HTTP/1.0 $code \x0d\x0a\x0d\x0a");
    $res->parse($body) if length $body;
    return $res;
}

sub _mock_ua($api, $res) {
    my $tx = Test::MockObject::Extends->new( 'Mojo::Transaction::HTTP' );
    $tx->mock( 'res', sub { $res });

    my $ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    $ua->mock( 'post', sub { return $tx; });

    $api->ua($ua);
    return $ua;
}

######
# TEST construction
######

{
    dies_ok { Mandyville::Notifier::Telegram->new({ config => {} }) }
        'new: dies without a token';
}

######
# TEST send
######

{
    my $api = Mandyville::Notifier::Telegram->new({ config => $CONFIG });

    my $ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    my ($seen_url, $seen_payload);
    $ua->mock( 'post', sub {
        $seen_url = $_[1];
        my %args = @_[2 .. $#_];
        $seen_payload = $args{json};
        my $tx = Test::MockObject::Extends->new( 'Mojo::Transaction::HTTP' );
        $tx->mock( 'res', sub { _res(200, '{"ok":true}') });
        return $tx;
    });
    $api->ua($ua);

    ok( $api->deliver('hello'), 'send: returns true on success' );

    like( $seen_url, qr{/bot123:abc/sendMessage$}, 'send: correct bot URL' );
    is( $seen_payload->{chat_id}, '456', 'send: chat id passed' );
    ok( !exists $seen_payload->{parse_mode}, 'send: no parse mode set' );
}

{
    my $api = Mandyville::Notifier::Telegram->new({ config => $CONFIG });

    _mock_ua($api, _res(400, '{"ok":false}'));

    ok( !$api->deliver('hello'), 'send: returns false on a client error' );
}

{
    my $api = Mandyville::Notifier::Telegram->new({ config => $CONFIG });

    # First a 429 with retry_after, then success.
    my $ua = Test::MockObject::Extends->new( 'Mojo::UserAgent' );
    my $calls = 0;
    $ua->mock( 'post', sub {
        $calls++;
        my $res = $calls == 1
            ? _res(429, '{"ok":false,"parameters":{"retry_after":0}}')
            : _res(200, '{"ok":true}');
        my $tx = Test::MockObject::Extends->new( 'Mojo::Transaction::HTTP' );
        $tx->mock( 'res', sub { $res });
        return $tx;
    });
    $api->ua($ua);

    ok( $api->deliver('hello'), 'send: retries after a 429' );
    cmp_ok( $calls, '==', 2, 'send: made two attempts' );
}

done_testing();
