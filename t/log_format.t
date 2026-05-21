use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::Log;
use Mojo::JSON qw(decode_json);

# Renderer::Log::apply_json_format — the structured-JSON log formatter.
# A leading hashref must merge to the top level of the entry (queryable by
# log aggregators); plain string args become `message`.

BEGIN { $ENV{LOG_FORMAT} = 'json' }
require Renderer::Log;

my $log = Mojo::Log->new;
Renderer::Log::apply_json_format($log, 'testcomp');
my $fmt = $log->format;
ok $fmt, 'formatter installed when LOG_FORMAT=json';

subtest 'plain string arg becomes message' => sub {
	my $e = decode_json($fmt->(1_716_000_000, 'info', 'hello there'));
	is $e->{message},   'hello there', 'string -> message';
	is $e->{level},     'info',        'level';
	is $e->{service},   'renderer',    'service';
	is $e->{component}, 'testcomp',    'component';
	ok $e->{timestamp}, 'timestamp present';
};

subtest 'leading hashref merges to top level, no nested message' => sub {
	my $e = decode_json($fmt->(1_716_000_000, 'info',
		{ type => 'request', status => 200, duration_ms => '12.3' }));
	is $e->{type},        'request', 'type at top level';
	is $e->{status},      200,       'status at top level';
	is $e->{duration_ms}, '12.3',    'duration_ms at top level';
	is $e->{service},     'renderer', 'envelope intact';
	ok !exists $e->{message}, 'no message field for a pure structured entry';
};

subtest 'envelope fields are not clobbered by the hashref' => sub {
	my $e = decode_json($fmt->(1_716_000_000, 'info',
		{ service => 'spoofed', level => 'spoofed', type => 'request' }));
	is $e->{service}, 'renderer', 'service not clobbered';
	is $e->{level},   'info',     'level not clobbered';
	is $e->{type},    'request',  'non-conflicting field still merged';
};

done_testing();
