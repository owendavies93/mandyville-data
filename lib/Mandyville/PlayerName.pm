package Mandyville::PlayerName;

use Mojo::Base -strict, -signatures;

use Const::Fast;
use Exporter 'import';
use List::Util qw(max);
use Text::Levenshtein::XS ();
use Unicode::Normalize qw(NFKD);

=head1 NAME

  Mandyville::PlayerName - normalise and compare player names

=head1 SYNOPSIS

  use Mandyville::PlayerName qw(
      normalise_name full_name name_variants candidate_names
      phonetic_key similarity score_names
  );

  my $n = normalise_name("Juanlu Sanchez");   # "juanlu sanchez"

  my $sim = similarity("Yehor Yarmoliuk", "Yegor Yarmolyuk");

=head1 DESCRIPTION

  Pure functions (no database, no object) for normalising and scoring
  player names during FPL matching. Both sides of every comparison
  pass through the same normalisation so that the football-data habit
  of storing the whole name in C<last_name> with an empty
  C<first_name> does not break matching.

  A phonetic key flattens the most common Cyrillic-to-Latin
  transliteration variants (C<Yehor>/C<Yegor>, C<-iuk>/C<-yuk>,
  C<-ov>/C<-ow>) so that identical keys can floor a comparison at a
  high confidence score. The key is deliberately conservative: it only
  encodes transliteration equivalences, never pronunciation, so key
  collisions between genuinely different names are extremely unlikely.

=cut

const my $PHONETIC_SCORE => 0.95;

our @EXPORT_OK = qw(
    normalise_name full_name name_variants candidate_names
    phonetic_key similarity score_names
);

# Token-level transliteration equivalences, applied in order to each
# whitespace-separated token of a normalised name. Each rule maps
# alternative romanisations of the same Cyrillic form to one canonical
# spelling. Anchored and specific so unrelated names never collide.
const my @PHONETIC_RULES => (
    [ qr/^yehor$/,  'egor' ],
    [ qr/^yegor$/,  'egor' ],
    [ qr/iuk$/,     'uk'   ],
    [ qr/yuk$/,     'uk'   ],
    [ qr/ow$/,      'ov'   ],
);

=head1 FUNCTIONS

=over

=item normalise_name ( STR )

  Lowercase C<STR>, strip diacritics (NFKD decomposition followed by
  removal of non-spacing marks), convert every run of punctuation and
  other non-alphanumeric characters to a single space, and trim.
  C<undef> becomes the empty string.

=cut

sub normalise_name($str) {
    return '' unless defined $str;

    my $n = NFKD($str);
    $n =~ s/\p{Mn}//g;
    $n = lc $n;
    $n =~ s/[^a-z0-9]+/ /g;
    $n =~ s/^\s+|\s+$//g;

    return $n;
}

=item full_name ( FIRST, LAST )

  Normalise the concatenation of C<FIRST> and C<LAST>. The fix for
  rows where football-data stored C<('', 'Juanlu Sanchez')>: both sides
  of the comparison call this, so the empty first name does not matter.

=cut

