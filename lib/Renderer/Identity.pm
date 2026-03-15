package Renderer::Identity;

use strict;
use warnings;

use Crypt::Ed25519;
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use Encode qw(encode);
use File::Spec;
use File::Path qw(make_path);

my $PRIVATE_KEY;
my $PUBLIC_KEY;
my $FINGERPRINT;

# Load or generate Ed25519 keypair from private/.identity/.
# Returns 1 on success, 0 on failure (telemetry will be unsigned).
sub init {
	my ($private_dir) = @_;
	$private_dir //= "$ENV{RENDER_ROOT}/private";
	my $identity_dir = File::Spec->catdir($private_dir, '.identity');
	my $key_file     = File::Spec->catfile($identity_dir, 'ed25519.key');
	my $pub_file     = File::Spec->catfile($identity_dir, 'ed25519.pub');

	if (-f $key_file && -f $pub_file) {
		$PRIVATE_KEY = _slurp($key_file);
		$PUBLIC_KEY  = _slurp($pub_file);
		unless ($PRIVATE_KEY && $PUBLIC_KEY && length($PUBLIC_KEY) == 32 && length($PRIVATE_KEY) == 64) {
			warn "Identity: keypair files corrupt, regenerating\n";
			undef $PRIVATE_KEY;
			undef $PUBLIC_KEY;
		}
	}

	unless ($PRIVATE_KEY) {
		eval {
			make_path($identity_dir);
			($PUBLIC_KEY, $PRIVATE_KEY) = Crypt::Ed25519::generate_keypair();
			_spew($key_file, $PRIVATE_KEY);
			chmod 0600, $key_file;
			_spew($pub_file, $PUBLIC_KEY);
		};
		if ($@) {
			warn "Identity: cannot generate keypair: $@\n";
			return 0;
		}
	}

	$FINGERPRINT = sha256_hex($PUBLIC_KEY);
	return 1;
}

# Sign a message. Returns raw 64-byte signature, or undef if no identity.
sub sign {
	my ($message) = @_;
	return unless $PRIVATE_KEY && $PUBLIC_KEY;
	# Encode to UTF-8 bytes — Ed25519 operates on byte strings,
	# and Perl's internal wide characters cause "Wide character" errors.
	my $bytes = encode('UTF-8', $message);
	return Crypt::Ed25519::sign($bytes, $PUBLIC_KEY, $PRIVATE_KEY);
}

# Verify a signature given message, signature, and public key (all raw bytes).
sub verify {
	my ($message, $signature, $public_key) = @_;
	return eval { Crypt::Ed25519::verify($message, $public_key, $signature) };
}

sub public_key     { return $PUBLIC_KEY }
sub public_key_b64 { return $PUBLIC_KEY ? encode_base64($PUBLIC_KEY, '') : undef }
sub fingerprint    { return $FINGERPRINT }
sub has_identity   { return defined $PRIVATE_KEY }

sub _slurp {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return;
	local $/;
	my $data = <$fh>;
	close $fh;
	return $data;
}

sub _spew {
	my ($path, $data) = @_;
	open my $fh, '>:raw', $path or die "Cannot write $path: $!";
	print $fh $data;
	close $fh;
}

1;
