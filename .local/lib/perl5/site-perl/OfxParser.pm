#!/usr/bin/env perl
package OfxParser;

use strict;
use warnings;
use Carp;
use Data::Dumper;	#FIXME: debug only

# constructor, as if you didn't know
sub new
{
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = {};
	bless $self, $class;
	$self->{file} = undef;
	$self->{fh} = undef;
	$self->{lineno} = 0;
	$self->{stack} = [];
	return $self;
}

# die with the given message after appending the current input line number
sub die
{
	my $self = shift;
	my $msg = shift;
	my $dbg = shift // $self;
	$msg .= sprintf(" at tag %d in %s line %d\n",
		$self->{tagno}, $self->{file}, $self->{lineno});
	$msg .= Dumper($dbg) . "\n";
	confess $msg;
}

# advance to the next nonblank line and peek at the tag
sub peek
{
	my $self = shift;
	my $fh = $self->{fh};
	if (!defined $self->{buffer} || @{$self->{buffer}} == 0)
	{
		do {
			$self->die("unexpected end of file") unless (defined($_ = <$fh>));
			++$self->{lineno};
		} while($_ eq '');
		s!<(\w+)\s*/>!<$1></$1>!g;	# convert <TAG /> TO <TAG></TAG>
		@{$self->{buffer}} = m/\s*<([^>]+)>([^\r\n\<]*)/g;
	}
	return @{$self->{buffer}}[0];
}

# advance to the next nonblank line and extract the tag and optional value
sub advance
{
	my $self = shift;
	$self->peek();
	$self->{tag} = shift @{$self->{buffer}};
	$self->{val} = shift @{$self->{buffer}};
	++$self->{tagno};
}

# Parse a file
sub parse
{
	my $self = shift;
	$self->{file} = shift;
	$self->{stack} = [];
	$self->{lineno} = 0;
	if (! -s $self->{file})
	{
		print STDERR "Skipping ",$self->{file}," because it's empty.\n";
		return;
	}
	open(my $fh,"<",$self->{file}) || CORE::die "Can't open $self->{file}: $!";
	$self->{fh} = $fh;
	my ($key,$val);
	while(1)
	{
		$self->die("unexpected end of file") unless (defined($_ = <$fh>));
		++$self->{lineno};
		last unless (($key,$val) = /^([^:]+):(.*)[\r\n]*$/);
		$self->{header}->{$key} = $val;
	}
	CORE::die "File doesn't contain OFXHEADER:100\n" unless ($self->{header}->{OFXHEADER} == 100);
	CORE::die "File isn't version 102 or 103\n" unless (
		$self->{header}->{VERSION} == 102 || $self->{header}->{VERSION} == 103);
	$self->{ofx} = $self->parse103();
	close $fh;
}

# Parse a version 102 or 103 file
sub parse103
{
	my $self = shift;
	$self->advance();
	return undef unless(defined $self->{tag} && $self->{tag} eq 'OFX');
	$self->OPEN_OFX() if ($self->can('OPEN_OFX'));      # open hook for OFX
	for($self->advance(); $self->{tag} ne '/OFX'; $self->advance())
	{
		my $tag = $self->{tag};
		if (substr($tag,0,1) eq '/')
		{
			$self->CLOSE() if ($self->can('CLOSE'));    # default close hook to catch everything
			my $coderef = $self->can("CLOSE_" . $self->{pos});
			$self->$coderef() if (defined $coderef);    # close hook for this exact position
			my $top = pop @{$self->{stack}};
			$self->die("Closing tag $tag doesn't match top element $top") unless($tag eq "/$top");
			$self->{pos} = join("_",@{$self->{stack}});
		}
		elsif ($self->{val} eq '')
		{
			push @{$self->{stack}},$self->{tag};
			$self->{pos} = join("_",@{$self->{stack}});
			$self->OPEN() if ($self->can('OPEN'));      # default open hook to catch everything
			my $coderef = $self->can("OPEN_" . $self->{pos});
			$self->$coderef() if (defined $coderef);    # open hook for this exact position
		}
		else
		{
			$self->{pos} = $self->{pos} . "_" . $tag;
			$self->VALUE() if ($self->can('VALUE'));    # default value hook to catch everything
			my $coderef = $self->can($self->{pos});
			$self->$coderef() if (defined $coderef);    # value hook for this exact position
			$self->{pos} = join("_",@{$self->{stack}});
			$self->advance() if ($self->peek() eq "/$tag");
		}
	}
	$self->CLOSE_OFX() if ($self->can('CLOSE_OFX'));    # close hook for OFX
}

1;
