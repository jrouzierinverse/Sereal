#!perl
#
# Encoder half of the savestack-scope fix; see
# Perl/Decoder/t/905_regr_savestack_scope.t for the full explanation.
#
# srl_prepare_encoder() registers a SAVEDESTRUCTOR_X holding a raw
# srl_encoder_t *. Without a scope of its own that entry landed on the caller's
# savestack, so it outlived the Perl object owning the struct whenever the last
# reference went away before the scope ended -- FREETMPS at the end of the
# statement for a temporary invocant, or an undef/reassign/delete of the
# variable holding it.
#
# The encoder case was the worse of the two and the harder to notice:
#
#  * srl_dump_data_structure() deliberately leaves SRL_OF_ENCODER_DIRTY set and
#    defers all cleanup to the hook, so the hook always did real work on the
#    freed struct -- PTABLE_clear on four freed ptables, one of which also
#    SvREFCNT_dec's what it holds. Unlike the decoder there is no buffer test
#    that might accidentally short-circuit it.
#
#  * It is silent. Unlike the decoder, a temporary-invocant encode does not
#    reliably abort the process, and a flat payload does not corrupt anything at
#    all, because the ptables are allocated lazily and stay NULL. So the
#    assertions below, not a crash, are what actually catch this.
#
#  * Leaving the encoder marked in-use meant every later
#    sereal_encode_with_object() in the same scope ran on a clone, and
#    srl_build_encoder_struct_alike() does not copy compress_level -- so those
#    documents came out uncompressed. That is section 2.

use strict;
use warnings;

use Test::More;
use Test::Warn;
use File::Spec;
use lib File::Spec->catdir(qw(t lib));

BEGIN {
    lib->import('lib')
        if !-d 't';
}
use Sereal::Encoder qw(sereal_encode_with_object);

# srl_encoder.h's per-run flags; SRL_OF_ENCODER_DIRTY means "encode in progress".
# Not in the generated Sereal::Encoder constants, which only cover SRL_F_*.
use constant SRL_OF_ENCODER_DIRTY => 1;

my $compressible = [ map { "abcdefghij" x 20 } 1 .. 50 ];

# ---------------------------------------------------------------------------
# 1. The encoder must not be left marked in-use once an encode has returned.
#
# operational_flags() is where SRL_OF_ENCODER_DIRTY lives; flags() exposes only
# the persistent options. As in the decoder test, the call must be literal (the
# custom op comes from a compile-time call checker) and the check must be in the
# same scope, with no sub boundary in between.
# ---------------------------------------------------------------------------

{   my $e = Sereal::Encoder->new;
    sereal_encode_with_object( $e, [] );
    is( $e->operational_flags & SRL_OF_ENCODER_DIRTY, 0,
        'sereal_encode_with_object releases encoder state before returning' );
}
{   my $e = Sereal::Encoder->new;
    sereal_encode_with_object( $e, [], { hdr => 1 } );
    is( $e->operational_flags & SRL_OF_ENCODER_DIRTY, 0,
        'sereal_encode_with_object with header releases encoder state before returning' );
}
{   my $e = Sereal::Encoder->new;
    $e->encode( [] );
    is( $e->operational_flags & SRL_OF_ENCODER_DIRTY, 0,
        'encode releases encoder state before returning' );
}

# ---------------------------------------------------------------------------
# 2. Repeated encodes on one handle in one scope must be identical.
#
# The three calls below MUST stay sibling statements in a single block. Moving
# them into separate blocks, or into a loop of any kind (block, statement
# modifier, map), gives each call its own scope and makes this section assert
# nothing -- it passed on the broken build that way.
# ---------------------------------------------------------------------------

