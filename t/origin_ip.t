use Mojo::Base -strict, -signatures;

use Test::More;

# Unit guard for X-Forwarded-For first-IP extraction (WW3-R60). A `=~`-vs-`//`
# precedence bug once ran the substitution on '' instead of the header, so
# originIP logged the entire raw "client, proxy1, proxy2…" string. Host-runnable
# — ParseRequest has no async or OPL dependency at this seam.
require Renderer::Render::ParseRequest;

my $xff = \&Renderer::Render::ParseRequest::_origin_ip_from_xff;

is $xff->('1.2.3.4, 5.6.7.8, proxy'), '1.2.3.4',     'multi-value XFF -> leading dotted-quad';
is $xff->('203.0.113.7'),             '203.0.113.7', 'single IP passes through';
is $xff->('  10.0.0.9 , 10.0.0.1'),   '10.0.0.9',    'leading space tolerated, first IP wins';
is $xff->(undef),                     '',            'absent header -> empty (caller falls back to remote_address)';

done_testing();
