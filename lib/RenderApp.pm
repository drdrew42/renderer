package RenderApp;
use Mojo::Base 'Mojolicious';
use Mojo::File;

BEGIN {
	#use File::Basename;
	use Mojo::File;
	$main::dirname = Mojo::File::curfile->dirname;
	#RENDER_ROOT is required for initializing conf files
	$ENV{RENDER_ROOT} = $main::dirname->dirname unless ( defined($ENV{RENDER_ROOT}) );
	#WEBWORK_ROOT is required for PG/lib/WeBWorK/IO
	$ENV{WEBWORK_ROOT} = $main::dirname.'/WeBWorK' unless ( defined($ENV{WEBWORK_ROOT}) );
	#used for reconstructing library paths from sym-links
	$ENV{OPL_DIRECTORY}	=	"webwork-open-problem-library";
	$WeBWorK::Constants::WEBWORK_DIRECTORY = $main::dirname."/WeBWorK";
	$WeBWorK::Constants::PG_DIRECTORY      = $main::dirname."/PG";
}
#$ENV{MOD_PERL_API_VERSION} = 2;
use lib "$main::dirname";
print "home directory ".$main::dirname."\n";

BEGIN {
	unless (-r $WeBWorK::Constants::WEBWORK_DIRECTORY ) {
		die "Cannot read webwork root directory at $WeBWorK::Constants::WEBWORK_DIRECTORY";
	}
	unless (-r $WeBWorK::Constants::PG_DIRECTORY ) {
		die "Cannot read webwork pg directory at $WeBWorK::Constants::PG_DIRECTORY";
	}
}

use RenderApp::Model::Problem;
use RenderApp::Controller::RenderProblem;

use WeBWorK::Form;
use WeBWorK::Constants;

sub startup {
  my $self = shift;
  my $staticPath = $WeBWorK::Constants::WEBWORK_DIRECTORY."/htdocs/"; #curfile->dirname->sibling('public')->to_string.'/';

  # Config
  $self->plugin('Config');
	$self->plugin('TagHelpers');
  $self->secrets($self->config('secrets'));

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

  # Routes to controller
  my $r = $self->routes;

	$r->any('/')->to('login#ui');
	$r->post('/render-api/')->to('render#problem');
	$r->post('/render-api/tap')->to('IO#raw');
	$r->post('/render-api/can')->to('IO#writer');
	$r->any('/render-api/cat')->to('IO#catalog');

	$r->any('/rendered')->to('render#problem');
	$r->any('/request' => sub {
		my $c =shift;
		$c->requestData2JSON;
	});

  # pass all requests via ww2_files through to lib/WeBWorK/htdocs
	$r->any('/webwork2_files/*path' => sub {
    my $c = shift;
    $c->reply->file($staticPath.$c->stash('path'));
  });
}

1;
