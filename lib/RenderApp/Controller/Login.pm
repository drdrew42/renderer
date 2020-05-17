package RenderApp::Controller::Login;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $self = shift;
  return $self->render unless $self->param('agreed');
  $self->session(token => 'valid');
  $self->flash(message => 'Access token generated.');
  $self->redirect_to('request');
}

sub is_valid {
  my $self = shift;
  return 1 if $self->session('token');
  $self->redirect_to('index');
  return undef;
}

sub logout {
  my $self = shift;
  $self->session(expires => 1);
  $self->flash(message => 'Mischief managed.');
  $self->redirect_to('index');
}

sub request {
  my $self = shift;
  delete $self->session->{filePath} if $self->session->{filePath};
  delete $self->session->{seed} if $self->session->{seed};
  $self->render;
}

1;
