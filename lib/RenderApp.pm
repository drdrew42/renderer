package RenderApp;
use Mojo::Base 'Mojolicious';

BEGIN {
    use Mojo::File;
    $main::dirname = Mojo::File::curfile->dirname;

    #RENDER_ROOT is required for initializing conf files
    $ENV{RENDER_ROOT} = $main::dirname->dirname
      unless ( defined( $ENV{RENDER_ROOT} ) );

    #WEBWORK_ROOT is required for PG/lib/WeBWorK/IO
    $ENV{WEBWORK_ROOT} = $main::dirname . '/WeBWorK'
      unless ( defined( $ENV{WEBWORK_ROOT} ) );

    #used for reconstructing library paths from sym-links
    $ENV{OPL_DIRECTORY}                    = "webwork-open-problem-library";
    $WeBWorK::Constants::WEBWORK_DIRECTORY = $main::dirname . "/WeBWorK";
    $WeBWorK::Constants::PG_DIRECTORY      = $main::dirname . "/PG";
    unless ( -r $WeBWorK::Constants::WEBWORK_DIRECTORY ) {
        die "Cannot read webwork root directory at $WeBWorK::Constants::WEBWORK_DIRECTORY";
    }
    unless ( -r $WeBWorK::Constants::PG_DIRECTORY ) {
        die "Cannot read webwork pg directory at $WeBWorK::Constants::PG_DIRECTORY";
    }

	$ENV{MOJO_CONFIG} = (-r "$ENV{RENDER_ROOT}/render_app.conf") ? "$ENV{RENDER_ROOT}/render_app.conf" : "$ENV{RENDER_ROOT}/render_app.conf.dist";
	# $ENV{MOJO_MODE} = 'production';
	# $ENV{MOJO_LOG_LEVEL} = 'debug';
}

use lib "$main::dirname";
print "home directory " . $main::dirname . "\n";

use RenderApp::Model::Problem;
use RenderApp::Controller::RenderProblem;
use RenderApp::Controller::IO;

sub startup {
	my $self = shift;

	# Merge environment variables with config file
	$self->plugin('Config');
	$self->plugin('TagHelpers');
	$self->secrets($self->config('secrets'));
	for ( qw(problemJWTsecret webworkJWTsecret baseURL formURL SITE_HOST MOJO_MODE) ) {
		$ENV{$_} //= $self->config($_);
	};

	# convert to absolute URLs
	$ENV{baseURL} = ''if ( $ENV{baseURL} eq '/' );
	$ENV{SITE_HOST} =~ s|/$||;  # remove trailing slash
	$ENV{baseURL} = $ENV{SITE_HOST} . $ENV{baseURL} if ( $ENV{baseURL} !~ m|^https?://| );
	$ENV{formURL} = $ENV{baseURL} . $ENV{formURL} if ( $ENV{formURL} !~ m|^https?://| );

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
	$self->helper(newJWT => sub { shift; RenderApp::Model::JWT->new(@_) });
	$self->helper(decodeJWT => sub { shift; RenderApp::Model::JWT::decode(@_) });

	# Helpers
	$self->helper(validateRequest => sub { RenderApp::Controller::IO::validate(@_) });
	$self->helper(parseRequest => sub { RenderApp::Controller::Render::parseRequest(@_) });
	$self->helper(logID => sub { shift->req->request_id });
	$self->helper(exception => sub { RenderApp::Controller::Render::exception(@_) });

	# Routes to controller
	my $r = $self->routes;

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
		$r->post('/render-api/sma')->to('IO#findNewVersion');
		$r->post('/render-api/unique')->to('IO#findUniqueSeeds');
		$r->post('/render-api/tags')->to('IO#setTags');
	}

	# pass all requests via ww2_files through to lib/WeBWorK/htdocs
	my $staticPath = $WeBWorK::Constants::WEBWORK_DIRECTORY."/htdocs/";
	$r->any('/webwork2_files/*static' => sub {
		my $c = shift;
		$c->reply->file($staticPath.$c->stash('static'));
	});

	# any other requests fall through
	$r->any('/*fail' => sub {
		my $c = shift;
		my $report = $c->stash('fail')."\nCOOKIE:";
		for my $cookie (@{$c->req->cookies}) {
			$report .= "\n".$cookie->to_string;
		}
		$report .= "\nFORM DATA:";
		foreach my $k (@{$c->req->params->names}) {
			$report .= "\n$k = ".join ', ', @{$c->req->params->every_param($k)};
		}
		$c->log->fatal($report);
		$c->rendered(404)});
}

1;
