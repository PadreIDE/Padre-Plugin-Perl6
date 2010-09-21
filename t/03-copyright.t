use strict;
use warnings;

use Test::More;
use File::Find::Rule;

BEGIN {
	if ( not $ENV{DISPLAY} and not $^O eq 'MSWin32' ) {
		plan skip_all => 'Needs DISPLAY';
		exit 0;
	}
}

# Don't run tests for installs
unless ( $ENV{AUTOMATED_TESTING} or $ENV{RELEASE_TESTING} ) {
	plan( skip_all => "Author tests not required for installation" );
}

my @files = File::Find::Rule->name('*.pm')->file->in('lib');
plan tests => scalar @files;

#
# a simple way to check if we have copyright information on all files
# that was taken from Padre t/10-copyright.t
#
my $copyright = qr{Padre Developers as in Perl6.pm\s*};
$copyright = qr{${copyright}This program is free software; you can redistribute it and/or\s*};
$copyright = qr{${copyright}modify it under the same terms as Perl 5 itself.};

foreach my $file (@files) {
	my $content = slurp($file);
	ok( $content =~ qr{$copyright}, $file );
}

sub slurp {
	my $file = shift;
	open my $fh, '<', $file or die "Could not open '$file' $!'";
	local $/ = undef;
	return <$fh>;
}
