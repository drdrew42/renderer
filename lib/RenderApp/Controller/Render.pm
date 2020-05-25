package RenderApp::Controller::Render;
use Mojo::Base 'Mojolicious::Controller';

sub form_check {
  my $c = shift;
  my $v = $c->validation;

  unless ($v->has_data) {
    $c->flash(message=>'Your request contained no data.');
    return $c->redirect_to('request');
  }

  $v->required('random_seed')->size(1,6)->like(qr/^[0-9]+$/);
  $v->required('path_to_problem')->like(qr/^[a-zA-Z0-9\-_\.\/]+\.pg$/);
  $v->optional('format');
  $v->optional('template');

  if ($v->has_error) {
    $c->flash(message=>"Your request was malformed.");
    return $c->redirect_to('request');
  }

  $c->session->{filePath} = $v->param('path_to_problem');
  $c->session->{seed} = $v->param('random_seed');
  $c->session->{template} = $v->param('template');
  $c->session->{format} = $v->param('format');
  $c->redirect_to('rendered');
}

1;
