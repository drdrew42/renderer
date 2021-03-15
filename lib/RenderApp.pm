package RenderApp;
use Mojo::Base 'Mojolicious';
use Mojo::File;

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
}

use lib "$main::dirname";
print "home directory " . $main::dirname . "\n";

use RenderApp::Model::Problem;
use RenderApp::Controller::RenderProblem;
use RenderApp::Controller::IO;

use WeBWorK::Form;
use WeBWorK::Constants;

sub startup {
  my $self = shift;
  my $staticPath = $WeBWorK::Constants::WEBWORK_DIRECTORY."/htdocs/"; #curfile->dirname->sibling('public')->to_string.'/';

  # config
  $self->plugin('Config');
  $self->plugin('TagHelpers');
  $self->secrets($self->config('secrets'));
#   $self->plugin('leak_tracker');

  # Models
  $self->helper(newProblem => sub { shift; RenderApp::Model::Problem->new(@_) });

  # helper to expose request data
  $self->helper(requestData2JSON => sub {
		my $c = shift;
		my $hash = {};
		my @all_param_names = @{$c->req->params->names};
		foreach my $key (@all_param_names) {
			my $val = join ',', @{$c->req->params->every_param($key)};
			$hash->{$key} = $val;
		}
		return $c->render(json => $hash);
	});

  # helper to validate incoming request parameters
  $self->helper(validateRequest => sub { RenderApp::Controller::IO::validate(@_) });

  # Routes to controller
  my $r = $self->routes;

	$r->any('/')->to('pages#twocolumn');
	$r->any('/opl')->to('pages#oplUI');

	$r->any('/health' => sub {shift->rendered(200)});

	$r->post('/render-api/')->to('render#problem');
	$r->post('/render-api/tap')->to('IO#raw');
	$r->post('/render-api/can')->to('IO#writer');
	$r->any('/render-api/cat')->to('IO#catalog');
	$r->any('/render-api/find')->to('IO#search');
    $r->post('/render-api/upload')->to('IO#upload');
	$r->post('/render-api/sma')->to('IO#findNewVersion');
	$r->post('/render-api/unique')->to('IO#findUniqueSeeds');
    $r->post('/render-api/tags')->to('IO#setTags');

	$r->any('/rendered')->to('render#problem');
	$r->any('/request' => sub {shift->requestData2JSON});

	# pass all requests via ww2_files through to lib/WeBWorK/htdocs
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
