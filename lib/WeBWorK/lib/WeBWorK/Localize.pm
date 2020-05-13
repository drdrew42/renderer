package WeBWorK::Localize;

use File::Spec;

use Locale::Maketext;
use Locale::Maketext::Lexicon;

my $path = "$WeBWorK::Constants::WEBWORK_DIRECTORY/lib/WeBWorK/Localize";
my   $pattern = File::Spec->catfile($path, '*.[pm]o');
my   $decode = 1;
my   $encoding = undef;

eval "
	package WeBWorK::Localize::I18N;
	use base 'Locale::Maketext';
    %WeBWorK::Localize::I18N::Lexicon = ( '_AUTO' => 1 );
	Locale::Maketext::Lexicon->import({
	    'i-default' => [ 'Auto' ],
	    '*'	=> [ Gettext => \$pattern ],
	    _decode => \$decode,
	    _encoding => \$encoding,
	});
	*tense = sub { \$_[1] . ((\$_[2] eq 'present') ? 'ing' : 'ed') };

" or die "Can't process eval in WeBWorK/Localize.pm: line 35:  ". $@;

package WeBWorK::Localize;

sub getLoc {
	my $lang = shift;
	my $lh = WeBWorK::Localize::I18N->get_handle($lang);
	return sub {$lh->maketext(@_)};
}


1;
