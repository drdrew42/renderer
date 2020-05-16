package RenderApp;
use Mojo::Base 'Mojolicious';
use Mojo::File 'curfile';

use RenderApp::Model::Users;
#use RenderApp::Model::Problem;

use RenderApp::Controller::RenderProblem;
use WeBWorK::Form;

BEGIN {
	use File::Basename;
	$main::dirname = dirname(__FILE__);
}
$ENV{MOD_PERL_API_VERSION} = 2;
use lib "$main::dirname";
print "home directory ".$main::dirname."\n";

BEGIN {
	# Unused variable, but define it twice to avoid an error message.
	$WeBWorK::Constants::WEBWORK_DIRECTORY = $main::dirname."/WeBWorK";
	$WeBWorK::Constants::PG_DIRECTORY      = $main::dirname."/PG";
	unless (-r $WeBWorK::Constants::WEBWORK_DIRECTORY ) {
		die "Cannot read webwork root directory at $WeBWorK::Constants::WEBWORK_DIRECTORY";
	}
	unless (-r $WeBWorK::Constants::PG_DIRECTORY ) {
		die "Cannot read webwork pg directory at $WeBWorK::Constants::PG_DIRECTORY";
	}
}

sub startup {
  my $self = shift;
  my $problemPath = curfile->dirname->sibling('problem.pg')->to_string;
  my $staticPath = curfile->dirname->sibling('public')->to_string.'/';

  # Config
  $self->plugin('Config');
  $self->secrets($self->config('secrets'));

  # Models
  #$self->helper(problem => sub { state $problem = RenderApp::Model::Problem->new });
  $self->helper(users => sub { state $users = RenderApp::Model::Users->new });

	# helper for rendering problem
	# needs to capture request data and pass along
  $self->helper(renderedProblem => sub{
    my $c = shift;
		my $opl_root = $c->app->config('opl_root');
    my $file_path = shift || $problemPath;
		$file_path =~ s!^Library/!$opl_root!;
		my $seed = shift || '666';
		my $hash = {};
		# it seems that ->Vars encodes an array in case key=>array
		my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
		$hash->{filePath} = $file_path;
		$hash->{problemSeed} = $seed;
		$hash->{form_action_url} = $c->app->config('form');
		$hash->{outputFormat} = 'standard';
		$hash->{inputs_ref} = \%inputs_ref;
    return RenderApp::Controller::RenderProblem::process_pg_file($hash);
  });

	# helper to reveal request data
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
  $r->any('/')->to('login#index')->name('index');

  my $logged_in = $r->under('/')->to('login#logged_in');
  $logged_in->get('/protected')->to('login#protected');
	$logged_in->any('/render')->to('render#form_check');
	$logged_in->any('/rendered')->to('login#rendered');

  $r->get('/logout')->to('login#logout');

  # pass all requests via ww2_files through to public
  $r->any('/webwork2_files/*path' => sub {
    my $c = shift;
    $c->reply->file($staticPath.$c->stash('path'));
  });
}

1;
