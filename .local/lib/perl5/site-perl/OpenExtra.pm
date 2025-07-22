#!/usr/bin/env perl
package OpenExtra;
@ISA = qw();

use Carp;
use Date::Manip;
use Fcntl qw(:DEFAULT :flock);
use Data::Dumper;	#FIXME: debug

my @tmp = (	#field names and field formats in output order
	'Name' => '"%s"',
	'Symbol' => '"%s"',
	'Open' => '%.4f',
	'High' => '%.4f',
	'Low' => '%.4f',
	'Close' => '%.4f',
	'Net Chg' => '%.4f',
	'% Chg' => '%.4f',
	'Volume' => '%d',
	'52 Wk High' => '%.4f',
	'52 Wk Low' => '%.4f',
	'Div' => '%.4f',
	'Yield' => '%.4f',
	'P/E' => '%.4f',
	'YTD % Chg' => '%.4f',
);

my @fn;	#field names in output order
my %ff;	#field formats by field name

while(@tmp)
{
	my $fn = shift @tmp;
	push @fn,$fn;
	$ff{$fn} = shift @tmp;
}

sub new
{
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = {};
	bless $self, $class;
	my $d = ParseDate(shift || 'today');
	$self->{date} = UnixDate($d,'%Y-%m-%d');
	$self->{filename} = "/home/dunc/data/eod/extra." .  UnixDate($d,"%Y%m%d") . ".csv";
	$self->{row} = {};
	#schwab closing summary and geteod.extra put rows into the same file so preserve any existing data
	sysopen(my $fh, $self->{filename}, O_RDWR | O_CREAT) || croak "Can't open $self->{filename}";
	flock($fh,LOCK_EX) || croak "Can't lock $self->{filename}";
	<$fh>;
	<$fh>;
	<$fh>;
	<$fh>;
	while(chomp($_ = <$fh>))
	{
		my ($symbol) = /^"[^"]*","([^"]*)"/;
		croak "Missing symbol in $self->{filename}: $_\n" if ($symbol eq '');
		$self->{row}->{$symbol} = $_;
	}
	truncate($fh,0) || croak "Can't truncate $self->{filename}";
	seek($fh,0,SEEK_SET);

	my $date = UnixDate($d,'%A, %B %d, %Y'); #Friday, August 26, 2011
	print $fh qq{EXTRA closing data\n};
	print $fh qq{"$date 5:55 PM"\n};
	print $fh qq{\n};
	print $fh join(',',@fn),"\n";

	$self->{fh} = $fh;
	return $self;
}

sub printrow
{
	my $self = shift;
	my %field = @_;
	croak "missing symbol in printrow" if (
			$field{Symbol} eq '' ||
			$field{Symbol} eq '...' ||
			$field{Symbol} eq '""');
	my @out;
	foreach my $fn (@fn)
	{
		if (defined $field{$fn})
		{
			push @out,sprintf($ff{$fn},$field{$fn});
		}
		else
		{
			push @out,($ff{$fn} eq '"%s"') ? '""' : '...';
		}
	}
	$self->{row}->{$field{Symbol}} = join(',',@out);
}

sub close
{
	my $self = shift;
	my $fh = $self->{fh};
	foreach my $symbol (sort keys %{$self->{row}})
	{
		print $fh $self->{row}->{$symbol},"\n";
	}
	close($fh);
}

# return filename
sub filename
{
	my $self = shift;
	return $self->{filename};
}

# return date of file's data
sub date
{
	my $self = shift;
	return $self->{date};
}

1;
