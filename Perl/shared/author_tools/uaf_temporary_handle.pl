#!/usr/bin/perl
#
# Reproducer for the savestack-scope use-after-free fixed in Decoder/Encoder
# 5.010. Run it under valgrind from either dist:
#
#   cd Perl/Decoder && make
#   valgrind --suppressions=author_tools/valgrind.supp --error-limit=no \
#     perl -Mblib ../shared/author_tools/uaf_temporary_handle.pl
#
# Expect "ERROR SUMMARY: 0 errors". Before the fix, on perl 5.26 / glibc 2.28:
# 22 errors / 15 contexts including 4 invalid writes for the decoder, and
# 15 errors / 13 contexts including 3 invalid writes for the encoder.
#
# srl_begin_decoding() / srl_prepare_encoder() registered a SAVEDESTRUCTOR_X
# holding a raw struct pointer on the *caller's* savestack scope. FREETMPS runs
# at the end of each statement and the savestack is unwound only at the end of
# the enclosing scope, so a handle whose last reference went away first was
# freed by DESTROY and the hook then ran on freed memory.
#
# Each form below is in its own block so the savestack actually unwinds. Whether
# a given dist is available depends on which blib you loaded; both halves are
# skipped independently.

use strict;
use warnings;

my $have_dec = eval { require Sereal::Decoder; 1 };
my $have_enc = eval { require Sereal::Encoder; 1 };

# { c => "plain", b => "nofreeze" } -- deliberately contains no objects, so this
# is independent of the FREEZE/THAW machinery.
my $body_only = "=\xf3rl\x05\x00Raceplainabhnofreeze";

# [ "body", 5, 300 ] with header user-data { hdr => "H", n => 7 }
my $with_hdr = "=\xf3rl\x05\x0b\x01Ran\x07chdraHCdbody\x05 \xac\x02";

if ($have_dec) {
    Sereal::Decoder->import(
        qw(sereal_decode_with_object sereal_decode_only_header_with_object));

    {   # the form from the original report
        my $out = sereal_decode_with_object( Sereal::Decoder->new, $body_only );
        print "decoder body: $out->{c}\n";
    }
    {   # worse: srl_decode_header_into never clears, so the deferred hook ran
        # the full cleanup rather than hitting an early return
        my $hdr = sereal_decode_only_header_with_object( Sereal::Decoder->new, $with_hdr );
        print "decoder header: $hdr->{hdr}\n";
    }
    {   # not only temporaries -- any release before the scope ends
        my $d = Sereal::Decoder->new;
        my $out = sereal_decode_with_object( $d, $body_only );
        undef $d;
        print "decoder undef-ed handle: $out->{b}\n";
    }
}
else {
    print "# Sereal::Decoder not loadable, skipping decoder forms\n";
}

if ($have_enc) {
    Sereal::Encoder->import(qw(sereal_encode_with_object));

    # A shared ref plus dedupe_strings populates the ptables and the dedupe HV.
    # A flat payload leaves them NULL and corrupts nothing, which is why the
    # encoder half of this bug went unnoticed for so long.
    my $inner = { s => "repeated string value" };
    my $shared = [ $inner, $inner, "repeated string value" ];

    {
        my $enc = sereal_encode_with_object(
            Sereal::Encoder->new( { dedupe_strings => 1 } ), $shared );
        print "encoder: ", length($enc), " bytes\n";
    }
    {
        my $e = Sereal::Encoder->new( { dedupe_strings => 1 } );
        my $enc = sereal_encode_with_object( $e, $shared );
        undef $e;
        print "encoder undef-ed handle: ", length($enc), " bytes\n";
    }
}
else {
    print "# Sereal::Encoder not loadable, skipping encoder forms\n";
}

print "done\n";
