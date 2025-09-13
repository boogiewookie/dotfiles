package ComputedValues;
@ISA = qw();

use DBI;
use DbiIni;
use Statistics::Descriptive;

my $pgsql = DbiIni->connect('finance') || die $DBI::errstr;
$pgsql->{HandleError} = sub {
	my ($msg,$dbi,$obj) = @_;
	return ($msg !~ /duplicate key violates unique constraint/ ||
			$msg !~ /duplicate key value violates unique constraint/);
};
$pgsql->{ShowErrorStatement} = 1;

sub new
{
# ComputedValues->new($symbol)
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = {};
	bless $self, $class;
	$self->{symbol} = shift @_;

	$self->{close} = [];
	$self->{pctchg} = [];
	$self->{rowfor} = {};

	my $bars = $pgsql->selectall_arrayref(
		"SELECT juncture,close,COALESCE(pctchg,0.0) as pctchg
         FROM dailybars WHERE symbol = ? AND
                              close IS NOT NULL
         ORDER BY juncture ASC",
        {RaiseError => 1},
        $self->{symbol});

    foreach my $row (@{$bars})
	{
	    my ($juncture,$close,$pctchg) = @{$row};
		$self->{rowfor}->{$juncture} = @{$self->{close}};
		push(@{$self->{close}},$close);
		push(@{$self->{pctchg}},$pctchg);
	}

	return $self;
}

# $cv->asof($juncture,$close)
sub asof
{
	my $self = shift;
	my $juncture = shift;
	my $close = shift;	#optional close

	if (defined($close))
	{
		$self->{rowfor}->{$juncture} = @{$self->{close}};
		push(@{$self->{close}},$close);
		push(@{$self->{pctchg}},undef);
	}

	my $row = $self->{rowfor}->{$juncture};
	return undef unless(defined($row));

	my $result = {'close' => $self->{close}->[$row]};

	# compute the pctchg
	if ($row >= 1)
	{
		my $prevclose = $self->{close}->[$row-1];
		$result->{pctchg} = $self->{pctchg}->[$row] =
			($prevclose == 0) ? 0.0 : ($self->{close}->[$row] - $prevclose) / $prevclose;
	}

	# compute all the 5 bar statistics
	if ($row >= 4)
	{
		my $s = Statistics::Descriptive::Full->new();
		$s->add_data(@{$self->{close}}[$row-4 .. $row]);
		$result->{m5av} = $s->mean();
		$result->{m5sd} = $s->standard_deviation();
		$result->{m5q0} = $s->quantile(0);
		$result->{m5q1} = $s->quantile(1);
		$result->{m5q2} = $s->quantile(2);
		$result->{m5q3} = $s->quantile(3);
		$result->{m5q4} = $s->quantile(4);
	}

	# compute all the 20 bar statistics
	if ($row >= 19)
	{
		my $s = Statistics::Descriptive::Full->new();
		$s->add_data(@{$self->{close}}[$row-19 .. $row]);
		$result->{m20av} = $s->mean();
		$result->{m20sd} = $s->standard_deviation();
		$result->{m20q0} = $s->quantile(0);
		$result->{m20q1} = $s->quantile(1);
		$result->{m20q2} = $s->quantile(2);
		$result->{m20q3} = $s->quantile(3);
		$result->{m20q4} = $s->quantile(4);
	}

	# compute all the 200 bar statistics
	if ($row >= 199)
	{
		my $s = Statistics::Descriptive::Full->new();
		$s->add_data(@{$self->{close}}[$row-199 .. $row]);
		$result->{m200av} = $s->mean();
		$result->{m200sd} = $s->standard_deviation();
		$result->{m200q0} = $s->quantile(0);
		$result->{m200q1} = $s->quantile(1);
		$result->{m200q2} = $s->quantile(2);
		$result->{m200q3} = $s->quantile(3);
		$result->{m200q4} = $s->quantile(4);
	}

	return $result;
}
