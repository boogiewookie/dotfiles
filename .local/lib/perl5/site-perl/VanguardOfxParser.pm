#!/usr/bin/env perl
package VanguardOfxParser;
use parent qw{OfxParser};
use Gainometer;
use strict;
use warnings;
no warnings qw{uninitialized};

use Data::Dumper;	#FIXME: debug only

# constructor, as if you didn't know
sub new
{
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = $class->SUPER::new();
	bless $self, $class;
	my $g = Gainometer->new;
	my %acctnumbers = $g->get_acctnumbers;
	$self->{acctid2acctkey} = \%acctnumbers;

	# result variables
	$self->{events} = [];				# all the events found
	$self->{securities} = [];			# all the securities found
	$self->{positions} = [];			# all the positions found
	
	# working variables
	$self->{uniqueid2security} = {};	# find a security from uniqueid
	$self->{uniqueid2position} = {};	# find a position from uniqueid
	$self->{acctkey} = undef;			# the acctkey for this file
	$self->{cash} = undef;				# the cash balance for this file
	$self->{juncture} = undef;			# the "as of" date for this file
	$self->{event} = {};				# the event we're currently accumulating
	$self->{security} = {};				# the security we're currently accumulating
	$self->{position} = {};				# the position we're currently accumulating
	$self->{pos} = undef;				# xpath-like position in the parse tree
	$self->{tag} = undef;				# tag from the current input line
	$self->{val} = undef;				# value, if any, from the current input line
	return $self;
}

#save current position to the uniqueid2position table
sub save_position
{
	my $self = shift;
	my $uniqueid = $self->{position}->{uniqueid};
	if (!defined $self->{uniqueid2position}->{$uniqueid})
	{
		$self->{uniqueid2position}->{$uniqueid} = $self->{position};
	}
	else
	{	#sometimes they have two position entries for the same id, so combine them
		$self->{uniqueid2position}->{$uniqueid}->{mktvalue} += $self->{position}->{mktvalue};
		$self->{uniqueid2position}->{$uniqueid}->{sharebalance} += $self->{position}->{sharebalance};
	}
}

#### Getter methods for use by caller

sub acctkey
{
	my $self = shift;
	return $self->{acctkey};
}

sub asof
{
	my $self = shift;
	return $self->{asof};
}

sub cash
{
	my $self = shift;
	return $self->{cash};
}

sub events
{
	my $self = shift;
	return @{$self->{events}};
}

sub securities
{
	my $self = shift;
	return @{$self->{securities}};
}

sub positions
{
	my $self = shift;
	return values %{$self->{uniqueid2position}};
}

#############

