package RenderApp::Controller::Render;
use Mojo::Base 'Mojolicious::Controller';

sub form_check {
  my $c = shift;
  my $v = $c->validation;

  unless ($v->has_data) {
    $c->flash(message=>'validation contained no data.');
    return $c->redirect_to('protected');
  }

  $v->required('random_seed')->size(1,5)->like(qr/^[0-9]+$/);
  $v->required('path_to_problem')->like(qr/^[a-zA-Z0-9\-_\.\/]+\.pg$/);

  if ($v->has_error) {
    $c->flash(message=>"validation of form values failed.");
    return $c->redirect_to('protected');
  }

  $c->session->{filePath} = $v->param('path_to_problem');
  $c->session->{seed} = $v->param('random_seed');
  $c->redirect_to('rendered');
}

1;