for my $case (
    [ 'zlib',  Sereal::Encoder::SRL_ZLIB(), 9 ],
    [ 'zlib1', Sereal::Encoder::SRL_ZLIB(), 1 ],
    [ 'zstd',  Sereal::Encoder::SRL_ZSTD(), 1 ],
) {
    my ( $name, $algo, $level ) = @$case;
    my $opt = {
        compress           => $algo,
        compress_level     => $level,
        compress_threshold => 1,
    };

    {
        my $e = Sereal::Encoder->new($opt);
        my $a = sereal_encode_with_object( $e, $compressible );
        my $b = sereal_encode_with_object( $e, $compressible );
        my $c = sereal_encode_with_object( $e, $compressible );
        is( length($b), length($a), "$name: 2nd functional encode in one scope matches the 1st" );
        is( length($c), length($a), "$name: 3rd functional encode in one scope matches the 1st" );
        ok( $a eq $b && $b eq $c, "$name: all three are byte-identical" );

        # Canary: without this the section would also pass if compression were
        # simply off for every call.
        ok( length($a) < length( Sereal::Encoder->new->encode($compressible) ),
            "$name: compression is actually active" );
    }
    {
        # Same for the 3-arg (header) form.
        my $e = Sereal::Encoder->new($opt);
        my $a = sereal_encode_with_object( $e, $compressible, { h => 1 } );
        my $b = sereal_encode_with_object( $e, $compressible, { h => 1 } );
        ok( $a eq $b, "$name: repeated encodes with header data are byte-identical" );
    }
    {
        # The OO form is the oracle: it always had pp_entersub's scope, so it
        # never lost compress_level. The fixed functional form must match it.
        my $e = Sereal::Encoder->new($opt);
        my $oo = $e->encode($compressible);
        my $fn = sereal_encode_with_object( Sereal::Encoder->new($opt), $compressible );
        ok( $fn eq $oo, "$name: functional output matches OO output" );
    }
}

# ---------------------------------------------------------------------------
# 3. Smoke: every way of releasing the encoder before the scope ends.
#
# dedupe_strings plus a repeated string is deliberate: it populates the ptables
# and the dedupe HV, which is what the deferred hook used to scribble through.
# A flat payload leaves them NULL and corrupts nothing.
# ---------------------------------------------------------------------------

my $inner = { s => "repeated string value" };
my $shared = [ $inner, $inner, "repeated string value", { deep => [ 1 .. 20 ] } ];
my $dedupe = { dedupe_strings => 1 };
my $expect = Sereal::Encoder->new($dedupe)->encode($shared);

warnings_are {
    {   # anonymous temporary, functional
        is( sereal_encode_with_object( Sereal::Encoder->new($dedupe), $shared ),
            $expect, 'temporary invocant, functional' );
    }
    {   # anonymous temporary, 3-arg form
        ok( length( sereal_encode_with_object(
                Sereal::Encoder->new($dedupe), $shared, { h => 1 } ) ),
            'temporary invocant, functional with header' );
    }
    {   # OO name called as a plain function, so it still uses the custom op
        is( Sereal::Encoder::encode( Sereal::Encoder->new($dedupe), $shared ),
            $expect, 'temporary invocant via the encode() alias' );
    }
    {   # named lexical, released before the scope ends
        my $e = Sereal::Encoder->new($dedupe);
        my $out = sereal_encode_with_object( $e, $shared );
        undef $e;
        is( $out, $expect, 'named lexical, undef-ed before scope exit' );
    }
    {   # named lexical, reassigned
        my $e = Sereal::Encoder->new($dedupe);
        my $out = sereal_encode_with_object( $e, $shared );
        $e = Sereal::Encoder->new($dedupe);
        is( $out, $expect, 'named lexical, reassigned before scope exit' );
    }
    {   # last reference held by a container that is then emptied
        my %h = ( e => Sereal::Encoder->new($dedupe) );
        my $out = sereal_encode_with_object( $h{e}, $shared );
        delete $h{e};
        is( $out, $expect, 'hash-held encoder, deleted before scope exit' );
    }
    {   # inside a sub: pp_leavesub frees the tmps before leaving the scope
        my $out = sub { sereal_encode_with_object( Sereal::Encoder->new($dedupe), $_[0] ) }
            ->($shared);
        is( $out, $expect, 'temporary invocant inside a sub' );
    }

    # Controls: these were always safe and must stay safe.
    {
        is( Sereal::Encoder->new($dedupe)->encode($shared), $expect,
            'control: temporary invocant, OO method' );
    }
    {
        my $e = Sereal::Encoder->new($dedupe);
        is( sereal_encode_with_object( $e, $shared ), $expect,
            'control: named lexical, functional' );
        is( $e->encode($shared), $expect, 'control: named lexical, OO' );
    }
}
[], 'no warnings from any of the release-before-scope-exit forms';

pass("Alive");
done_testing();
