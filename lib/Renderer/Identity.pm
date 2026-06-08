package Renderer::Identity;

use strict;
use warnings;

use Crypt::Ed25519;
use Digest::SHA  qw(sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use Encode       qw(encode);
use File::Spec;
use File::Path qw(make_path);

use Renderer::Log;

my $log = Renderer::Log::structured('Identity');

my $PRIVATE_KEY;
my $PUBLIC_KEY;
my $FINGERPRINT;

# Load Ed25519 keypair. Resolution order:
#   1. Environment variables (IDENTITY_PUBLIC_KEY_B64 + IDENTITY_PRIVATE_KEY_B64)
#      — for ECS Fargate with Secrets Manager injection
#   2. Key files on disk (private/.identity/ed25519.{key,pub})
#      — for Docker/bare-metal with persistent volumes
#   3. Generate new keypair and write to disk
#      — first boot on any platform
#
# Returns 1 on success, 0 on failure (telemetry will be unsigned).
sub init {
	my ($private_dir) = @_;
	$private_dir //= "$ENV{RENDER_ROOT}/private";
	my $identity_dir = File::Spec->catdir($private_dir, '.identity');
	my $key_file     = File::Spec->catfile($identity_dir, 'ed25519.key');
	my $pub_file     = File::Spec->catfile($identity_dir, 'ed25519.pub');

	# 1. Environment variables (base64-encoded raw keys from Secrets Manager)
	if ($ENV{IDENTITY_PUBLIC_KEY_B64} && $ENV{IDENTITY_PRIVATE_KEY_B64}) {
		$PUBLIC_KEY  = decode_base64($ENV{IDENTITY_PUBLIC_KEY_B64});
		$PRIVATE_KEY = decode_base64($ENV{IDENTITY_PRIVATE_KEY_B64});
		unless ($PUBLIC_KEY && $PRIVATE_KEY && length($PUBLIC_KEY) == 32 && length($PRIVATE_KEY) == 64) {
			$log->warn("env var keypair invalid (pub="
					. length($PUBLIC_KEY // '')
					. "B, priv="
					. length($PRIVATE_KEY // '')
					. "B), falling through");
			undef $PUBLIC_KEY;
			undef $PRIVATE_KEY;
		} else {
			$log->info("loaded keypair from environment");
		}
	}

	# 2. Key files on disk
	if (!$PRIVATE_KEY && -f $key_file && -f $pub_file) {
		$PRIVATE_KEY = _slurp($key_file);
		$PUBLIC_KEY  = _slurp($pub_file);
		unless ($PRIVATE_KEY && $PUBLIC_KEY && length($PUBLIC_KEY) == 32 && length($PRIVATE_KEY) == 64) {
			$log->warn("keypair files corrupt, regenerating");
			undef $PRIVATE_KEY;
			undef $PUBLIC_KEY;
		}
	}

	# 3. Generate new keypair
	unless ($PRIVATE_KEY) {
		eval {
			make_path($identity_dir);
			($PUBLIC_KEY, $PRIVATE_KEY) = Crypt::Ed25519::generate_keypair();
			_spew($key_file, $PRIVATE_KEY);
			chmod 0600, $key_file;
			_spew($pub_file, $PUBLIC_KEY);
			$log->info("generated new keypair");
			$log->info("to share across fleet, store in Secrets Manager:");
			$log->info("  public_key:  " . encode_base64($PUBLIC_KEY,  ''));
			$log->info("  private_key: " . encode_base64($PRIVATE_KEY, ''));
		};
		if ($@) {
			$log->error("cannot generate keypair: $@");
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
