package Padre::Plugin::Perl6::Perl6ColorizerTask;

use strict;
use warnings;
use base 'Padre::Task';

our $VERSION = '0.42';
our $thread_running = 0;

# This is run in the main thread before being handed
# off to a worker (background) thread. The Wx GUI can be
# polled for information here.
# If you don't need it, just inherit this default no-op.
sub prepare {
	my $self = shift;

	# it is not running yet.
	$self->{broken} = 0;
	
	# put editor into main-thread-only storage
	$self->{main_thread_only} ||= {};
	my $document = $self->{document} || $self->{main_thread_only}{document};
	my $editor = $self->{editor} || $self->{main_thread_only}{editor};
	delete $self->{document};
	delete $self->{editor};
	$self->{main_thread_only}{document} = $document;
	$self->{main_thread_only}{editor} = $editor;

	# assign a place in the work queue
	if($thread_running) {
		# single thread instance at a time please. aborting...
		$self->{broken} = 1;
		return "break";
	}
	$thread_running = 1;
	return 1;
}

sub is_broken {
	my $self = shift;
	return $self->{broken};
}

my %colors = (
	'comp_unit'  => Padre::Constant::BLUE,
	'scope_declarator' => Padre::Constant::RED,
	'routine_declarator' => Padre::Constant::RED,
	'regex_declarator' => Padre::Constant::RED,
	'package_declarator' => Padre::Constant::RED,
	'statement_control' => Padre::Constant::RED,
	'block' => Padre::Constant::BLACK,
	'regex_block' => Padre::Constant::BLACK,
	'noun' => Padre::Constant::BLACK,
	'sigil' => Padre::Constant::GREEN,
	'variable' => Padre::Constant::GREEN,
	'assertion' => Padre::Constant::GREEN,
	'quote' => Padre::Constant::MAGENTA,
	'number' => Padre::Constant::ORANGE,
	'infix' => Padre::Constant::DIM_GRAY,
	'methodop' => Padre::Constant::BLACK,
	'pod_comment' => Padre::Constant::GREEN,
	'param_var' => Padre::Constant::CRIMSON,
	'_scalar' => Padre::Constant::RED,
	'_array' => Padre::Constant::BROWN,
	'_hash' => Padre::Constant::ORANGE,
	'_comment' => Padre::Constant::GREEN,
);

# This is run in the main thread after the task is done.
# It can update the GUI and do cleanup.
# You don't have to implement this if you don't need it.
sub finish {
	my $self = shift;
	my $mainwindow = shift;

	my $doc = $self->{main_thread_only}{document};
	my $editor = $self->{main_thread_only}{editor};
	if($self->{tokens}) {
		$doc->remove_color;
		my @tokens = @{$self->{tokens}};
		for my $htoken (@tokens) {
			my %token = %{$htoken};
			my $color = $colors{ $token{rule} };
			if($color) {
				my $len = length $token{buffer};
				my $start = $token{last_pos} - $len;
				$editor->StartStyling($start, $color);
				$editor->SetStyling($len, $color);
			}
		}
		$doc->{tokens} = $self->{tokens};
	} else {
		$doc->{tokens} = [];
	}
	
	if($self->{issues}) {
		# pass errors/warnings to document...
		$doc->{issues} = $self->{issues};
	} else {
		$doc->{issues} = [];
	}
	
	$doc->check_syntax_in_background(force => 1);
	$doc->get_outline(force => 1);

	# finished here
	$thread_running = 0;

	return 1;
}

# Task thread subroutine
sub run {
	my $self = shift;

	# temporary file for the process STDIN
	require File::Temp;
	my $tmp_in = File::Temp->new( SUFFIX => '_p6_in.txt' );
	binmode $tmp_in, ':utf8';
	print $tmp_in $self->{text};
	delete $self->{text};
	close $tmp_in or warn "cannot close $tmp_in\n";

	# temporary file for the process STDOUT
	my $tmp_out = File::Temp->new( SUFFIX => '_p6_out.txt' );
	close $tmp_out or warn "cannot close $tmp_out\n";
	
	# temporary file for the process STDERR
	my $tmp_err = File::Temp->new( SUFFIX => '_p6_err.txt' );
	close $tmp_err or warn "cannot close $tmp_out\n";
	
	# construct the command
	require Cwd;
	require File::Basename;
	require File::Spec;
	my $cmd = Padre->perl_interpreter . " " .
		Cwd::realpath(File::Spec->join(File::Basename::dirname(__FILE__),'p6tokens.pl')) .
		" $tmp_in $tmp_out $tmp_err";
	
	# all this is needed to prevent win32 platforms from:
	# 1. popping out a command line on each run...
	# 2. STD.pm uses Storable 
	# 3. Padre TaskManager does not like tasks that do Storable operations...
	if($^O =~ /MSWin/) {
		# on win32 platforms, we need to use this to prevent command line popups when using wperl.exe
		require Win32;
		require Win32::Process;

		sub print_error {
		   print Win32::FormatMessage(Win32::GetLastError());
		}

		my $p_obj;
		Win32::Process::Create($p_obj, Padre->perl_interpreter, $cmd, 0, Win32::Process::DETACHED_PROCESS(), '.') 
			or warn &print_error;
		$p_obj->Wait(Win32::Process::INFINITE());
	} else {
		# On other platforms, we will simply use the perl way of calling a command
		`$cmd`;
	}
		
	my ($out, $err);
	{
		local $/ = undef;   #enable localized slurp mode

		# slurp the process output...
		open CHLD_OUT, $tmp_out	or warn "Could not open $tmp_out";
		binmode CHLD_OUT;
		$out = <CHLD_OUT>;
		close CHLD_OUT or warn "Could not close $tmp_out\n";
		
		open CHLD_ERR, $tmp_err or warn "Cannot open $tmp_err\n";
		binmode CHLD_ERR, ':utf8';
		$err = <CHLD_ERR>;
		close CHLD_ERR or warn "Could not close $tmp_err\n";
	}
	
	if($err) {
		# remove ANSI color escape sequences...
		$err =~ s/\033\[\d+(?:;\d+(?:;\d+)?)?m//g;
		print qq{STD.pm warning/error:\n$err\n};
		my @messages = split /\n/, $err;
		my ($lineno, $severity);
		my $issues = [];
		for my $msg (@messages) {
			if($msg =~ /^\#\#\#\#\# PARSE FAILED \#\#\#\#\#/) {
				# the following lines are errors until we see the warnings section
				$severity = 'E';
			} elsif($msg =~ /^Potential difficulties/) {
				# all rest are warnings...
				$severity = 'W';
			} elsif($msg =~ /line (\d+):$/i) {
				# record the line number
				$lineno = $1;
			} elsif($msg =~ /^Can't locate object method ".+?" via package "STD"/) {
				# STD lex cache is corrupt...
				$msg = qq{'STD Lex Cache' is corrupt. Please use Plugins/Perl6/Cleanup STD Lex Cache.};
				push @{$issues}, { line => 1, msg => $msg, severity => 'E', };
				# no need to continue collecting errors...
				last; 
			}
			if($lineno) {
				push @{$issues}, { line => $lineno, msg => $msg, severity => $severity, };
			}
		}
		$self->{issues} = $issues;
	} 
	
	if($out) {
		eval {
			require Storable;
		 	$self->{tokens} = Storable::thaw($out);
		};
		if ($@) {
			warn "Exception: $@";
		}
	}

	return 1;
};

1;