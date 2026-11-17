package Renderer::AltText;

use strict;
use warnings;

use Mojo::DOM;

# Fill alt text on rendered <img> elements that carry no alt attribute.
#
# Fixed images (OPL resources, src /api/resources/sha256:<hex>.<ext>) take the
# stored alt for their content hash when one is known. Everything else is a
# generated image and gets the identifying rule: "Figure for part N" inside a
# scaffold section numbered N, "Figure for this problem" otherwise. An alt
# attribute already present, including alt="", is never touched.
#
# Returns ($html, \%counts). $html is returned byte-identical when nothing was
# filled; otherwise it is the DOM re-serialised.
sub fill_html {
	my ($html, $alt_by_hash) = @_;
	$alt_by_hash //= {};

	my %counts = (
		fixed_filled     => 0,
		fixed_missing    => 0,
		generated_filled => 0,
		author_alt       => 0,
	);
	return ($html, \%counts) unless defined $html && length $html;

	my $dom = Mojo::DOM->new($html);
	my $changed = 0;

	for my $img ($dom->find('img')->each) {
		if (exists $img->attr->{alt}) {
			$counts{author_alt}++;
			next;
		}

		my $src = $img->attr('src') // '';
		if ($src =~ m{/api/resources/(sha256:[0-9a-f]{64})\.}) {
			my $alt = $alt_by_hash->{$1};
			if (defined $alt) {
				$img->attr(alt => $alt);
				$counts{fixed_filled}++;
				$changed = 1;
			} else {
				$counts{fixed_missing}++;
			}
			next;
		}

		$img->attr(alt => _generated_alt($img));
		$counts{generated_filled}++;
		$changed = 1;
	}

	return ($html, \%counts) unless $changed;
	return ($dom->to_string, \%counts);
}

# "Figure for part N" when the nearest enclosing scaffold section carries a
# section number; "Figure for this problem" otherwise.
sub _generated_alt {
	my ($img) = @_;
	for (my $node = $img->parent; $node; $node = $node->parent) {
		next unless $node->matches('.accordion-item.section-div');
		my $number = $node->at('.section-number');
		next unless $number;
		my $n = $number->text;
		$n =~ s/^\s+|\s+$//g;
		return "Figure for part $n" if length $n;
	}
	return 'Figure for this problem';
}

1;
