#!perl

use strict;
use warnings;

use Sereal::Encoder qw(sereal_encode_with_object);
use Test::More tests => 4;

my $srl_encoder = Sereal::Encoder->new();

my $enc = sereal_encode_with_object( $srl_encoder, [] );
is( $enc, "=\363rl\5\0\@", "check that sereal_encode_with_object works" );

# The encoder as an anonymous temporary: the custom op used to leave
# srl_prepare_encoder()'s savestack destructor registered on the caller's scope,
# by which point FREETMPS had already freed the struct. See
# t/901_regr_savestack_scope.t.
{
    my $tmp = sereal_encode_with_object( Sereal::Encoder->new, [] );
    is( $tmp, "=\363rl\5\0\@", "sereal_encode_with_object works with a temporary encoder" );
}
{
    my $e = Sereal::Encoder->new;
    sereal_encode_with_object( $e, [] );
    is( $e->operational_flags & 1, 0,    # SRL_OF_ENCODER_DIRTY
        "the custom op leaves no cleanup hook pending on the caller's scope" );
}

pass("did not segfault!")
