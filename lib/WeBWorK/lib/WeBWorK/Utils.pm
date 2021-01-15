################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2007 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/Utils.pm,v 1.83 2009/07/12 23:48:00 gage Exp $
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::Utils;
use base qw(Exporter);

use strict;
use warnings;
use DateTime;
use DateTime::TimeZone;
use Date::Format;
use Encode qw(encode_utf8 decode_utf8);
use File::Spec::Functions qw(canonpath);

use constant DATE_FORMAT => "%m/%d/%Y at %I:%M%P %Z";
use constant MKDIR_ATTEMPTS => 10;

our @EXPORT    = ();
our @EXPORT_OK = qw(
	wwRound
	undefstr
	runtime_use
	formatDateTime
	makeTempDirectory
	readFile
	writeTimingLogEntry
	constituency_hash
	writeLog
	surePathToFile
	path_is_subdir
);

sub force_eoln($) {
	my ($string) = @_;
	$string = $string//'';
	$string =~ s/\015\012?/\012/g;
	return $string;
}

sub writeLog($$@) {
	my ($ce, $facility, @message) = @_;
	unless ($ce->{webworkFiles}->{logs}->{$facility}) {
		warn "There is no log file for the $facility facility defined.\n";
		return;
	}
	my $logFile = $ce->{webworkFiles}->{logs}->{$facility};
	surePathToFile($ce->{webworkDirs}->{root}, $logFile);
	local *LOG;
	if (open LOG, ">>", $logFile) {
		print LOG "[", time2str("%a %b %d %H:%M:%S %Y", time), "] @message\n";
		close LOG;
	} else {
		warn "failed to open $logFile for writing: $!";
	}
}

sub surePathToFile($$) {
	# constructs intermediate directories enroute to the file
	# the input path must be the path relative to this starting directory
	my $start_directory = shift;
	my $path = shift;
	my $delim = "/";
	unless ($start_directory and $path ) {
		warn "missing directory<br> surePathToFile  start_directory   path ";
		return '';
	}
	# use the permissions/group on the start directory itself as a template
	my ($perms, $groupID) = (stat $start_directory)[2,5];
	# warn "&urePathToTmpFile: perms=$perms groupID=$groupID\n";

	# if the path starts with $start_directory (which is permitted but optional) remove this initial segment
	$path =~ s|^$start_directory|| if $path =~ m|^$start_directory|;


	# find the nodes on the given path
        my @nodes = split("$delim",$path);

	# create new path
	$path = $start_directory; #convertPath("$tmpDirectory");

	while (@nodes>1) {  # the last node is the file name
		$path = $path . shift (@nodes) . "/"; #convertPath($path . shift (@nodes) . "/");
		#FIXME  this make directory command may not be fool proof.
		unless (-e $path) {
			mkdir($path, $perms)
				or warn "Failed to create directory $path with start directory $start_directory ";
		}

	}

	$path = $path . shift(@nodes); #convertPath($path . shift(@nodes));
	return $path;
}

sub constituency_hash {
	my $hash = {};
	@$hash{@_} = ();
	return $hash;
}

sub wwRound(@) {
# usage wwRound($places,$float)
# return $float rounded up to number of decimal places given by $places
	my $places = shift;
	my $float = shift;
	my $factor = 10**$places;
	return int($float*$factor+0.5)/$factor;
}

