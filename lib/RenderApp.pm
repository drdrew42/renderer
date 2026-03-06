package RenderApp;
use Mojo::Base 'Mojolicious';

BEGIN {
	use Mojo::File;
	$main::libname = Mojo::File::curfile->dirname;

	# RENDER_ROOT is required for initializing conf files.
	$ENV{RENDER_ROOT} = $main::libname->dirname
		unless (defined($ENV{RENDER_ROOT}));

	# PG_ROOT is required for PG/lib/PGEnvironment.pm
	$ENV{PG_ROOT} = $main::libname . '/PG';

	# Used for reconstructing library paths from sym-links.
	$ENV{OPL_DIRECTORY} = "$ENV{RENDER_ROOT}/webwork-open-problem-library";

	$ENV{MOJO_CONFIG} =
		(-r "$ENV{RENDER_ROOT}/render_app.conf")
		? "$ENV{RENDER_ROOT}/render_app.conf"
		: "$ENV{RENDER_ROOT}/render_app.conf.dist";
	$ENV{MOJO_LOG_LEVEL} = 'debug';
}

use lib "$main::libname";
print "using root directory: $ENV{RENDER_ROOT}\n";

use RenderApp::Model::Problem;
use RenderApp::Controller::IO;
use WeBWorK::RenderProblem;
use WeBWorK::FormatRenderedProblem;

