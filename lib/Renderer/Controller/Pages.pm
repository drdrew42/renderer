package Renderer::Controller::Pages;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub twocolumn ($c) {
	$c->render(template => 'pages/twocolumn');
}

sub oplUI ($c) {
	$c->render(template => 'pages/oplUI');
}

1;
