use strict;
use warnings;

use Test::More;
use Mojo::DOM;

use Renderer::AltText;

my $H1 = 'sha256:' . ('a' x 64);
my $H2 = 'sha256:' . ('b' x 64);

sub fixed_src {
	my ($hash, $ext) = @_;
	$ext //= 'png';
	return "https://opl.example.edu/api/resources/$hash.$ext";
}

# Scaffold section numbered $n wrapping $body, as PG emits it (scaffold.pl:583-622).
sub section {
	my ($n, $body) = @_;
	return qq{<div class="accordion-item section-div">}
		. qq{<div class="accordion-header iswrong canopen" id="s$n-header">}
		. qq{<button class="accordion-button" type="button">}
		. qq{<span class="section-number">$n</span><span class="section-title">Part $n</span>}
		. qq{</button></div>}
		. qq{<div class="accordion-collapse collapse" id="s$n">}
		. qq{<div class="accordion-body">$body</div></div></div>};
}

sub img_tag {
	my ($src, $extra) = @_;
	$extra //= '';
	return qq{<img src="$src" class="image-view-elt $extra" tabindex="0" role="button">};
}

subtest 'fixed image without alt takes the stored alt' => sub {
	my $html = '<p>' . img_tag(fixed_src($H1)) . '</p>';
	my ($out, $counts) = Renderer::AltText::fill_html($html, { $H1 => 'A parabola opening up' });

	my $img = Mojo::DOM->new($out)->at('img');
	is($img->attr('alt'), 'A parabola opening up', 'stored alt written');
	is($counts->{fixed_filled}, 1, 'fixed_filled counted');
	is($counts->{fixed_missing}, 0, 'fixed_missing not counted');
};

subtest 'existing alt attributes are untouched, including empty' => sub {
	my $with_alt  = img_tag(fixed_src($H1)) =~ s/role=/alt="x" role=/r;
	my $empty_alt = img_tag(fixed_src($H1)) =~ s/role=/alt="" role=/r;
	my $html      = $with_alt . $empty_alt;
	my ($out, $counts) = Renderer::AltText::fill_html($html, { $H1 => 'stored' });

	my @alts = map { $_->attr('alt') } Mojo::DOM->new($out)->find('img')->each;
	is_deeply(\@alts, [ 'x', '' ], 'author alt and empty alt both preserved');
	is($counts->{author_alt}, 2, 'author_alt counts images that carry an alt attribute');
	is($counts->{fixed_filled}, 0, 'nothing filled');
};

subtest 'fixed image with no stored alt is counted missing and left alone' => sub {
	my $html = img_tag(fixed_src($H2));
	my ($out, $counts) = Renderer::AltText::fill_html($html, { $H1 => 'other' });

	is($out, $html, 'output identical to input when nothing filled');
	is($counts->{fixed_missing}, 1, 'fixed_missing counted');
	ok(!defined Mojo::DOM->new($out)->at('img')->attr('alt'), 'no alt attribute added');
};

subtest 'fixed image with a null stored alt is missing' => sub {
	my $html = img_tag(fixed_src($H1));
	my ($out, $counts) = Renderer::AltText::fill_html($html, { $H1 => undef });

	is($counts->{fixed_missing}, 1, 'undef alt treated as missing');
	is($out, $html, 'untouched');
};

subtest 'generated image in a scaffold section gets the part rule' => sub {
	my $html = section(3, img_tag('/api/problems/42/graph.png'));
	my ($out, $counts) = Renderer::AltText::fill_html($html, {});

	is(Mojo::DOM->new($out)->at('img')->attr('alt'), 'Figure for part 3', 'part number from section-number');
	is($counts->{generated_filled}, 1, 'generated_filled counted');
};

subtest 'generated image outside a section gets the problem rule' => sub {
	my $html = '<div>' . img_tag('/api/problems/42/graph.png') . '</div>';
	my ($out, $counts) = Renderer::AltText::fill_html($html, {});

	is(Mojo::DOM->new($out)->at('img')->attr('alt'), 'Figure for this problem', 'problem rule');
	is($counts->{generated_filled}, 1, 'generated_filled counted');
};

subtest 'nested section uses the nearest numbered ancestor' => sub {
	my $inner = section(2, img_tag('/api/problems/42/inner.png'));
	my $html  = section(1, $inner . img_tag('/api/problems/42/outer.png'));
	my ($out) = Renderer::AltText::fill_html($html, {});

	my @alts = map { $_->attr('alt') } Mojo::DOM->new($out)->find('img')->each;
	is_deeply(\@alts, [ 'Figure for part 2', 'Figure for part 1' ], 'nearest section wins at each depth');
};

subtest 'generated rule ignores a fixed-looking hash that is not a resource' => sub {
	my $html = img_tag("https://example.com/static/$H1.png");
	my ($out, $counts) = Renderer::AltText::fill_html($html, { $H1 => 'should not apply' });

	is($counts->{fixed_filled}, 0, 'not a /api/resources/ src');
	is(Mojo::DOM->new($out)->at('img')->attr('alt'), 'Figure for this problem', 'generated rule applies');
};

subtest 'HTML outside img attributes is unchanged after DOM normalisation' => sub {
	my $html = join "\n",
		'<h1 class="problem">Graph</h1>',
		'<p>Consider <em>this</em> &amp; that.</p>',
		section(1, '<p>Part one</p>' . img_tag(fixed_src($H1), 'valign-top') . img_tag('/api/problems/9/g.png')),
		'<ul><li>' . img_tag(fixed_src($H2)) . '</li><li>text</li></ul>',
		'<img src="https://opl.example.edu/api/resources/' . $H1 . '.png" alt="kept">';

	my ($out, $counts) = Renderer::AltText::fill_html($html, { $H1 => 'parabola' });
	is($counts->{fixed_filled}, 1, 'fixed filled');
	is($counts->{generated_filled}, 1, 'generated filled');
	is($counts->{fixed_missing}, 1, 'fixed missing');
	is($counts->{author_alt}, 1, 'author alt counted');

	# Images that were alt-less on input, in document order.
	my $din = Mojo::DOM->new($html);
	my $dout = Mojo::DOM->new($out);
	my @in_imgs  = $din->find('img')->each;
	my @out_imgs = $dout->find('img')->each;
	is(scalar @out_imgs, scalar @in_imgs, 'same number of images');

	for my $i (0 .. $#out_imgs) {
		delete $out_imgs[$i]->attr->{alt} unless exists $in_imgs[$i]->attr->{alt};
	}

	is($dout->to_string, $din->to_string, 'everything except the added alts is identical');
};

subtest 'no images: input returned unchanged with zero counts' => sub {
	my $html = '<p>plain text</p>';
	my ($out, $counts) = Renderer::AltText::fill_html($html, {});
	is($out, $html, 'unchanged');
	is_deeply($counts, { fixed_filled => 0, fixed_missing => 0, generated_filled => 0, author_alt => 0 },
		'all counts zero');
};

done_testing();
