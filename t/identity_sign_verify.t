use strict;
use warnings;
use utf8;    # the payload literal below carries genuine wide characters

use Test::More;

use Crypt::Ed25519;
use MIME::Base64 qw(encode_base64);
use File::Temp   qw(tempdir);

# Load a deterministic keypair into Identity via the env-var branch (no disk).
my ($pub, $sec) = Crypt::Ed25519::generate_keypair();
$ENV{IDENTITY_PUBLIC_KEY_B64}  = encode_base64($pub, '');
$ENV{IDENTITY_PRIVATE_KEY_B64} = encode_base64($sec, '');

require Renderer::Identity;
ok(Renderer::Identity::init(tempdir(CLEANUP => 1)), 'Identity init loaded the env keypair');

# The contract under test: sign() and verify() are symmetric — both encode the
# message to UTF-8 bytes internally, one mechanism. A wide-character payload
# signed by sign() must verify() true with NO manual pre-encode at the call
# site. Against an asymmetric pair (sign encodes, verify does not) this fails:
# verify sees raw wide characters and Crypt::Ed25519 dies / mismatches.
my $wide = "café ½ \x{2211} \x{6570}\x{5B66}";    # é, ½, ∑, 数学 — codepoints > 255

my $sig = Renderer::Identity::sign($wide);
ok(defined $sig && length($sig) == 64, 'sign returns a 64-byte signature for a wide payload');

ok(
	Renderer::Identity::verify($wide, $sig, Renderer::Identity::public_key()),
	'symmetric sign/verify round-trips a wide-character payload (no manual encode)'
);

# ASCII floor — the common case must keep round-tripping.
my $ascii = 'plain-ascii-payload';
ok(
	Renderer::Identity::verify($ascii, Renderer::Identity::sign($ascii), Renderer::Identity::public_key()),
	'ASCII payload round-trips'
);

# A tampered payload must NOT verify (guards against a verify that ignores its input).
ok(
	!Renderer::Identity::verify("$wide-tampered", $sig, Renderer::Identity::public_key()),
	'a modified payload fails verification'
);

done_testing();
