use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Unit guard for the resource-usage log line (WW3-R60). _render_log_message is
# the seam where a `.`-vs-`?:` precedence bug once collapsed the whole timing
# line down to just the (empty-on-success) error string, so the log recorded
# nothing useful. Pure string logic — no PG render needed. PG_ROOT/RENDER_ROOT
# are set before the require so the module's load-time `use lib` and log-touch
# resolve; the container's own values win when present.
BEGIN {
	$ENV{PG_ROOT} //= "$FindBin::Bin/../lib/PG";
	my $root = tempdir(CLEANUP => 1);
	make_path("$root/logs");
	$ENV{RENDER_ROOT} //= $root;
}

require WeBWorK::RenderProblem;

subtest 'successful render logs a full timing line' => sub {
	my $msg = WeBWorK::RenderProblem::_render_log_message(0.123, 4096, 'lib/x.pg', 0, '');
	ok length($msg) > 0, 'non-empty log line on success';
	like $msg, qr/duration: 0\.123 sec/, 'duration present';
	like $msg, qr/memory:\s+4096 bytes/, 'memory present';
	like $msg, qr{file: lib/x\.pg},      'source path present';
};

subtest 'error render appends the error string after the timing line' => sub {
	my $msg = WeBWorK::RenderProblem::_render_log_message(0.2, 8192, 'lib/y.pg', 1, ' has errors');
	like $msg, qr/duration: 0\.200 sec/,       'timing still present on error';
	like $msg, qr{file: lib/y\.pg has errors}, 'error string appended after the path';
};

done_testing();
