package RenderApp;
use Mojo::Base 'Mojolicious';

BEGIN {
    use Mojo::File;
    $main::libname = Mojo::File::curfile->dirname;

    # RENDER_ROOT is required for initializing conf files.
    $ENV{RENDER_ROOT} = $main::libname->dirname
      unless ( defined( $ENV{RENDER_ROOT} ) );

	# PG_ROOT is required for PG/lib/PGEnvironment.pm, FormatRenderedProblem.pm, and RenderProblem.pm.
    # This is hardcoded to avoid conflict with the environment variable for webwork2.
    # There is no need for this to be configurable.
    $ENV{PG_ROOT} = $main::libname . '/PG';

	# Used for reconstructing library paths from sym-links.
	$ENV{OPL_DIRECTORY} = "$ENV{RENDER_ROOT}/webwork-open-problem-library";

	$ENV{MOJO_CONFIG} = (-r "$ENV{RENDER_ROOT}/render_app.conf") ? "$ENV{RENDER_ROOT}/render_app.conf" : "$ENV{RENDER_ROOT}/render_app.conf.dist";
	# $ENV{MOJO_MODE} = 'production';
	# $ENV{MOJO_LOG_LEVEL} = 'debug';
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
	for ( qw(problemJWTsecret webworkJWTsecret baseURL formURL SITE_HOST STRICT_JWT) ) {
		$ENV{$_} //= $self->config($_);
	};

	sanitizeHostURLs();
	# baseURL sets the root at which the renderer is listening, and is used in Environment for pg_root_url
	my $r = $self->routes->under($ENV{baseURL});

	print "Renderer is based at $main::basehref\n";
	print "Problem attempts will be sent to $main::formURL\n";

	# Handle optional CORS settings
	if (my $CORS_ORIGIN = $self->config('CORS_ORIGIN')) {
		die "CORS_ORIGIN ($CORS_ORIGIN) must be an absolute URL or '*'"
			unless ($CORS_ORIGIN eq '*' || $CORS_ORIGIN =~ /^https?:\/\//);

		$self->hook(before_dispatch => sub {
			my $c = shift;
            $c->res->headers->header( 'Access-Control-Allow-Origin' => $CORS_ORIGIN );
		});
	}

	# Models
	$self->helper(newProblem => sub { shift; RenderApp::Model::Problem->new(@_) });

	# Helpers
	$self->helper(format => sub { WeBWorK::FormatRenderedProblem::formatRenderedProblem(@_) });
	$self->helper(validateRequest => sub { RenderApp::Controller::IO::validate(@_) });
	$self->helper(parseRequest => sub { RenderApp::Controller::Render::parseRequest(@_) });
	$self->helper(croak => sub { RenderApp::Controller::Render::croak(@_) });
	$self->helper(logID => sub { shift->req->request_id });
	$self->helper(exception => sub { RenderApp::Controller::Render::exception(@_) });

	# Routes to controller

	$r->any('/render-api')->to('render#problem');
	$r->any('/health' => sub {shift->rendered(200)});
	if ($self->mode eq 'development') {
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

		$r->any('/render-api/jwt')->to('render#jwtFromRequest');
		$r->any('/render-api/jwe')->to('render#jweFromRequest');
		$r->any('/render-api/tap')->to('IO#raw');
		$r->post('/render-api/can')->to('IO#writer');
		$r->any('/render-api/cat')->to('IO#catalog');
		$r->any('/render-api/find')->to('IO#search');
		$r->post('/render-api/upload')->to('IO#upload');
		$r->delete('/render-api/remove')->to('IO#remove');
		$r->post('/render-api/clone')->to('IO#clone');
		$r->post('/render-api/sma')->to('IO#findNewVersion');
		$r->post('/render-api/unique')->to('IO#findUniqueSeeds');
		$r->post('/render-api/tags')->to('IO#setTags');
	}

	# Static file routes
	$r->any('/pg_files/CAPA_Graphics/*static')->to('StaticFiles#CAPA_graphics_file');
	$r->any('/pg_files/tmp/*static')->to('StaticFiles#temp_file');
	$r->any('/pg_files/*static')->to('StaticFiles#pg_file');
    $r->any('/*static')->to('StaticFiles#public_file');
}

sub sanitizeHostURLs {
	$ENV{baseURL} = "/$ENV{baseURL}";
	warn "*** Configuration error: baseURL should not end in a slash\n" if $ENV{baseURL} =~ s!/$!!;
	warn "*** Configuration error: baseURL should begin with a slash\n" unless $ENV{baseURL} =~ s!^//!/!;

	# set an absolute base href for iframe embedding
	my $basehref = $ENV{baseURL} =~ m!/$! ? $ENV{baseURL} : "$ENV{baseURL}/";
	my $baseURL = Mojo::URL->new($basehref);
	$main::basehref = $baseURL->is_abs
		? $baseURL
		: Mojo::URL->new($ENV{SITE_HOST})->path($baseURL);

	# respect absolute form URLs for man-in-the-middle implementations
	warn "*** Configuration error: formURL should not begin with a slash\n" if $ENV{formURL} =~ s!^/!!;
	my $renderEndpoint = $ENV{formURL} || 'render-api';
	my $formURL = Mojo::URL->new($renderEndpoint);
	warn "*** Possible configuration error: are you sure you want to use $main::basehref$renderEndpoint as the render endpoint?\n"
		unless $formURL->is_abs || $renderEndpoint eq 'render-api';
	$main::formURL = $formURL->is_abs
		? $formURL
		: Mojo::URL->new($ENV{SITE_HOST})->path($basehref.$renderEndpoint);
}

1;
