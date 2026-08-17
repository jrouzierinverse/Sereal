#!perl
#
# The functional/custom-op decode interfaces used to leave srl_begin_decoding's
# SAVEDESTRUCTOR_X cleanup hook registered on the *caller's* savestack scope.
# The hook holds a raw srl_decoder_t * with no reference to the Perl object that
# owns that struct, and perl runs FREETMPS at the end of each *statement* but
# unwinds the savestack only at the end of the enclosing *scope* -- statement
# boundary first. So any decoder whose last reference went away before the scope
# ended was freed by DESTROY, and the hook then ran on freed memory.
#
# That is reachable from more than an anonymous temporary: undef-ing,
# reassigning or deleting the variable holding the decoder does it too.
#
# Two failure modes, tested separately below:
#
#  * Heap corruption. Untrappable -- on an unfixed decoder this file emits its
#    TAP and then aborts in global destruction, so the harness reports
#    "Dubious, test returned 134" rather than a clean failure. That is what the
#    smoke section is for, and it is why the sections above it exist.
#
#  * Leaked state, which IS trappable. The hook is also what clears the decoder,
#    so deferring it left the decoder marked SRL_F_DECODER_DIRTY after a
#    header-only decode. srl_begin_decoding then cloned it for the next decode,
#    and srl_build_decoder_struct_alike does not copy flags_readonly -- so
#    set_readonly was silently dropped. No crash, no warning, wrong data.
#
# Documents are hardcoded (as in t/901_regr_segv.t) so this file does not need
# the Encoder installed.

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
use Sereal::Decoder qw(
    sereal_decode_with_object
    sereal_decode_only_header_with_object
    sereal_decode_with_header_with_object
    sereal_decode_with_offset_with_object
    sereal_decode_only_header_with_offset_with_object
    sereal_decode_with_header_and_offset_with_object
);

# { c => "plain", b => "nofreeze" }
my $body_only = "=\xf3rl\x05\x00Raceplainabhnofreeze";

# [ "body", 5, 300 ] with header user-data { hdr => "H", n => 7 }
my $with_hdr = "=\xf3rl\x05\x0b\x01Ran\x07chdraHCdbody\x05 \xac\x02";

# ---------------------------------------------------------------------------
# 1. No volatile flags may survive any entry point.
#
# SRL_F_DECODER_DIRTY left set is the direct signature of a still-pending
# savestack hook. Before the fix the two header-only functional forms reported
# ['DIRTY'] here while every other form, and every OO method, reported [] --
# because pp_entersub wraps XSUB calls in its own ENTER/LEAVE, so the OO path
# always had the scoping this test now requires of the functional one.
#
# Two things make this section fragile, and both silently turn it into a test of
# nothing rather than into a failure:
#
#  * Every functional call must be written out literally. The custom op is
#    installed by a compile-time call checker on the named sub, so dispatching
#    through a symbolic or code ref (&$fn(...), $fn->(...)) falls back to the
#    plain XSUB -- which gets pp_entersub's own scope.
#
#  * The flag check must sit in the same scope as the call, with no sub boundary
#    in between. Wrapping the call in a helper sub means pp_leavesub has already
#    unwound the savestack by the time the check runs.
#
# Hence the deliberate repetition below. Do not factor it out.
# ---------------------------------------------------------------------------