sub startup {
	my $self = shift;

	# Merge environment variables with config file
	$self->plugin('Config');
	$self->plugin('TagHelpers');
	$self->secrets($self->config('secrets'));
	for (qw(problemJWTsecret webworkJWTsecret baseURL formURL SITE_HOST STRICT_JWT)) {
		$ENV{$_} //= $self->config($_);
	}

	sanitizeHostURLs();

	print "Renderer is based at $main::basehref\n";
	print "Problem attempts will be sent to $main::formURL\n";

	# Handle optional Strict-Transport-Security header
	if (my $HSTS_HEADER = $self->config('HSTS_HEADER')) {
		$self->hook(before_dispatch => sub {
			my $c = shift;
			$c->res->headers->header(
				'Strict-Transport-Security' => $HSTS_HEADER
			       );
		});
	}

	# Handle optional CORS settings
	if (my $CORS_ORIGIN = $self->config('CORS_ORIGIN')) {
		die "CORS_ORIGIN ($CORS_ORIGIN) must be an absolute URL or '*'"
			unless ($CORS_ORIGIN eq '*' || $CORS_ORIGIN =~ /^https?:\/\//);

		warn "*** [CONFIG] Using '*' for CORS_ORIGIN is insecure\n"
			if ($CORS_ORIGIN eq '*');

		$self->hook(
			before_dispatch => sub {
				my $c = shift;
				$c->res->headers->header('Access-Control-Allow-Origin' => $CORS_ORIGIN);
			}
		);
	}

	# Logging
	if ($ENV{MOJO_MODE} && $ENV{MOJO_MODE} eq 'production') {
		my $logPath = "$ENV{RENDER_ROOT}/logs/error.log";
		print "[LOGS] Running in production mode, logging to $logPath\n";
		$self->log(Mojo::Log->new(
			path  => $logPath,
			level => ($ENV{MOJO_LOG_LEVEL} || 'warn')
		));
	}

	if ($self->config('INTERACTION_LOG')) {
		my $interactionLogPath = "$ENV{RENDER_ROOT}/logs/interactions.log";
		print "[LOGS] Saving interactions to $interactionLogPath\n";
		my $resultsLog = Mojo::Log->new(path => $interactionLogPath, level => 'info');
		$resultsLog->format(sub {
			my ($time, $level, @lines) = @_;
			my $start = shift(@lines);
			my $msg   = join ", ", @lines;
			return sprintf "%s, %s, %s\n", $start, $time - $start, $msg;
		});
		$self->helper(logAttempt => sub { shift; $resultsLog->info(@_); });
	}

	# Add Cache-Control and Expires headers to static content from webwork2_files
	if (my $STATIC_EXPIRES = $self->config('STATIC_EXPIRES')) {
	    $STATIC_EXPIRES = int( $STATIC_EXPIRES );
	    my $cache_control_setting = "max-age=$STATIC_EXPIRES";
	    my $no_cache_setting = 'max-age=1, no-cache';
	    $self->hook(after_dispatch => sub {
		my $c = shift;

		# Only process if file requested is under webwork2_files
		return unless ($c->req->url->path =~ '^/webwork2_files/');

		if ($c->req->url->path =~ '/tmp/renderer') {
		    # Treat problem generated files as already expired.
		    # They should not be cached.
		    $c->res->headers->cache_control( $no_cache_setting );
		    $c->res->headers->header(Expires =>
		        Mojo::Date->new(time - 86400) # expired 24 hours ago
		    );
		} else {
		    # Standard "static" files.
		    # They can be cached
		    $c->res->headers->cache_control( $cache_control_setting );
		    $c->res->headers->header(Expires =>
		        Mojo::Date->new(time + $STATIC_EXPIRES)
			);
		}
	    });
	}

	# Models
	$self->helper(newProblem => sub { shift; RenderApp::Model::Problem->new(@_) });

	# Helpers
	$self->helper(format          => sub { WeBWorK::FormatRenderedProblem::formatRenderedProblem(@_) });
	$self->helper(validateRequest => sub { RenderApp::Controller::IO::validate(@_) });
	$self->helper(parseRequest    => sub { RenderApp::Controller::Render::parseRequest(@_) });
	$self->helper(croak           => sub { RenderApp::Controller::Render::croak(@_) });
	$self->helper(logID           => sub { shift->req->request_id });
	$self->helper(exception       => sub { RenderApp::Controller::Render::exception(@_) });

	# Routes
	# baseURL sets the root at which the renderer is listening,
	# and is used in Environment for pg_root_url
	my $r = $self->routes->under($ENV{baseURL});

	$r->any('/render-api')->to('render#problem');
	$r->any('/render-ptx')->to('render#render_ptx');
	$r->any('/health' => sub { shift->rendered(200) });
	$r->any('/health' => sub {shift->rendered(200)});
	if ($self->mode eq 'development' || $self->config('FULL_APP_INSECURE')) {
		$r->any('')->to('pages#twocolumn');
		$r->any('/')->to('pages#twocolumn');
		$r->any('/opl')->to('pages#oplUI');
		$r->any('/die' => sub {die "what did you expect, flowers?"});
		$r->any('/timeout' => sub {
			my $c = shift;
			my $tx = $c->render_later->tx;
			Mojo::IOLoop->timer(2 => sub {
				$tx = $tx; # prevent $tx from going out of scope
				$c->rendered(200);
			});
		});
  }

	# Enable problem editor & OPL browser -- NOT recommended for production environment!
	supplementalRoutes($r) if ($self->mode eq 'development' || $self->config('FULL_APP_INSECURE'));

	# Static file routes
	$r->any('/pg_files/CAPA_Graphics/*static')->to('StaticFiles#CAPA_graphics_file');
	$r->any('/pg_files/tmp/*static')->to('StaticFiles#temp_file');
	$r->any('/pg_files/*static')->to('StaticFiles#pg_file');
	$r->any('/*static')->to('StaticFiles#public_file');

}

sub supplementalRoutes {
	my $r = shift;

	# UI
	$r->any('/')->to('pages#twocolumn');
	$r->any('/opl')->to('pages#oplUI');

	# Testing
	$r->any('/die'     => sub { die "what did you expect, flowers?" });
	$r->any('/timeout' => sub { timeout(@_) });

	# JWT Convenience
	$r->any('/render-api/jwt')->to('render#jwtFromRequest');
	$r->any('/render-api/jwe')->to('render#jweFromRequest');

	# Library Actions
	$r->any('/render-api/tap')->to('IO#raw');
	$r->post('/render-api/can')->to('IO#writer');
	$r->any('/render-api/cat')->to('IO#catalog');
	$r->any('/render-api/find')->to('IO#search');
	$r->post('/render-api/upload')->to('IO#upload');
	$r->delete('/render-api/remove')->to('IO#remove');
	$r->post('/render-api/clone')->to('IO#clone');
	$r->post('/render-api/tags')->to('IO#setTags');

	# ShowMeAnother Support Functions
	$r->post('/render-api/sma')->to('IO#findNewVersion');
	$r->post('/render-api/unique')->to('IO#findUniqueSeeds');
}

sub timeout {
	my $c  = shift;
	my $tx = $c->render_later->tx;
	Mojo::IOLoop->timer(
		2 => sub {
			$tx = $tx;    # prevent $tx from going out of scope
			$c->rendered(200);
		}
	);
}

sub sanitizeHostURLs {
	$ENV{SITE_HOST} =~ s!/$!!;

	# set an absolute base href for asset urls under iframe embedding
	if ($ENV{baseURL} =~ m!^https?://!) {

		# this should only be used by MITM sites when proxying renderer assets
		my $baseURL = $ENV{baseURL} =~ m!/$! ? $ENV{baseURL} : "$ENV{baseURL}/";
		$main::basehref = Mojo::URL->new($baseURL);

		# do NOT use the proxy address in our router!
		$ENV{baseURL} = '';
	} elsif ($ENV{baseURL} =~ m!\S!) {

		# ENV{baseURL} is used to build routes, so configure as "/extension"
		$ENV{baseURL} = "/$ENV{baseURL}";
		warn "*** [CONFIG] baseURL should not end in a slash\n"
			if $ENV{baseURL} =~ s!/$!!;
		warn "*** [CONFIG] baseURL should begin with a slash\n"
			unless $ENV{baseURL} =~ s!^//!/!;

		# base href must end in a slash when not hosting at the root
		$main::basehref =
			Mojo::URL->new($ENV{SITE_HOST})->path("$ENV{baseURL}/");
	} else {
		# no proxy and service is hosted at the root of SITE_HOST
		$main::basehref = Mojo::URL->new($ENV{SITE_HOST});
	}

	if ($ENV{formURL} =~ m!\S!) {

		# this should only be used by MITM
		$main::formURL = Mojo::URL->new($ENV{formURL});
		die '*** [CONFIG] if provided, formURL must be absolute'
			unless $main::formURL->is_abs;
	} else {
		# if using MITM proxy base href + renderer api not at SITE_HOST root
		# provide form url as absolute SITE_HOST/extension/render-api
		$main::formURL =
			Mojo::URL->new($ENV{SITE_HOST})->path("$ENV{baseURL}/render-api");
	}
}

1;