sub full_name($first, $last) {
    return normalise_name(($first // '') . ' ' . ($last // ''));
}

=item name_variants ( FPL_INFO )

  Return an ordered, de-duplicated arrayref of normalised strings to
  try for one FPL element. C<FPL_INFO> is the element hash from the
  FPL C<bootstrap-static> payload and must contain C<first_name>,
  C<second_name> and C<web_name>.

  Variants, in priority order: full name, reversed name, web name,
  first name plus web name, web name with an initial prefix stripped
  (C<B.Fernandes>), web name with a dot suffix stripped
  (C<Kroupi.Jr>), and hyphenated surname components (prefixed with the
  first name). Bare surname forms are deliberately omitted: they are
  compared against full names during fuzzy scoring and would otherwise
  collide with single-name database rows (e.g. Ewen Jaouen's surname
  matching Jaouen Hadjam's first name).

=cut

sub name_variants($fpl_info) {
    my $first  = $fpl_info->{first_name}  // '';
    my $second = $fpl_info->{second_name} // '';
    my $web    = $fpl_info->{web_name}    // '';

    my @variants;

    push @variants, normalise_name("$first $second");

    if (length $first && length $second) {
        push @variants, normalise_name("$second $first");
    }

    push @variants, normalise_name($web) if length $web;

    if (length $first && length $web && $web ne $second) {
        push @variants, normalise_name("$first $web");
    }

    # First word of a compound first name plus web name (e.g.
    # "Gabriel Fernando" / web "Jesus" -> "Gabriel Jesus").
    if ($first =~ /^(\S+)\s/ && length $web) {
        push @variants, normalise_name("$1 $web");
    }

    if ($web =~ /^[A-Za-z]\.(.+)$/) {
        push @variants, normalise_name("$first $1") if length $first;
        push @variants, normalise_name($1);
    }

    if ($web =~ /^(.+)\.[A-Za-z]{1,2}$/) {
        push @variants, normalise_name("$first $1") if length $first;
    }

    if ($second =~ /-/) {
        foreach my $part (split /-/, $second) {
            push @variants, normalise_name("$first $part") if length $first;
        }
    }

    my %seen;
    return [ grep { length $_ && !$seen{$_}++ } @variants ];
}

=item candidate_names ( FIRST, LAST )

  Return a one-element arrayref containing the normalised full name of
  a database player. Because C<full_name> collapses to a single token
  when one column is empty, this also represents single-name rows and
  the football-data habit of storing the whole name in C<last_name>
  with an empty C<first_name>. Bare first/surname forms are excluded so
  they cannot be treated as exact matches.

=cut

sub candidate_names($first, $last) {
    my $full = full_name($first, $last);
    return length $full ? [$full] : [];
}

=item phonetic_key ( STR )

  Return a canonical transliteration key for the normalised C<STR>.
  Two strings with the same key are considered strong matches. The key
  collapses only the documented Cyrillic-romanisation equivalences in
  L</PHONETIC_RULES>; unrelated names do not share keys.

=cut

sub phonetic_key($str) {
    my $n = normalise_name($str);
    return '' unless length $n;

    my @tokens = split /\s+/, $n;

    foreach my $token (@tokens) {
        foreach my $rule (@PHONETIC_RULES) {
            $token =~ s/$rule->[0]/$rule->[1]/;
        }
    }

    return join ' ', @tokens;
}

=item similarity ( A, B )

  Return a similarity score in C<0..1> for the two names. This is the
  higher of:

  * the normalised Levenshtein ratio over the whole string, and
  * a token-set ratio: a greedy best one-to-one pairing of the tokens,
    order-insensitive, with a boost when one name's tokens are a
    strict subset of the other's (so C<"gonzalo garcia"> matches
    C<"gonzalo garcia torres">).

=cut

sub similarity($a, $b) {
    my $na = normalise_name($a);
    my $nb = normalise_name($b);

    return 0 if $na eq '' || $nb eq '';

    my $max_len = max(length $na, length $nb);
    my $lev     = 1 - (Text::Levenshtein::XS::distance($na, $nb) / $max_len);
    my $token   = _token_similarity($na, $nb);

    return max($lev, $token);
}

=item score_names ( VARIANTS, CANDIDATES )

  Score an FPL player's C<VARIANTS> (from L</name_variants>) against a
  database player's C<CANDIDATES> (from L</candidate_names>) and return
  the best similarity. Returns C<PHONETIC_SCORE> when any variant and
  any candidate share a phonetic key.

=cut

sub score_names($variants, $candidates) {
    my $best = 0;

    my %variant_keys;
    foreach my $v (@$variants) {
        my $key = phonetic_key($v);
        $variant_keys{$key} = 1 if length $key;
    }

    foreach my $c (@$candidates) {
        my $key = phonetic_key($c);
        return $PHONETIC_SCORE if length $key && $variant_keys{$key};

        foreach my $v (@$variants) {
            my $s = similarity($v, $c);
            $best = $s if $s > $best;
        }
    }

    return $best;
}

sub _token_similarity($a, $b) {
    my @a = split /\s+/, $a;
    my @b = split /\s+/, $b;

    my ($short, $long) = @a <= @b ? (\@a, \@b) : (\@b, \@a);

    my $total = 0;
    my @remaining = @$long;

    foreach my $t (@$short) {
        my ($best, $best_i) = (0, -1);

        foreach my $i (0 .. $#remaining) {
            my $r = _token_ratio($t, $remaining[$i]);
            if ($r > $best) {
                $best   = $r;
                $best_i = $i;
            }
        }

        splice @remaining, $best_i, 1 if $best_i >= 0;
        $total += $best;
    }

    my $avg = @$short ? $total / @$short : 0;

    return $avg if @$short == @$long;

    # Containment: every token of the shorter name appears in the longer.
    foreach my $t (@$short) {
        my $found = 0;
        foreach my $l (@$long) {
            if (_token_ratio($t, $l) >= 0.9) {
                $found = 1;
                last;
            }
        }
        return $avg unless $found;
    }

    # Subset names score well but not perfectly: blend with the length
    # ratio so "felipe" vs "felipe rodrigues da silva" is ~0.81.
    my $len_ratio = @$short / @$long;
    return 0.5 + 0.5 * (0.5 + 0.5 * $len_ratio);
}

sub _token_ratio($a, $b) {
    my $max_len = max(length $a, length $b);
    return 0 unless $max_len;

    return 1 - (Text::Levenshtein::XS::distance($a, $b) / $max_len);
}

1;

=back

=cut