sub SIGNONMSGSRSV1_SONRS_STATUS_MESSAGE
{
	my $self = shift;
	$self->die("Bad signon status: " . $self->{val}) unless ($self->{val} eq "Successful Sign On");
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_STATUS_CODE
{
	my $self = shift;
	$self->die("Bad statement status: " . $self->{val}) unless ($self->{val} eq "0");
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_DTASOF
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{asof} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVACCTFROM_BROKERID
{
	my $self = shift;
	$self->die("Not from vanguard.com " . $self->{val}) unless ($self->{val} eq "vanguard.com");
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVACCTFROM_ACCTID
{
	my $self = shift;
	$self->die("Unknown account id $self->{val}")
		unless (exists $self->{acctid2acctkey}->{$self->{val}});
	$self->{acctkey} = $self->{acctid2acctkey}->{$self->{val}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVBAL_AVAILCASH
{
	my $self = shift;
	$self->{cash} = $self->{val};
}

sub OPEN
{
	my $self = shift;
	if ($self->{pos} =~ /INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_$self->{tag}/ &&
		$self->{tag} !~ /INCOME|REINVEST|BUYOTHER|TRANSFER|BUYDEBT|BUYMF|BUYSTOCK|SELLSTOCK|SELLMF|SELLOPT|BUYOPT|INVBANKTRAN|MARGININTEREST/)
	{
		$self->die("Unhandled INVTRANLIST tag $self->{tag}");
	}

	if ($self->{pos} =~ /INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_$self->{tag}/ &&
		$self->{tag} !~ /POSSTOCK|POSDEBT|POSMF/)
	{
		$self->die("Unhandled INVPOSLIST tag $self->{tag}");
	}

	if ($self->{pos} =~ /SECLISTMSGSRSV1_SECLIST_$self->{tag}/ &&
		$self->{tag} !~ /DEBTINFO|STOCKINFO|MFINFO|OPTINFO/)
	{
		$self->die("Unhandled SECLIST tag $self->{tag}");
	}
}

sub VALUE
{
	my $self = shift;
	$self->die("UNIQUEIDTYPE is  $self->{var} not CUSIP as expected")
		if ($self->{pos} =~ /_UNIQUEIDTYPE$/ && $self->{val} ne 'CUSIP');
}


###### INVTRANLIST

# income transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_INCOME
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_INCOME_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_INCOME_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_INCOME_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_INCOME_INCOMETYPE
{
	my $self = shift;
	$self->{event}->{action} = "RECVINT" if ($self->{val} eq 'INTEREST');
	$self->{event}->{action} = "RECVDIV" if ($self->{val} eq 'DIV');
	$self->{event}->{action} = "RECVLTCG" if ($self->{val} eq 'CGLONG');
	$self->{event}->{action} = "RECVSTCG" if ($self->{val} eq 'CGSHORT');
	$self->die("unknown income type") unless (defined $self->{event}->{action});
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_INCOME_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}


sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_INCOME
{
	my $self = shift;
	push @{$self->{events}},$self->{event};
}

# reinvest transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST_INCOMETYPE
{
	my $self = shift;
	$self->{event}->{action} = "REININT" if ($self->{val} eq 'INTEREST');
	$self->{event}->{action} = "REINDIV" if ($self->{val} eq 'DIV');
	$self->{event}->{action} = "REINLTCG" if ($self->{val} eq 'CGLONG');
	$self->{event}->{action} = "REINSTCG" if ($self->{val} eq 'CGSHORT');
	$self->die("unknown income type") unless (defined $self->{event}->{action});
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}


sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_REINVEST
{
	my $self = shift;
	push @{$self->{events}},$self->{event};
}

# buyother transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER_INVBUY_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER_INVBUY_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER_INVBUY_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER_INVBUY_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER_INVBUY_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER_INVBUY_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER_INVBUY_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}


sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOTHER
{
	my $self = shift;
	# BUYOTHER seems to always be reinvest
	$self->{event}->{action} = 'BUY';
	if ($self->{event}->{memo} =~ /rein/i)
	{
		# search for a prior matching RECV event to determine what we're reinvesting
		for (my $i = scalar @{$self->{events}}-1; $i >= 0; --$i)
		{
			if ($self->{events}->[$i]->{uniqueid} eq $self->{event}->{uniqueid} &&
				$self->{events}->[$i]->{juncture} eq $self->{event}->{juncture} &&
				$self->{events}->[$i]->{money} == -$self->{event}->{money} &&
				$self->{events}->[$i]->{action} =~ /^RECV(.+)/)
			{
				$self->{event}->{action} = 'REIN' . $1;
				last;
			}
		}
	}
	push @{$self->{events}},$self->{event};
}

# transfer transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

#FIXME: unfortunately, schwab reports avgcostbasis and unitprice as zero
#sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_AVGCOSTBASIS
#sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_UNITPRICE

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER_TFERACTION
{
	my $self = shift;
	$self->die("Unknown transfer action '$self->{val}'") unless ($self->{val} =~ /IN|OUT/);
	$self->{event}->{action} = ($self->{val} eq 'IN') ? 'XFERIN' : 'XFEROUT';
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_TRANSFER
{
	my $self = shift;
	push @{$self->{events}},$self->{event};
}

# buydebt transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT
{
	my $self = shift;
	# we zero money and use += so it combines TOTAL and ACCRDINT regardless of ordering
	$self->{event} = {acctkey => $self->{acctkey}, money => 0};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_INVBUY_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_INVBUY_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_INVBUY_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_INVBUY_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_INVBUY_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val}/100;
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_INVBUY_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_INVBUY_TOTAL
{
	my $self = shift;
	# we zero money and use += so it combines TOTAL and ACCRDINT regardless of ordering
	$self->{event}->{money} += $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT_ACCRDINT
{
	my $self = shift;
	# we zero money and use += so it combines TOTAL and ACCRDINT regardless of ordering
	$self->{event}->{money} += $self->{val};
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYDEBT
{
	my $self = shift;
	$self->{event}->{action} = 'BUY';
	push @{$self->{events}},$self->{event};
}

# buymf transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF_INVBUY_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF_INVBUY_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF_INVBUY_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF_INVBUY_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF_INVBUY_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF_INVBUY_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF_INVBUY_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYMF
{
	my $self = shift;
	$self->{event}->{action} = 'BUY';
	push @{$self->{events}},$self->{event};
}

# buystock transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK_INVBUY_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK_INVBUY_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK_INVBUY_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK_INVBUY_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK_INVBUY_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK_INVBUY_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK_INVBUY_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYSTOCK
{
	my $self = shift;
	$self->{event}->{action} = 'BUY';
	push @{$self->{events}},$self->{event};
}

# sellstock transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK_INVSELL_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK_INVSELL_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK_INVSELL_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK_INVSELL_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK_INVSELL_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK_INVSELL_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK_INVSELL_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLSTOCK
{
	my $self = shift;
	$self->{event}->{action} = 'SELL';
	push @{$self->{events}},$self->{event};
}

# sellmf transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF_INVSELL_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF_INVSELL_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF_INVSELL_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF_INVSELL_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF_INVSELL_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF_INVSELL_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF_INVSELL_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLMF
{
	my $self = shift;
	$self->{event}->{action} = 'SELL';
	push @{$self->{events}},$self->{event};
}

# sellopt transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_INVSELL_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_INVSELL_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_INVSELL_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_INVSELL_SECID_UNIQUEID
{
	#NOTE: schwab provides a non-cusip id for options and lies about it being a cusip
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{symbol} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_INVSELL_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_INVSELL_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_INVSELL_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT_OPTSELLTYPE
{
	my $self = shift;
	$self->die("Unexpected optselltype $self->{val}") unless ($self->{val} =~ /SELLTOCLOSE|SELLTOOPEN/);
	$self->{event}->{selltype} = $self->{val};
	$self->{event}->{action} = ($self->{val} eq 'SELLTOOPEN') ? 'SHORT' : 'SELL';
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_SELLOPT
{
	my $self = shift;
	push @{$self->{events}},$self->{event};
}

# buyopt transactions

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT
{
	my $self = shift;
	$self->{event} = {acctkey => $self->{acctkey}, lineno => $self->{lineno}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_INVBUY_INVTRAN_FITID
{
	my $self = shift;
	$self->{event}->{fitid} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_INVBUY_INVTRAN_DTTRADE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{event}->{juncture} = "$y-$m-$d";
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_INVBUY_INVTRAN_MEMO
{
	my $self = shift;
	$self->{event}->{memo} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_INVBUY_SECID_UNIQUEID
{
	my $self = shift;
	$self->{event}->{uniqueid} = $self->{val};
	$self->{event}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_INVBUY_UNITS
{
	my $self = shift;
	$self->{event}->{shares} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_INVBUY_UNITPRICE
{
	my $self = shift;
	$self->{event}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_INVBUY_TOTAL
{
	my $self = shift;
	$self->{event}->{money} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT_OPTBUYTYPE
{
	my $self = shift;
	$self->die("Unexpected optbuytype $self->{val}") unless ($self->{val} =~ /BUYTOCLOSE|BUYTOOPEN/);
	$self->{event}->{buytype} = $self->{val};
	$self->{event}->{action} = ($self->{val} eq 'BUYTOCLOSE') ? 'UNSHORT' : 'BUY';
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVTRANLIST_BUYOPT
{
	my $self = shift;
	push @{$self->{events}},$self->{event};
}

###### INVPOSLIST

# posstock

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSSTOCK
{
	my $self = shift;
	$self->{position} = {acctkey => $self->{acctkey}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSSTOCK_INVPOS_SECID_UNIQUEID
{
	my $self = shift;
	$self->{position}->{uniqueid} = $self->{val};
	$self->{position}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSSTOCK_INVPOS_UNITS
{
	my $self = shift;
	$self->{position}->{sharebalance} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSSTOCK_INVPOS_UNITPRICE
{
	my $self = shift;
	$self->{position}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSSTOCK_INVPOS_DTPRICEASOF
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{position}->{juncture} = "$y-$m-$d";
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSSTOCK
{
	my $self = shift;
	$self->save_position();
}

# posdebt

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSDEBT
{
	my $self = shift;
	$self->{position} = {acctkey => $self->{acctkey}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSDEBT_INVPOS_SECID_UNIQUEID
{
	my $self = shift;
	$self->{position}->{uniqueid} = $self->{val};
	$self->{position}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSDEBT_INVPOS_UNITS
{
	my $self = shift;
	$self->{position}->{sharebalance} = $self->{val}/100;
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSDEBT_INVPOS_UNITPRICE
{
	my $self = shift;
	$self->{position}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSDEBT_INVPOS_MKTVAL
{
	my $self = shift;
	$self->{position}->{mktvalue} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSDEBT_INVPOS_DTPRICEASOF
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{position}->{juncture} = "$y-$m-$d";
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSDEBT
{
	my $self = shift;
	$self->save_position();
}

# posmf

sub OPEN_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSMF
{
	my $self = shift;
	$self->{position} = {acctkey => $self->{acctkey}};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSMF_INVPOS_SECID_UNIQUEID
{
	my $self = shift;
	$self->{position}->{uniqueid} = $self->{val};
	$self->{position}->{cusip} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSMF_INVPOS_UNITS
{
	my $self = shift;
	$self->{position}->{sharebalance} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSMF_INVPOS_UNITPRICE
{
	my $self = shift;
	$self->{position}->{quote} = $self->{val};
}

sub INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSMF_INVPOS_DTPRICEASOF
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{position}->{juncture} = "$y-$m-$d";
}

sub CLOSE_INVSTMTMSGSRSV1_INVSTMTTRNRS_INVSTMTRS_INVPOSLIST_POSMF
{
	my $self = shift;
	$self->save_position();
}

###### SECLIST

# debtinfo

sub OPEN_SECLISTMSGSRSV1_SECLIST_DEBTINFO
{
	my $self = shift;
	$self->{security} = {ofxkind => 'DEBT'};
}

sub SECLISTMSGSRSV1_SECLIST_DEBTINFO_SECINFO_SECID_UNIQUEID
{
	my $self = shift;
	$self->{security}->{uniqueid} = $self->{val};
	$self->{security}->{cusip} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_DEBTINFO_SECINFO_SECNAME
{
	my $self = shift;
	$self->{security}->{name} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_DEBTINFO_SECINFO_TICKER
{
	my $self = shift;
	$self->{security}->{symbol} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_DEBTINFO_DEBTCLASS
{
	my $self = shift;
	$self->die("Unexpected DEBTCLASS $self->{val}")
		unless($self->{val} =~ /CORPORATE|MUNICIPAL|TREASURY|OTHER/);
	$self->{security}->{debtclass} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_DEBTINFO_COUPONRT
{
	my $self = shift;
	$self->{security}->{coupon} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_DEBTINFO_DTMAT
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{security}->{matures} = "$y-$m-$d";
}

sub CLOSE_SECLISTMSGSRSV1_SECLIST_DEBTINFO
{
	my $self = shift;
	push @{$self->{securities}},$self->{security};
}

# stockinfo

sub OPEN_SECLISTMSGSRSV1_SECLIST_STOCKINFO
{
	my $self = shift;
	$self->{security} = {ofxkind => 'STOCK'};
}

sub SECLISTMSGSRSV1_SECLIST_STOCKINFO_SECINFO_SECID_UNIQUEID
{
	my $self = shift;
	$self->{security}->{uniqueid} = $self->{val};
	$self->{security}->{cusip} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_STOCKINFO_SECINFO_SECNAME
{
	my $self = shift;
	$self->{security}->{name} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_STOCKINFO_SECINFO_TICKER
{
	my $self = shift;
	$self->{security}->{symbol} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_STOCKINFO_STOCKTYPE
{
	my $self = shift;
	$self->die("Unexpected STOCKTYPE $self->{val}")
		unless($self->{val} =~ /COMMON|PREFERRED|OTHER/);
	$self->{security}->{stocktype} = $self->{val};
}

sub CLOSE_SECLISTMSGSRSV1_SECLIST_STOCKINFO
{
	my $self = shift;
	push @{$self->{securities}},$self->{security};
}

# mfinfo

sub OPEN_SECLISTMSGSRSV1_SECLIST_MFINFO
{
	my $self = shift;
	$self->{security} = {ofxkind => 'FUND'};
}

sub SECLISTMSGSRSV1_SECLIST_MFINFO_SECINFO_SECID_UNIQUEID
{
	my $self = shift;
	$self->{security}->{uniqueid} = $self->{val};
	$self->{security}->{cusip} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_MFINFO_SECINFO_SECNAME
{
	my $self = shift;
	$self->{security}->{name} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_MFINFO_SECINFO_TICKER
{
	my $self = shift;
	$self->{security}->{symbol} = $self->{val};
}

sub CLOSE_SECLISTMSGSRSV1_SECLIST_MFINFO
{
	my $self = shift;
	push @{$self->{securities}},$self->{security};
}

# optinfo

sub OPEN_SECLISTMSGSRSV1_SECLIST_OPTINFO
{
	my $self = shift;
	$self->{security} = {ofxkind => 'OPTION'};
}

sub SECLISTMSGSRSV1_SECLIST_OPTINFO_SECINFO_SECID_UNIQUEID
{
	my $self = shift;
	#NOTE: schwab provides a non-cusip id for options and lies about it being a cusip
	$self->{security}->{uniqueid} = $self->{val};
	$self->{security}->{symbol} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_OPTINFO_SECINFO_SECNAME
{
	my $self = shift;
	$self->{security}->{name} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_OPTINFO_SECINFO_TICKER
{
	my $self = shift;
	$self->{val} =~ s/\s+//g;	# just remove spaces to get official ticker
	$self->{security}->{ticker} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_OPTINFO_OPTTYPE
{
	my $self = shift;
	$self->die("Unexpected OPTTYPE $self->{val}")
		unless($self->{val} =~ /CALL|PUT/);
	$self->{security}->{opttype} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_OPTINFO_STRIKEPRICE
{
	my $self = shift;
	$self->{security}->{strike} = $self->{val};
}

sub SECLISTMSGSRSV1_SECLIST_OPTINFO_DTEXPIRE
{
	my $self = shift;
	my ($y,$m,$d) = $self->{val} =~ /(\d{4})(\d{2})(\d{2})/;
	$self->{security}->{expires} = "$y-$m-$d";
}

sub CLOSE_SECLISTMSGSRSV1_SECLIST_OPTINFO
{
	my $self = shift;
	push @{$self->{securities}},$self->{security};
}

###### OFX

sub CLOSE_OFX
{
	my $self = shift;
	my $g = Gainometer->new;
	foreach my $s ($self->securities)
	{
		# assure we always have a ticker
		if (!defined $s->{ticker})
		{
			$s->{ticker} = $g->get_ticker('CUSIP',$s->{cusip})
				if (defined $s->{cusip});
			$s->{ticker} = $g->get_ticker('SCHWAB',$s->{symbol})
				if (!defined $s->{ticker} && defined $s->{symbol});
			if (!defined $s->{ticker})
			{
				# it must be a new security
				$s->{ticker} = ($s->{ofxkind} eq 'DEBT') ? $s->{cusip} : $s->{symbol};
			}
		}

		# clean up the names a little and fill in securities table fields you can guess
		$s->{name} =~ s/\s+/ /g;
		$s->{description} = $s->{name};
		if ($s->{ofxkind} eq 'DEBT')
		{
			my $isfdic = ($s->{name} =~ /\bFDIC\b/);
			$s->{kind} = ($s->{name} =~ /\bCD|FDIC\b/) ? 'CD' : 'BOND';
			$s->{name} =~ s{\%.*$}{\%};
			$s->{name} =~ s{XXX\*\*.*$}{\%};
			$s->{name} .= " CD" if ($s->{kind} eq 'CD');
			$s->{name} .= " FDIC" if ($isfdic);
			$s->{name} .= " DUE " . $s->{matures};
		}
		elsif ($s->{ofxkind} eq 'STOCK')
		{
			$s->{kind} = 'STOCK';
			if ($s->{name} =~ /\bETF\b/ || $s->{stocktype} eq 'OTHER')
			{
				$s->{kind} = ($s->{name} =~ /\bADR\b/) ? 'STOCK' : 'ETF';
			}
			$s->{kind} = ($s->{name} =~ /\bETF\b/ || $s->{stocktype} eq 'OTHER') ? 'ETF' : 'STOCK';
			if ($s->{stocktype} eq 'PREFERRED')
			{
				$s->{ticker} =~ s/\W+(PR?)?/pr/;
				$s->{ticker} =~ s/PR/pr/;
			}
		}
		elsif ($s->{ofxkind} eq 'FUND')
		{
			$s->{kind} = 'FUND';
		}
		elsif ($s->{ofxkind} eq 'OPTION')
		{
			$s->{kind} = 'OPT';
			$s->{name} =~ s{\d\d/\d\d/\d\d\d\d}{$s->{expires}};
		}
		else
		{
			die "Can't happen: unexpected ofxkind $s->{ofxkind}\n";
		}

		# assure that it's in the securities table
		$self->die("This isn't happening!") if (!defined $s->{ticker});	#famous last words
		$self->{uniqueid2security}->{$s->{uniqueid}} = $s;
		$g->get_or_add_security($s->{ticker},%{$s});
	}

	@{$self->{events}} = sort {
		$a->{juncture} cmp $b->{juncture};
	} @{$self->{events}};
	foreach my $e ($self->events())
	{
		$self->die("Event is missing uniqueid!",$e) if (!defined $e->{uniqueid});
		my $security = $self->{uniqueid2security}->{$e->{uniqueid}};
		$self->die("Security not found!",$e) if (!defined $security);
		$e->{security} = $security;
		$e->{ticker} = $security->{ticker};
		$self->die("Event is missing ticker!",$e) if (!defined $e->{ticker});
		$e->{has_matured} = 1 if ($e->{juncture} eq $security->{matures});

		$self->die("Event is missing juncture!",$e) if (!defined $e->{juncture});
		$self->die("Event is missing acctkey!",$e) if (!defined $e->{acctkey});
		$self->die("Event is missing ticker!",$e) if (!defined $e->{ticker});
		$self->die("Event is missing action!",$e) if (!defined $e->{action});

		$e->{money} = 0 if (!defined $e->{money});
		$e->{shares} = 0 if (!defined $e->{shares});

		if (!defined $e->{quote})
		{
			$e->{quote} =  $g->get_quote($e->{ticker},$e->{juncture});
			if (!defined $e->{quote})
			{
				if (defined $e->{money} && defined $e->{shares} && $e->{shares} != 0)
				{
					$e->{quote} =  $e->{money} / $e->{shares};
				}
				elsif ($e->{cusip} eq 'FED12Q45Q')
				{
					$e->{quote} = 1;
				}
				else
				{
					die ("Event is missing quote!",$e);
				}
			}
		}
		$self->die("Event is missing money!",$e) if (!defined $e->{money});
		$self->die("Event is missing shares!",$e) if (!defined $e->{shares});
		$self->die("Event is missing quote!",$e) if (!defined $e->{quote});

		$e->{evthash} = $g->get_evthash($e->{juncture},$e->{acctkey},$e->{ticker},$e->{action},$e->{money},$e->{shares});
	}

	foreach my $p ($self->positions())
	{
		my $security = $self->{uniqueid2security}->{$p->{uniqueid}};
		$p->{security} = $security;
		$p->{ticker} = $security->{ticker};
	}
}

1;
