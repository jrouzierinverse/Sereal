#!perl

use strict;
use warnings;

use Sereal::Decoder qw(sereal_decode_with_object scalar_looks_like_sereal);
use Test::More tests => 5;
use Data::Dumper;

my $srl_decoder           = Sereal::Decoder->new();
my $empty_array_as_sereal = "=\363rl\4\0\@";

my $dec = sereal_decode_with_object( $srl_decoder, $empty_array_as_sereal );
is( Dumper($dec), Dumper( [] ), "check that sereal_decode_with_object works as expected" );
is(
    scalar_looks_like_sereal($empty_array_as_sereal), 4,    #expect version 4
    "check that scalar_looks_like_sereal works as expected"
);

# The decoder as an anonymous temporary: the custom op used to leave
# srl_begin_decoding()'s savestack destructor registered on the caller's scope,
# by which point FREETMPS had already freed the struct. See
# t/905_regr_savestack_scope.t.
{
    my $tmp = sereal_decode_with_object( Sereal::Decoder->new, $empty_array_as_sereal );
    is( Dumper($tmp), Dumper( [] ), "sereal_decode_with_object works with a temporary decoder" );
}
{
    my $d = Sereal::Decoder->new;
    sereal_decode_with_object( $d, $empty_array_as_sereal );
    is_deeply( [ $d->flag_names_volatile ], [],
        "the custom op leaves no cleanup hook pending on the caller's scope" );
}

pass("did not segfault!");
