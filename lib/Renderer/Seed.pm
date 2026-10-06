package Renderer::Seed;

# The seed rule every lane applies (WW3-R73). A request whose seed is absent or
# empty renders at DEFAULT_SEED: the render is the one a seed of DEFAULT_SEED
# produces, it is logged, and it carries SEED_DEFAULTED_WARNING. A present seed
# is a non-negative integer or the request is malformed.
#
# Used by ParseRequest::dispatch for every /render-api lane, by the
# content-fetch endpoints, and by /render-ptx.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Renderer::Constants qw(DEFAULT_SEED SEED_DEFAULTED_WARNING);

use Exporter qw(import);
our @EXPORT_OK = qw(resolve_seed MALFORMED_SEED_MESSAGE);

use constant MALFORMED_SEED_MESSAGE => 'You must provide a positive integer for the random seed.';

# resolve_seed($c, $params, $lane) → arrayref of warnings, or undef when the
# seed is present and malformed. Sets $params->{problemSeed} to DEFAULT_SEED
# when the request named none.
sub resolve_seed ($c, $params, $lane) {
	my $seed = $params->{problemSeed};
	if (defined $seed && length $seed) {
		return $seed =~ /^\d+$/ ? [] : undef;
	}
	$params->{problemSeed} = DEFAULT_SEED;
	$c->log->warn("$lane request carries no seed; rendering at the default seed " . DEFAULT_SEED);
	return [SEED_DEFAULTED_WARNING];
}

1;
