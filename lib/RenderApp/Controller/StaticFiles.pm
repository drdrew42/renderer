package RenderApp::Controller::StaticFiles;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::File qw(path);

sub reply_with_file_if_readable ($c, $file) {
	if (-r $file) {
		return $c->reply->file($file);
	} else {
		return $c->render(data => 'File not found', status => 404);
	}
}

# Route requests for pg_files/CAPA_Graphics to render root Contrib/CAPA/CAPA_Graphics
sub CAPA_graphics_file ($c) {
	return $c->reply_with_file_if_readable($c->app->home->child('Contrib/CAPA/CAPA_Graphics', $c->stash('static')));
}

# Route requests for pg_files to the render root tmp.  The
# only requests should be for files in the temporary directory.
# FIXME: Perhaps this directory should be configurable.
sub temp_file ($c) {
	$c->reply_with_file_if_readable($c->app->home->child('tmp', $c->stash('static')));
}

# Route request to pg_files to lib/PG/htdocs.
sub pg_file ($c) {
	$c->reply_with_file_if_readable(path($ENV{PG_ROOT}, 'htdocs', $c->stash('static')));
}

sub public_file($c) {
    $c->reply_with_file_if_readable($c->app->home->child('public', $c->stash('static')));
}

1;
