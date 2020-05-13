package RenderApp::Controller::Login;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $self = shift;

  my $user = $self->param('user') || '';
  my $pass = $self->param('pass') || '';
  return $self->render unless $self->users->check($user, $pass);

  $self->session(user => $user);
  $self->flash(message => 'Thanks for logging in.');
  $self->redirect_to('protected');
}

sub logged_in {
  my $self = shift;
  return 1 if $self->session('user');
  $self->redirect_to('index');
  return undef;
}

sub logout {
  my $self = shift;
  $self->session(expires => 1);
  $self->redirect_to('index');
}

sub protected {
  my $self = shift;
  delete $self->session->{filePath} if $self->session->{filePath};
  delete $self->session->{seed} if $self->session->{seed};
  $self->render; #(template=>'login/protected');
}

1;
