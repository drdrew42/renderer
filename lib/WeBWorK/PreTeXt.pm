package WeBWorK::PreTeXt;

use strict;
use warnings;

use Mojo::DOM;
use Mojo::IOLoop;
use Data::Structure::Util qw(unbless);

use lib "$ENV{PG_ROOT}/lib";
use WeBWorK::PG;

sub render_ptx {
	my $p      = shift;
	my $source = $p->{rawProblemSource};

	return Mojo::IOLoop->subprocess->run_p(sub {
		my $pg = WeBWorK::PG->new(
			showSolutions  => 1,
			showHints      => 1,
			processAnswers => 1,
			displayMode    => 'PTX',
			problemSeed    => $p->{problemSeed} // 1234,
			$p->{problemUUID}    ? (problemUUID    => $p->{problemUUID})    : (),
			$p->{sourceFilePath} ? (sourceFilePath => $p->{sourceFilePath}) : (),
			$source              ? (r_source       => \$source)             : ()
		);

		# Assemble the result under eval so $pg->free runs on every path — a
		# failure building the answerhash DOM must still release the PG object
		# before the error propagates.
		my $ret = eval {
			my $dom = Mojo::DOM->new->xml(1);
			for my $answer (sort keys %{ $pg->{answers} }) {
				$dom->append_content($dom->new_tag(
					$answer, map { $_ => ($pg->{answers}{$answer}{$_} // '') } keys %{ $pg->{answers}{$answer} }
				));
			}
			$dom->wrap_content('<answerhashes></answerhashes>');
			{ problemText => $pg->{body_text}, answerhashXML => $dom->to_string };
		};
		my $err = $@;

		$pg->free;
		die $err if $err;
		return $ret;
	});
	# Failure leaves the promise rejected; the caller maps that to a 500.
}
1;
