#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::PlayerName qw(
    normalise_name full_name name_variants candidate_names
    phonetic_key similarity score_names
);

use Test::More;

######
# normalise_name
######

is( normalise_name('Juanlu Sánchez'), 'juanlu sanchez',
    'normalise_name strips accents and lowercases' );
is( normalise_name('  B.Fernandes  '), 'b fernandes',
    'normalise_name converts punctuation to space and trims' );
is( normalise_name("Kroupi.Jr"), 'kroupi jr',
    'normalise_name handles dot suffix' );
is( normalise_name(undef), '', 'normalise_name handles undef' );
is( normalise_name('Kesler-Hayden'), 'kesler hayden',
    'normalise_name splits hyphens' );

######
# full_name / candidate_names
######

is( full_name('', 'Juanlu Sánchez'), 'juanlu sanchez',
    'full_name collapses empty first name' );
is( full_name('Rodri', ''), 'rodri', 'full_name collapses empty last name' );

is_deeply( candidate_names('', 'Juanlu Sánchez'), ['juanlu sanchez'],
    'candidate_names returns full name only' );
is_deeply( candidate_names('Kai', 'Andrews'), ['kai andrews'],
    'candidate_names does not include bare tokens' );

######
# name_variants
######

my $v = name_variants({
    first_name => 'Yehor', second_name => 'Yarmoliuk', web_name => 'Yarmoliuk'
});
is( $v->[0], 'yehor yarmoliuk', 'name_variants starts with full name' );
ok( (grep { $_ eq 'yarmoliuk' } @$v), 'name_variants keeps web name' );

$v = name_variants({
    first_name => 'Gabriel Fernando',
    second_name => 'de Jesus',
    web_name => 'Jesus',
});
ok( (grep { $_ eq 'gabriel jesus' } @$v),
    'name_variants builds first-word + web name' );

$v = name_variants({
    first_name => 'Bruno', second_name => 'Fernandes', web_name => 'B.Fernandes'
});
ok( (grep { $_ eq 'fernandes' } @$v),
    'name_variants strips initial prefix' );

######
# phonetic_key
######

is( phonetic_key('Yehor Yarmoliuk'), phonetic_key('Yegor Yarmolyuk'),
    'phonetic_key collapses Yehor/Yegor and iuk/yuk' );
is( phonetic_key('Ivanov'), phonetic_key('Ivanow'),
    'phonetic_key collapses -ov/-ow' );
isnt( phonetic_key('smith'), phonetic_key('jones'),
    'phonetic_key distinguishes different names' );

######
# similarity
######

cmp_ok( similarity('Yehor Yarmoliuk', 'Yegor Yarmolyuk'), '>', 0.8,
    'similarity scores transliteration variants high' );
cmp_ok( similarity('Kaine Andrews', 'Kai Andrews'), '>', 0.8,
    'similarity scores Kaine/Kai high' );
cmp_ok( similarity('Gonzalo García', 'Gonzalo García Torres'), '>', 0.8,
    'similarity scores subset names high' );
cmp_ok( similarity('Ewen Jaouen', 'Jaouen Hadjam'), '<', 0.5,
    'similarity rejects Ewen Jaouen vs Jaouen Hadjam' );
cmp_ok( similarity('Felipe Rodrigues da Silva', 'Felipe Monteiro'), '<', 0.9,
    'similarity keeps distinct Felipes apart' );

######
# score_names
######

my $score = score_names(
    name_variants({
        first_name => 'Yehor', second_name => 'Yarmoliuk', web_name => 'Yarmoliuk'
    }),
    candidate_names('Yegor', 'Yarmolyuk'),
);
cmp_ok( $score, '>=', 0.95, 'score_names floors phonetic matches at 0.95' );

$score = score_names(
    name_variants({
        first_name => 'Ewen', second_name => 'Jaouen', web_name => 'Jaouen'
    }),
    candidate_names('Jaouen', 'Hadjam'),
);
cmp_ok( $score, '<', 0.95, 'score_names does not floor non-equivalent names' );

done_testing;
