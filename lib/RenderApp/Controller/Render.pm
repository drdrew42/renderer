package RenderApp::Controller::Render;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::File;
use RenderApp::Controller::RenderProblem;
use MIME::Base64 qw(decode_base64);

sub problem {
  my $c = shift;
  my $opl_root = $c->app->config('opl_root');
  my $contrib_root = $c->app->config('contrib_root');
  my $file_path = $c->param('sourceFilePath'); # || $c->session('filePath');
  $file_path =~ s!^Library/!$opl_root!;
  $file_path =~ s!^Contrib/!$contrib_root!;
  $c->render(json => {
    statusCode => 404,
    error => "Not Found",
    message => "I cannot find a problem with that file path."
  }, status => 404) unless (-r $file_path);
  my $hash = {};
  # it seems that ->Vars encodes an array in case key=>array
  my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
  $hash->{filePath} = $file_path;
  $hash->{problemSeed} = $c->param('problemSeed'); # || $c->session('seed');
  $hash->{form_action_url} = $c->param('formURL') || $c->app->config('form');
  $hash->{base_url} = $c->param('baseURL') || $c->app->config('url');
  $hash->{outputformat} = $c->param('outputformat'); # || $c->session('template');
  $hash->{inputs_ref} = \%inputs_ref;
  my $ww_return_json = RenderApp::Controller::RenderProblem::process_pg_file($hash);
  my $ww_return_hash = decode_json($ww_return_json);
  $c->respond_to(
    html => { text => $ww_return_hash->{renderedHTML}},
    json => { json => $ww_return_hash }
  );
}

sub raw {
  my $c = shift;
  my $opl_root = $c->app->config('opl_root');
  my $contrib_root = $c->app->config('contrib_root');
  my $file_path = $c->param('sourceFilePath'); # || $c->session('filePath');
  $file_path =~ s!^Library/!$opl_root!;
  $file_path =~ s!^Contrib/!$contrib_root!;
  return $c->render(json => {
    statusCode => 404,
    error => "Not Found",
    message => "I cannot find a problem with that file path."
  }, status => 404) unless (-r $file_path);
  $c->render(text => Mojo::File->new($file_path)->slurp);
}

sub writer {
  my $c = shift;
  my $opl_root = $c->app->config('opl_root');
  my $contrib_root = $c->app->config('contrib_root');
  my $file_path = $c->param('writeFilePath'); # || $c->session('filePath');
  $file_path =~ s!^Library/!$opl_root!;
  $file_path =~ s!^Contrib/!$contrib_root!;
  my $source = decode_base64($c->param('problemSource'));
  if ($file_path =~ m/^webwork-open-problem-library/) {
    Mojo::File->new($file_path)->spurt($source);
    $c->res->body($file_path);
    $c->rendered(200);
  } else {
    $c->res->body("You do not have permission to save to that path.");
    $c->rendered(403);
  }
}

1;
