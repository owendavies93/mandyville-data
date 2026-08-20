package Mandyville::Notifier::Telegram;

use Mojo::Base 'Mandyville::Notifier', -signatures;

use Carp;
use Const::Fast;
use Mojo::JSON qw(decode_json);
use Mojo::UserAgent;

const my $BASE_URL => 'https://api.telegram.org/';
const my $MAX_RETRIES => 3;

=head1 NAME

  Mandyville::Notifier::Telegram - deliver reminders to a Telegram chat

=head1 SYNOPSIS

  use Mandyville::Notifier::Telegram;
  my $telegram = Mandyville::Notifier::Telegram->new({ config => $config });
  $telegram->deliver('Deadline soon!');

=head1 DESCRIPTION

  Sends messages to a Telegram chat using the bot API. The bot token and
  target chat id are read from the config's C<telegram> section. Messages
  are sent as plain text, so player names and news snippets don't need
  any escaping.

=head1 METHODS

=over

=item new ( OPTIONS )

  Creates a new notifier. C<OPTIONS> must contain C<config>, a hashref
  with C<telegram.token> and C<telegram.chat_id>. Dies if either is
  missing.

=item deliver ( TEXT )

  Send C<TEXT> to the configured chat. Returns true on success. On
  failure the request is retried a few times, honouring Telegram's
  C<retry_after> on rate-limit responses; returns false if the message
  could not be delivered.

=cut

has 'config' => sub { shift->{config} };
has 'ua'     => sub { Mojo::UserAgent->new->connect_timeout(20) };

sub new($class, $options) {
    my $self = $class->SUPER::new($options);

    my $token   = $self->config->{telegram}{token};
    my $chat_id = $self->config->{telegram}{chat_id};

    croak 'Missing telegram.token in config' unless defined $token;
    croak 'Missing telegram.chat_id in config' unless defined $chat_id;

    return $self;
}

sub deliver($self, $text) {
    my $token   = $self->config->{telegram}{token};
    my $chat_id = $self->config->{telegram}{chat_id};

    # Messages are plain text: no parse mode is set, so player names and
    # news snippets containing & or < don't need escaping and can't
    # trigger a parse error from Telegram.
    my $payload = {
        chat_id                  => $chat_id,
        text                     => $text,
        disable_web_page_preview => 1,
    };

    my $url = $BASE_URL . "bot$token/sendMessage";

    my $attempts = 0;
    while ($attempts++ < $MAX_RETRIES) {
        my $tx = $self->ua->post($url => json => $payload);
        my $res = $tx->res;
        my $code = $res->code // 0;

        if ($code >= 200 && $code < 300) {
            return 1;
        }

        # A 429 response includes retry_after, which we honour before
        # trying again. Other server errors get a short pause.
        if ($code == 429 || $code >= 500) {
            my $retry_after = 1;
            if ($code == 429) {
                my $body = eval { decode_json($res->body) };
                $retry_after = $body->{parameters}{retry_after} // 1
                    if ref $body eq 'HASH';
            }

            sleep $retry_after;
            next;
        }

        # Client errors (bad token, bad chat) will never succeed.
        return 0;
    }

    return 0;
}

=back

=cut

1;
