package Renderer::Controller::StaticFiles;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::File            qw(path);
use File::Spec::Functions qw(canonpath);

sub path_is_subdir ($path, $dir) {
	return 0 unless $path =~ /^\//;

	$path = canonpath($path);
	return 0 if $path =~ m#(^\.\.$|^\.\./|/\.\./|/\.\.$)#;

	$dir = canonpath($dir);
	return 0 unless $path =~ m|^$dir|;

	return 1;
}

sub reply_with_file_if_readable ($c, $directory, $file) {
	my $filePath = $directory->child($file);
	if (-r $filePath && path_is_subdir($filePath, $directory)) {
		return $c->reply->file($filePath);
	} else {
		return $c->render(data => 'File not found', status => 404);
	}
}

# Route requests for pg_files/CAPA_Graphics to render root Contrib/CAPA/CAPA_Graphics
sub CAPA_graphics_file ($c) {
	return $c->reply_with_file_if_readable($c->app->home->child('Contrib/CAPA/CAPA_Graphics'), $c->stash('static'));
}

# Route requests for pg_files to the render root tmp.  The
# only requests should be for files in the temporary directory.
# FIXME: Perhaps this directory should be configurable.
sub temp_file ($c) {
	return $c->reply_with_file_if_readable($c->app->home->child('tmp'), $c->stash('static'));
}

# Route request to pg_files to lib/PG/htdocs.
sub pg_file ($c) {
	return $c->reply_with_file_if_readable(path($ENV{PG_ROOT}, 'htdocs'), $c->stash('static'));
}

sub public_file ($c) {
	return $c->reply_with_file_if_readable($c->app->home->child('public'), $c->stash('static'));
}

1;