{   my $d = Sereal::Decoder->new;
    sereal_decode_with_object( $d, $body_only );
    is_deeply( [ $d->flag_names_volatile ], [],
        'sereal_decode_with_object releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    $d->decode($body_only);
    is_deeply( [ $d->flag_names_volatile ], [],
        'decode releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    sereal_decode_only_header_with_object( $d, $with_hdr );
    is_deeply( [ $d->flag_names_volatile ], [],
        'sereal_decode_only_header_with_object releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    $d->decode_only_header($with_hdr);
    is_deeply( [ $d->flag_names_volatile ], [],
        'decode_only_header releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    sereal_decode_with_header_with_object( $d, $with_hdr );
    is_deeply( [ $d->flag_names_volatile ], [],
        'sereal_decode_with_header_with_object releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    $d->decode_with_header($with_hdr);
    is_deeply( [ $d->flag_names_volatile ], [],
        'decode_with_header releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    sereal_decode_with_offset_with_object( $d, $body_only, 0 );
    is_deeply( [ $d->flag_names_volatile ], [],
        'sereal_decode_with_offset_with_object releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    $d->decode_with_offset( $body_only, 0 );
    is_deeply( [ $d->flag_names_volatile ], [],
        'decode_with_offset releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    sereal_decode_only_header_with_offset_with_object( $d, $with_hdr, 0 );
    is_deeply( [ $d->flag_names_volatile ], [],
        'sereal_decode_only_header_with_offset_with_object releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    $d->decode_only_header_with_offset( $with_hdr, 0 );
    is_deeply( [ $d->flag_names_volatile ], [],
        'decode_only_header_with_offset releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    sereal_decode_with_header_and_offset_with_object( $d, $with_hdr, 0 );
    is_deeply( [ $d->flag_names_volatile ], [],
        'sereal_decode_with_header_and_offset_with_object releases decoder state before returning' );
}
{   my $d = Sereal::Decoder->new;
    $d->decode_with_header_and_offset( $with_hdr, 0 );
    is_deeply( [ $d->flag_names_volatile ], [],
        'decode_with_header_and_offset releases decoder state before returning' );
}

# ---------------------------------------------------------------------------
# 2. Leaked state must not silently change what the next decode returns.
#
# Both calls must be sibling statements in one scope: that is the whole point.
# Splitting them into separate blocks, or into a loop body, makes this section
# assert nothing at all, because each iteration gets its own scope.
# ---------------------------------------------------------------------------

for my $opt (qw(set_readonly set_readonly_scalars)) {
    {
        my $d = Sereal::Decoder->new( { $opt => 1 } );
        my $h = sereal_decode_only_header_with_object( $d, $with_hdr );
        my $b = sereal_decode_with_object( $d, $body_only );
        is( ref($b), 'HASH', "$opt: functional body decode after header decode works" );
        ok( Internals::SvREADONLY( $b->{c} ),
            "$opt survives a preceding functional header-only decode in the same scope" );
    }
    {
        my $d = Sereal::Decoder->new( { $opt => 1 } );
        my $h = sereal_decode_only_header_with_object( $d, $with_hdr );
        my $b = $d->decode($body_only);
        ok( Internals::SvREADONLY( $b->{c} ),
            "$opt survives it for a following OO decode too" );
    }
}

# ---------------------------------------------------------------------------
# 3. The OO form is the oracle: giving the custom op its own scope must not
#    change any result. These all passed before the fix; they are here to catch
#    the fix itself going wrong -- in particular an ENTER/LEAVE that grew a
#    SAVETMPS/FREETMPS would free the mortal return value.
# ---------------------------------------------------------------------------

{
    my $d = Sereal::Decoder->new;
    is_deeply( sereal_decode_with_object( $d, $body_only ), $d->decode($body_only),
        'body: functional matches OO' );

    is_deeply( [ sereal_decode_with_header_with_object( $d, $with_hdr ) ],
               [ $d->decode_with_header($with_hdr) ],
        'body+header: functional matches OO' );

    is_deeply( sereal_decode_only_header_with_object( $d, $with_hdr ),
               $d->decode_only_header($with_hdr),
        'header only: functional matches OO' );

    # "pass-in" style: the caller supplies the target SV rather than getting a
    # mortal back. Exercises the OPOPT_OUTARG_* arms of the same op.
    my ( $into, $hdr_into );
    sereal_decode_with_object( $d, $body_only, $into );
    is_deeply( $into, { c => "plain", b => "nofreeze" }, 'pass-in body target filled' );
    sereal_decode_only_header_with_object( $d, $with_hdr, $hdr_into );
    is_deeply( $hdr_into, { hdr => "H", n => 7 }, 'pass-in header target filled' );
}

# ---------------------------------------------------------------------------
# 4. Smoke: every way of releasing the decoder before the scope ends.
#
# One call each is enough -- an unfixed decoder corrupts its heap on the first
# one. These print ok and the process then aborts at exit, so on an unfixed
# build the signal is the harness reporting a non-zero exit, not a failed
# assertion. The safe controls at the end are what make a pass meaningful.
# ---------------------------------------------------------------------------

my $want = { c => "plain", b => "nofreeze" };

warnings_are {
    {   # anonymous temporary, functional
        is_deeply( sereal_decode_with_object( Sereal::Decoder->new, $body_only ),
            $want, 'temporary invocant, functional' );
    }
    {   # anonymous temporary, header-only (worse case: srl_decode_header_into
        # never clears, so the deferred hook did the full cleanup on freed memory)
        is_deeply(
            sereal_decode_only_header_with_object( Sereal::Decoder->new, $with_hdr ),
            { hdr => "H", n => 7 }, 'temporary invocant, header-only functional' );
    }
    {   # OO name called as a plain function, so it still uses the custom op
        is_deeply( Sereal::Decoder::decode( Sereal::Decoder->new, $body_only ),
            $want, 'temporary invocant via the decode() alias' );
    }
    {   # named lexical, released before the scope ends
        my $d = Sereal::Decoder->new;
        my $out = sereal_decode_with_object( $d, $body_only );
        undef $d;
        is_deeply( $out, $want, 'named lexical, undef-ed before scope exit' );
    }
    {   # named lexical, reassigned
        my $d = Sereal::Decoder->new;
        my $out = sereal_decode_with_object( $d, $body_only );
        $d = Sereal::Decoder->new;
        is_deeply( $out, $want, 'named lexical, reassigned before scope exit' );
    }
    {   # last reference held by a container that is then emptied
        my %h = ( d => Sereal::Decoder->new );
        my $out = sereal_decode_with_object( $h{d}, $body_only );
        delete $h{d};
        is_deeply( $out, $want, 'hash-held decoder, deleted before scope exit' );
    }
    {   # inside a sub: pp_leavesub frees the tmps before leaving the scope
        my $out = sub { sereal_decode_with_object( Sereal::Decoder->new, $_[0] ) }
            ->($body_only);
        is_deeply( $out, $want, 'temporary invocant inside a sub' );
    }

    # Controls: these were always safe and must stay safe.
    {
        is_deeply( Sereal::Decoder->new->decode($body_only), $want,
            'control: temporary invocant, OO method' );
    }
    {
        my $m = 'decode';
        is_deeply( Sereal::Decoder->new->$m($body_only), $want,
            'control: temporary invocant, dynamic method name' );
    }
    {
        my $d = Sereal::Decoder->new;
        is_deeply( sereal_decode_with_object( $d, $body_only ), $want,
            'control: named lexical, functional' );
        is_deeply( $d->decode($body_only), $want,
            'control: named lexical, OO' );
    }
}
[], 'no warnings from any of the release-before-scope-exit forms';

pass("Alive");
done_testing();
