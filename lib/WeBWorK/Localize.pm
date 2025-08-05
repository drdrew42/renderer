package WeBWorK::Localize;
use Mojo::Base 'Locale::Maketext', -strict;

use Locale::Maketext::Lexicon;
use Mojo::File;

Locale::Maketext::Lexicon->import({
	'i-default' => ['Auto'],
	'*'         => [ Gettext => Mojo::File::curfile->dirname->child('Localize', '*.[pm]o')->to_string ],
	_decode     => 1,
	_encoding   => undef,
});

sub getLangHandle {
	my $lang = shift;
	return WeBWorK::Localize->get_handle($lang);
}

# This is like [quant] but it doesn't write the number.
#  usage: [quant,_1,<singular>,<plural>,<optional zero>]
sub plural {
	my ($handle, $num, @forms) = @_;

	return ''        if @forms == 0;
	return $forms[2] if @forms > 2 and $num == 0;

	# Normal case:
	return ($handle->numerate($num, @forms));
}

# This is like [quant] but it also has -1 case.
#  usage: [negquant,_1,<neg case>,<singular>,<plural>,<optional zero>]
sub negquant {
	my ($handle, $num, @forms) = @_;

	return $num if @forms == 0;

	my $negcase = shift @forms;
	return $negcase if $num < 0;

	return $forms[2] if @forms > 2 and $num == 0;
	return ($handle->numf($num) . ' ' . $handle->numerate($num, @forms));
}

our %Lexicon = ('_AUTO' => 1);

1;