sub undefstr($@) {
	map { defined $_ ? $_ : $_[0] } @_[1..$#_];
}

sub runtime_use($;@) {
	my ($module, @import_list) = @_;
	my $package = (caller)[0]; # import into caller's namespace

	my $import_string;
	if (@import_list == 1 and ref $import_list[0] eq "ARRAY" and @{$import_list[0]} == 0) {
		$import_string = "";
	} else {
		# \Q = quote metachars \E = end quoting
		$import_string = "import $module " . join(",", map { qq|"\Q$_\E"| } @import_list);
	}
	eval "package $package; require $module; $import_string";
	die $@ if $@;
}

sub formatDateTime($;$;$;$) {
	my ($dateTime, $display_tz, $format_string, $locale) = @_;
	warn "Utils::formatDateTime is not a method. ", join(" ",caller(2)) if ref($dateTime); # catch bad calls to Utils::formatDateTime
	warn "not defined formatDateTime('$dateTime', '$display_tz') ",join(" ",caller(2)) unless  $display_tz;
	$dateTime = $dateTime ||0;  # do our best to provide default values
	$display_tz ||= "local";    # do our best to provide default vaules
	$display_tz = verify_timezone($display_tz);

	$format_string ||= DATE_FORMAT; # If a format is not provided, use the default WeBWorK date format
	my $dt;
	if($locale) {
	    $dt = DateTime->from_epoch(epoch => $dateTime, time_zone => $display_tz, locale=>$locale);
	}
	else {
	    $dt = DateTime->from_epoch(epoch => $dateTime, time_zone => $display_tz);
	}
	#warn "\t\$dt = ", $dt->strftime(DATE_FORMAT), "\n";
	return $dt->strftime($format_string);
}

sub makeTempDirectory($$) {
	my ($parent, $basename) = @_;
	# Loop until we're able to create a directory, or it fails for some
	# reason other than there already being something there.
	my $triesRemaining = MKDIR_ATTEMPTS;
	my ($fullPath, $success);
	do {
		my $suffix = join "", map { ('A'..'Z','a'..'z','0'..'9')[int rand 62] } 1 .. 8;
		$fullPath = "$parent/$basename.$suffix";
		$success = mkdir $fullPath;
	} until ($success or not $!{EEXIST});
	die "Failed to create directory $fullPath: $!"
		unless $success;
	return $fullPath;
}

sub readFile($) {
	my $fileName = shift;
	# debugging code: found error in CourseEnvironment.pm with this
# 	if ($fileName =~ /___/ or $fileName =~ /the-course-should-be-determined-at-run-time/) {
# 		print STDERR "File $fileName not found.\n Usually an unnecessary call to readFile from\n",
# 		join("\t ", caller()), "\n";
# 		return();
# 	}
	local $/ = undef; # slurp the whole thing into one string
	my $result='';  # need this initialized because the file (e.g. simple.conf) may not exist
	if (-r $fileName) {
		eval{
			# CODING WARNING:
			# if (open my $dh, "<", $fileName){
			# will cause a utf8 "\xA9" does not map to Unicode warning if © is in latin-1 file
			# use the following instead
			if (open my $dh, "<:raw", $fileName){
				$result = <$dh>;
				decode_utf8($result) or die "failed to decode $fileName";
				close $dh;
			} else {
				print STDERR "File $fileName cannot be read."; # this is not a fatal error.
			}
		};
		if ($@) {
			print STDERR "reading $fileName:  error in Utils::readFile: $@\n";
		}
		my $prevent_error_message = utf8::decode($result) or  warn  "Non-fatal warning: file $fileName contains at least one character code which ".
		 "is not valid in UTF-8. (The copyright sign is often a culprit -- use '&amp;copy;' instead.)\n".
		 "While this is not fatal you should fix it\n";
		# FIXME
		# utf8::decode($result) raises an error about the copyright sign
		# decode_utf8 and Encode::decode_utf8 do not -- which is doing the right thing?
	}
	# returns the empty string if the file cannot be read
	return force_eoln($result);
}

sub writeTimingLogEntry($$$$) {
	my ($ce, $function, $details, $beginEnd) = @_;
	$beginEnd = ($beginEnd eq "begin") ? ">" : ($beginEnd eq "end") ? "<" : "-";
	writeLog($ce, "timing", "$$ ".time." $beginEnd $function [$details]");
}

sub path_is_subdir($$;$) {
	my ($path, $dir, $allow_relative) = @_;

	unless ($path =~ /^\//) {
		if ($allow_relative) {
			$path = "$dir/$path";
		} else {
			return 0;
		}
	}

	$path = canonpath($path);
	$path .= "/" unless $path =~ m|/$|;
	return 0 if $path =~ m#(^\.\.$|^\.\./|/\.\./|/\.\.$)#;

	$dir = canonpath($dir);
	$dir .= "/" unless $dir =~ m|/$|;
	return 0 unless $path =~ m|^$dir|;

	return 1;
}

1;
