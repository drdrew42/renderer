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
print "RENDER_ROOT: ".$ENV{RENDER_ROOT}."\n";
print "WEBWORK ROOT: ".$ENV{WEBWORK_ROOT}."\n";
print "WEBWORK_DIRECTORY: ".$WeBWorK::Constants::WEBWORK_DIRECTORY."\n";
print "OPL_DIRECTORY: ".$ENV{OPL_DIRECTORY}."\n";
print "PG_DIRECTORY: ".$WeBWorK::Constants::PG_DIRECTORY."\n";

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

	# helper for rendering problem
	# needs to capture request data and pass along
	$self->helper(renderedProblem => sub{
    my $c = shift;
		my $opl_root = $c->app->config('opl_root');
		my $contrib_root = $c->app->config('contrib_root');
    my $file_path = $c->param('sourceFilePath') || $c->session('filePath');
		$file_path =~ s!^Library/!$opl_root!;
		$file_path =~ s!^Contrib/!$contrib_root!;
		my $format = $c->param('format') || $c->session('format');
		my $hash = {};
		# it seems that ->Vars encodes an array in case key=>array
		my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
		$hash->{filePath} = $file_path;
		$hash->{problemSeed} = $c->param('problemSeed') || $c->session('seed');
		$hash->{form_action_url} = $c->param('formURL') || $c->app->config('form');
		$hash->{base_url} = $c->param('baseURL') || $c->app->config('url');
		$hash->{outputformat} = $c->param('template') || $c->session('template');
		$hash->{inputs_ref} = \%inputs_ref;
    return RenderApp::Controller::RenderProblem::process_pg_file($hash);
  });

  $self->helper(fetchProblemSource => sub{
		my $c = shift;
		my $file_path = $c->param('sourceFilePath') || $c->session('filePath');
		return unless $file_path;
		my $opl_root = $c->app->config('opl_root');
		my $contrib_root = $c->app->config('contrib_root');
		$file_path =~ s!^Library/!$opl_root!;
		$file_path =~ s!^Contrib/!$contrib_root!;
		$file_path = Mojo::File->new($file_path);
		return unless (-r $file_path);
		#$c->session( pathString => $file_path->to_string );
		return $file_path->slurp;
	});

	# helper to expose request data
  $self->helper(requestData => sub {
		my $c = shift;
		my $string = "";
		my @all_param_names = @{$c->req->params->names};
		foreach my $key (@all_param_names) {
			$string = $string."[".$key."] => ".$c->param($key)."<br>";
		}
		return $string;
	});

  # Routes to controller
  my $r = $self->routes;
  #$r->any('/')->to('login#index')->name('index');

	$r->any('/')->to('login#ui');
	$r->post('/render-api/')->to('render#problem');
	$r->post('/render-api/tap')->to('IO#raw');
	$r->post('/render-api/can')->to('IO#writer');
	$r->any('/render-api/cat')->to('IO#catalog');

  #my $logged_in = $r->under('/')->to('login#is_valid');
  $r->get('/request')->to('login#request');
	$r->any('/render')->to('render#problem');
	$r->any('/rendered')->to('render#problem');

  $r->get('/logout')->to('login#logout');

  # pass all requests via ww2_files through to public
	$r->any('/webwork2_files/*path' => sub {
    my $c = shift;
    $c->reply->file($staticPath.$c->stash('path'));
  });
}

1;
