package RenderApp::Controller::Editor;
use Mojo::Base 'Mojolicious::Controller';

sub action {
  my $self = shift;
  my $action = $self->param('action');
  $self->session(problemContents=>$self->param('problemContents'));

  if ($action eq 'Save') {
    my $write_path = $self->param('writePathString');
    my $opl_root = $self->app->config('opl_root');
		my $contrib_root = $self->app->config('contrib_root');
		$write_path =~ s!^Library/!$opl_root!;
		$write_path =~ s!^Contrib/!$contrib_root!;
    my $path = Mojo::File->new($write_path);
    my $contents = $self->param('problemContents');
    $path->touch if !(-e $path->to_string);
    if (-w $path->to_string && isAllowed($path) ) {
      # UNIX style line-ending is required
      $contents =~ s/\r\n/\n/g;
      $contents =~ s/\r/\n/g;
      $path->spurt($contents); # write to file
      $self->session(filePath=>$path->to_string); # update location
      $self->stash(message => 'written to file: '.$path->to_string);
    } else {
      $self->stash(message => $path->to_string.' is not writable!');
    }
  } elsif ($action eq 'Render') {
    $self->stash(message => 'this should be redirected to the renderer.');
  } elsif ($action eq 'Revert') {
    $self->session(filePath=>$self->param('readPathString'));
    delete $self->session->{problemContents};
    $self->stash(message => 'reverted to file: '.$self->param('readPathString'));
  }
  $self->render('login/editor');
}

sub isAllowed {
  my $path = shift;
  warn $path;
  return 1;
}

1;
