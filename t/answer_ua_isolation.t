use Mojo::Base -strict, -signatures;

use Test::More;
use Mojo::UserAgent;

# Unit guard for the shared-UA connect_timeout leak (WW3-R60). Answer-URL
# postbacks carry graded verdicts; they must ride a dedicated UA, not the
# shared $c->ua whose connect_timeout is set (to 2s) by Registration's ECS
# probe and never reset. A dedicated agent keeps its own, stable timeouts no
# matter what a shared agent elsewhere was mutated to.
require Renderer::Render::AnswerURL;

my $default = Mojo::UserAgent->new->connect_timeout;

# Simulate Registration's leak on a shared-style agent, then confirm the
# answer-URL UA is unaffected.
my $shared = Mojo::UserAgent->new;
$shared->connect_timeout(2);

my $ua = Renderer::Render::AnswerURL::_post_ua();
isa_ok $ua, 'Mojo::UserAgent', 'AnswerURL owns a UA';
isnt $ua,                  $shared,  'not the shared agent';
is $ua->connect_timeout,   $default, 'answer-URL UA keeps the default connect_timeout';
isnt $ua->connect_timeout, 2,        'answer-URL UA not poisoned by a leaked connect_timeout';
is $ua->request_timeout,   7,        'answer-URL request_timeout preserved';

done_testing();
