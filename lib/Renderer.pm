package Renderer;
use Mojo::Base 'Mojolicious', -signatures;

BEGIN {
	use Mojo::File;
	$main::libname = Mojo::File::curfile->dirname;

	# RENDER_ROOT is required for initializing conf files.
	$ENV{RENDER_ROOT} = $main::libname->dirname
		unless (defined($ENV{RENDER_ROOT}));

	# PG_ROOT is required for PG/lib/PGEnvironment.pm
	$ENV{PG_ROOT} = $main::libname . '/PG';

	$ENV{MOJO_CONFIG} =
		(-r "$ENV{RENDER_ROOT}/renderer.conf")
		? "$ENV{RENDER_ROOT}/renderer.conf"
		: "$ENV{RENDER_ROOT}/renderer.conf.dist";
	$ENV{MOJO_LOG_LEVEL} = $ENV{MOJO_LOG_LEVEL} || 'debug';
}

use lib "$main::libname";
print "using root directory: $ENV{RENDER_ROOT}\n";

use Mojo::JSON;
use Renderer::Identity;
use Renderer::OPLClient;
use Renderer::Telemetry;
use Renderer::Registration;
use Renderer::Render::ParseRequest;
use Renderer::Version;
use WeBWorK::FormatRenderedProblem;

sub startup ($self) {

	# Merge environment variables with config file
	$self->plugin('Config');
	$self->plugin('TagHelpers');
	$self->secrets($self->config('secrets'));
	for (qw(problemJWTsecret webworkJWTsecret STRICT_JWT)) {
		$ENV{$_} //= $self->config($_);
	}

	# Static asset list (third-party CSS/JS) — config-driven with baked-in
	# fallbacks so deployments using a customized renderer.conf that predates
	# WW3-R24 keep rendering. Replaces the hardcoded lists previously in
	# WeBWorK::FormatRenderedProblem. Per-problem assets (PG's
	# extra_css_files / extra_js_files) stay in the formatter; this is the
	# process-wide library list only.
	$self->config->{third_party_css} //= [
		'css/bootstrap.css',
		'node_modules/jquery-ui-dist/jquery-ui.min.css',
		'node_modules/@fortawesome/fontawesome-free/css/all.min.css',
	];
	$self->config->{third_party_js} //= [
		[ 'node_modules/jquery/dist/jquery.min.js',                            {} ],
		[ 'node_modules/jquery-ui-dist/jquery-ui.min.js',                      {} ],
		[ 'js/apps/MathJaxConfig/mathjax-config.js',                { defer => undef } ],
		[ 'node_modules/mathjax/es5/tex-svg.js',                    { defer => undef, id => 'MathJax-script' } ],
		[ 'node_modules/bootstrap/dist/js/bootstrap.bundle.min.js', { defer => undef } ],
		[ 'js/apps/Problem/problem.js',                             { defer => undef } ],
		[ 'js/apps/Problem/submithelper.js',                        { defer => undef } ],
		[ 'js/apps/CSSMessage/css-message.js',                      { defer => undef } ],
		[ 'js/apps/DraftTracker/draft-tracker.js',                  { defer => undef } ],
	];

	# Refuse to start if shared secrets are still placeholders.
	# Prevents silent fallback to conf-file defaults when a service forgets to
	# pass the env var — see WeBWorK3/Config and Secrets Evolution for rationale.
	for my $k (qw(problemJWTsecret webworkJWTsecret)) {
		my $v = $ENV{$k} // '';
		if ($v eq '' || $v eq 'CHANGE_ME_IN_ENV') {
			die "FATAL: $k is unset or still at placeholder value. "
				. "Set env var `$k` (e.g. in .env) before starting the renderer.\n";
		}
	}

	# --- URL configuration ---
	# RENDERER_URL: the public URL where this renderer is reachable.
	#   e.g. "https://render.lan.drdrew.us" or "https://cms.example.com/renderer"
	#   Replaces the old SITE_HOST + baseURL pair.
	# FORM_ACTION: (optional) only for MITM deployments where a middleware
	#   intercepts form submissions. If empty, defaults to {RENDERER_URL}/render-api.
	#
	# Legacy support: SITE_HOST + baseURL still work if RENDERER_URL is not set.
	$ENV{RENDERER_URL} //= $self->config('RENDERER_URL');
	$ENV{FORM_ACTION}  //= $self->config('FORM_ACTION') // '';

	# Legacy fallback: build RENDERER_URL from SITE_HOST + baseURL
	unless ($ENV{RENDERER_URL}) {
		for (qw(baseURL formURL SITE_HOST)) {
			$ENV{$_} //= $self->config($_);
		}
		my $host = $ENV{SITE_HOST} // 'http://localhost:3000';
		my $base = $ENV{baseURL}   // '';
		if ($base =~ m!^https?://!) {
			# MITM mode: baseURL is the proxy origin, SITE_HOST is the renderer
			$ENV{RENDERER_URL} = $host;
			$ENV{FORM_ACTION}  = $ENV{formURL} if $ENV{formURL} && $ENV{formURL} =~ /\S/;
			# basehref comes from the proxy for asset URLs
			$main::basehref_override = $base;
		} elsif ($base =~ /\S/) {
			$ENV{RENDERER_URL} = "${host}/${base}";
		} else {
			$ENV{RENDERER_URL} = $host;
		}
	}

	# Hypnotoad tuning from environment (Fargate vCPU count differs from bare metal).
	# Env vars override config file values; unset vars leave config defaults intact.
	my $hyp = $self->config->{hypnotoad} //= {};
	$hyp->{workers}          = $ENV{HYPNOTOAD_WORKERS}          + 0 if $ENV{HYPNOTOAD_WORKERS};
	$hyp->{accepts}          = $ENV{HYPNOTOAD_ACCEPTS}          + 0 if $ENV{HYPNOTOAD_ACCEPTS};
	$hyp->{requests}         = $ENV{HYPNOTOAD_REQUESTS}         + 0 if $ENV{HYPNOTOAD_REQUESTS};
	$hyp->{spare}            = $ENV{HYPNOTOAD_SPARE}            + 0 if $ENV{HYPNOTOAD_SPARE};
	$hyp->{clients}          = $ENV{HYPNOTOAD_CLIENTS}          + 0 if $ENV{HYPNOTOAD_CLIENTS};
	$hyp->{graceful_timeout} = $ENV{HYPNOTOAD_GRACEFUL_TIMEOUT} + 0 if $ENV{HYPNOTOAD_GRACEFUL_TIMEOUT};

	configureURLs();

	$self->log->info("Renderer is based at $main::basehref");
	$self->log->info("Problem attempts will be sent to $main::formURL");

	# Increase max header line size from 8KB to 64KB.
	# Browsers on shared wildcard domains send large Cookie headers
	# from sibling services, which silently truncates the request.
	$ENV{MOJO_MAX_LINE_SIZE} = 65536;

	# CORS: allow requests from known OPL origins (learned during registration)
	# and optionally from a static CORS_ORIGIN config for other use cases.
	{
		my $static_origin = $self->config('CORS_ORIGIN');
		if ($static_origin) {
			die "CORS_ORIGIN ($static_origin) must be an absolute URL or '*'"
				unless ($static_origin eq '*' || $static_origin =~ /^https?:\/\//);
			$self->log->warn("Using '*' for CORS_ORIGIN is insecure")
				if ($static_origin eq '*');
		}

		$self->hook(
			before_dispatch => sub {
				my $c = shift;
				my $origin = $c->req->headers->origin // return;

				my $allowed = $static_origin && ($static_origin eq '*' || $static_origin eq $origin)
					? $static_origin
					: Renderer::Registration::is_known_origin($origin)
						? $origin
						: undef;
				return unless $allowed;

				$c->res->headers->header('Access-Control-Allow-Origin'  => $allowed);
				$c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS');
				$c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type');

				# Short-circuit preflight requests
				if ($c->req->method eq 'OPTIONS') {
					$c->res->headers->header('Access-Control-Max-Age' => '86400');
					$c->rendered(204);
				}
			}
		);
	}

	# Logging — Hypnotoad sets MOJO_MODE=production implicitly.
	# In containers, LOG_TO_STDERR=1 keeps logs on stderr for Docker/Promtail/CloudWatch.
	# Without LOG_TO_STDERR, production mode logs to file.
	my $level = $ENV{MOJO_LOG_LEVEL} || 'warn';
	if ($ENV{MOJO_MODE} && $ENV{MOJO_MODE} eq 'production') {
		if ($ENV{LOG_TO_STDERR}) {
			$self->log(Mojo::Log->new(level => $level));
		} else {
			my $logPath = "$ENV{RENDER_ROOT}/logs/error.log";
			$self->log(Mojo::Log->new(path => $logPath, level => $level));
		}
	}

	# Structured JSON logging for Loki/CloudWatch Insights queryability.
	# LOG_FORMAT=json enables; plaintext otherwise (Mojo default).
	if ($ENV{LOG_FORMAT} && $ENV{LOG_FORMAT} eq 'json') {
		$self->log->format(sub {
			my ($time, $level, @lines) = @_;
			Mojo::JSON::encode_json({
				timestamp => Mojo::Date->new($time)->to_datetime,
				level     => $level,
				pid       => $$,
				service   => 'renderer',
				message   => join(' ', @lines),
			}) . "\n";
		});
	}

	$self->log->info("Renderer logging to "
		. ($ENV{LOG_TO_STDERR} ? 'stderr' : 'file')
		. " (level: $level, format: " . ($ENV{LOG_FORMAT} // 'plain') . ")");

	if ($self->config('INTERACTION_LOG')) {
		my $interactionLogPath = "$ENV{RENDER_ROOT}/logs/interactions.log";
		$self->log->info("Saving interactions to $interactionLogPath");
		my $resultsLog = Mojo::Log->new(path => $interactionLogPath, level => 'info');
		$resultsLog->format(sub {
			my ($time, $level, @lines) = @_;
			my $start = shift(@lines);
			my $msg   = join ", ", @lines;
			return sprintf "%s, %s, %s\n", $start, $time - $start, $msg;
		});
		$self->helper(logAttempt => sub { shift; $resultsLog->info(@_); });
	}

	# Content cache sweep on startup — evict stale problem directories.
	# Controlled by CACHE_TTL_HOURS env var (default 168 = 1 week).
	if ($ENV{CONTENT_ADDRESSED}) {
		require Renderer::ContentCache;
		my $evicted = Renderer::ContentCache::sweep();
		$self->log->info("ContentCache sweep: evicted $evicted stale problem(s)") if $evicted;
	}

	# OPL HTTP client (single instance per app; closes over $self->ua at init time).
	{
		my $client = Renderer::OPLClient->new(
			ua       => $self->ua,
			base_url => $ENV{OPL_API_URL} || 'http://webwork-opl:3000',
			log      => $self->log,
		);
		$self->helper(opl_client => sub { $client });
	}

	# Helpers
	$self->helper(format          => sub { WeBWorK::FormatRenderedProblem::formatRenderedProblem(@_) });
	$self->helper(parseRequest    => sub { Renderer::Render::ParseRequest::dispatch(@_) });
	$self->helper(croak           => sub { Renderer::Controller::Render::croak(@_) });
	$self->helper(logID           => sub { shift->req->request_id });
	$self->helper(exception       => sub { Renderer::Controller::Render::exception(@_) });

	# Structured request logging — one JSON line per request
	require Time::HiRes;
	require Mojo::JSON;
	$self->hook(before_dispatch => sub ($c) {
		$c->stash('_request_start' => Time::HiRes::time());
	});
	$self->hook(after_dispatch => sub ($c) {
		my $start = $c->stash('_request_start') // return;
		my $req = $c->req;
		my $res = $c->res;
		my $path = $req->url->path->to_string;
		return if $path eq '/health';
		my %entry = (
			type        => 'request',
			method      => $req->method,
			path        => $path,
			status      => $res->code,
			duration_ms => sprintf('%.1f', (Time::HiRes::time() - $start) * 1000),
			request_id  => $req->request_id,
		);
		# Renderer-specific fields
		$entry{cache_status} = $c->stash('_cache_status') if $c->stash('_cache_status');
		$entry{pg_hash}      = $c->stash('pg_hash')       if $c->stash('pg_hash');
		$self->log->info(Mojo::JSON::encode_json(\%entry));
	});

	# Routes
	# baseURL sets the root at which the renderer is listening,
	# and is used in Environment for pg_root_url
	my $r = $self->routes->under($ENV{baseURL});

	$r->any('/render-api')->to('render#problem');
	$r->post('/render-api/callback')->to('callback#callback');
	$r->post('/render-api/audit')->to('audit#audit');
	$r->post('/render-api/hint')->to('render#hint');
	$r->post('/render-api/solution')->to('render#solution');
	$r->any('/render-ptx')->to('render#render_ptx');
	$r->any('/health' => sub ($c) {
		my $ok = eval { -d "$ENV{RENDER_ROOT}/private" };
		$c->render(json => {
			status           => $ok ? 'ok' : 'error',
			service          => 'Renderer',
			pg_version       => Renderer::Version::pg_version(),
			renderer_version => Renderer::Version::renderer_version(),
		}, status => $ok ? 200 : 503);
	});

	# Enable problem editor & OPL browser -- NOT recommended for production environment!
	supplementalRoutes($r) if ($self->mode eq 'development' || $self->config('FULL_APP_INSECURE'));

	# Ed25519 identity for telemetry signing (persisted in private/.identity/)
	if (Renderer::Identity::init()) {
		$self->log->info("Identity: fingerprint " . Renderer::Identity::fingerprint());
	} else {
		$self->log->warn("Identity: no keypair — telemetry will be unsigned");
	}

	# Telemetry batch reporter (fires only when OPL_API_URL is set)
	Renderer::Telemetry::init($self);

	# Explicit OPL registration with callback URL (LT-016)
	Renderer::Registration::init($self);

	# Static file routes
	$r->any('/pg_files/CAPA_Graphics/*static')->to('StaticFiles#CAPA_graphics_file');
	$r->any('/pg_files/tmp/*static')->to('StaticFiles#temp_file');
	$r->any('/pg_files/*static')->to('StaticFiles#pg_file');
	$r->any('/*static')->to('StaticFiles#public_file');
}

sub supplementalRoutes ($r) {
	# Testing
	$r->any('/die'     => sub { die "what did you expect, flowers?" });
	$r->any('/timeout' => sub { timeout(@_) });

	# JWT Convenience (hand-testing helpers)
	$r->any('/render-api/jwt')->to('render#jwtFromRequest');
	$r->any('/render-api/jwe')->to('render#jweFromRequest');
}

sub timeout ($c) {
	my $tx = $c->render_later->tx;
	Mojo::IOLoop->timer(
		2 => sub {
			$tx = $tx;    # prevent $tx from going out of scope
			$c->rendered(200);
		}
	);
}

# Derive basehref, formURL, route prefix, and SITE_HOST from RENDERER_URL.
#
# Deployment strategies:
#   1. Direct:    RENDERER_URL=https://render.example.com
#   2. Subpath:   RENDERER_URL=https://example.com/renderer
#   3. MITM:      RENDERER_URL=https://render.example.com  FORM_ACTION=https://cms.example.com/render-api
#                  (+ basehref_override from legacy baseURL=https://cms.example.com/renderer/)
sub configureURLs {
	my $url = Mojo::URL->new($ENV{RENDERER_URL});
	die "*** [CONFIG] RENDERER_URL must be an absolute URL\n" unless $url->is_abs;

	# SITE_HOST = origin only (scheme + host + port). Used for JWT iss/aud.
	$ENV{SITE_HOST} = $url->clone->path('')->query(undef)->fragment(undef)->to_string;
	$ENV{SITE_HOST} =~ s!/$!!;

	# Route prefix = path component (e.g. "/renderer" or "")
	my $path_prefix = $url->path->to_string // '';
	$path_prefix =~ s!/$!!;
	$ENV{baseURL} = $path_prefix;

	# basehref = what browsers use to resolve relative asset URLs
	if ($main::basehref_override) {
		# MITM: proxy serves assets from its own origin
		my $override = $main::basehref_override;
		$override .= '/' unless $override =~ m!/$!;
		$main::basehref = Mojo::URL->new($override);
	} elsif ($path_prefix) {
		$main::basehref = Mojo::URL->new($ENV{SITE_HOST})->path("$path_prefix/");
	} else {
		$main::basehref = Mojo::URL->new($ENV{SITE_HOST});
	}

	# formURL = where answer submission forms POST to
	if ($ENV{FORM_ACTION} && $ENV{FORM_ACTION} =~ /\S/) {
		$main::formURL = Mojo::URL->new($ENV{FORM_ACTION});
		die "*** [CONFIG] FORM_ACTION must be an absolute URL\n"
			unless $main::formURL->is_abs;
	} else {
		$main::formURL =
			Mojo::URL->new($ENV{SITE_HOST})->path("$path_prefix/render-api");
	}
}

1;
