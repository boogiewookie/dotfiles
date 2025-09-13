#!/usr/bin/env perl
# vim: set sw=4 ts=4 expandtab:
package Gainometer;
use v5.10;  #enable state variables
use strict;
use warnings;
no warnings qw{uninitialized};
use DBI;
use DbiIni;

use DBD::Pg;
use Time::Piece;
use Finance::Quote;
use Carp;
use Digest::MD5 qw(md5_hex);
use Data::Dumper;   #FIXME: debug

my %actions;
my %accounts;
my %acctnumbers;
my %categories;
my %contexts;
my %cusips;
my %kinds;
my %tickers;
my %latestquotedate;

BEGIN {
    my $dbh = DbiIni->connect("finance",{'AutoCommit' => 1}) or die $DBI::errstr;
    %actions = %{$dbh->selectall_hashref("SELECT action, is_buy, is_income, is_sell FROM actions", 'action')};
    %acctnumbers = @{$dbh->selectcol_arrayref(
        "SELECT acctnumber, acctkey FROM accounts",{Columns=>[1,2]})};
    %categories = @{$dbh->selectcol_arrayref(
        "SELECT category, 1 AS val FROM categories", { Columns=>[1,2] })};
    %contexts = @{$dbh->selectcol_arrayref(
        "SELECT context, 1 AS val FROM contexts", { Columns=>[1,2] })};
    %cusips = @{$dbh->selectcol_arrayref(
        "SELECT cusip, ticker FROM cusip",{Columns=>[1,2]})};
    %kinds = @{$dbh->selectcol_arrayref(
        "SELECT kind, 1 AS val FROM kinds", { Columns=>[1,2] })};
    %tickers = @{$dbh->selectcol_arrayref(
        "SELECT ticker, 1 AS val FROM securities", { Columns=>[1,2] })};
    %latestquotedate = @{$dbh->selectcol_arrayref(
        "SELECT ticker,max(juncture) FROM events WHERE action = 'QUOTE' GROUP BY ticker", { Columns=>[1,2] })};
    $dbh->disconnect;
}
#
############################## class methods ############################## 

my $epsilon = 0.000001; # the smallest number we won't consider zero

# round number to nearest integer towards zero
sub round
{
    my $x = shift @_;
    my $sign = $x <=> 0.0;
    $x = int(abs($x)+.5);
    return $sign * $x;
}


# get the value below which we consider a number zero
sub epsilon {
    return $epsilon;
}

# divide arg0 by arg1, but return 0 if arg1 is 0
sub safediv {
    return ($_[1] == 0) ? 0 : $_[0] / $_[1];
}

############################## private methods ############################## 

#prepare a statement handle and cache it for future use
# private
sub prep_sth
{
    my $self = shift @_;
    my $sql = shift @_;
    if (!defined($self->{sql}->{$sql}))
    {
        $self->{sql}->{$sql} = $self->{db}->prepare($sql) or die $self->{db}->errstr;
    }
    return $self->{sql}->{$sql};
}

############################## public methods ############################## 

# get a hash of action values
sub get_actions { return %actions; }
 
# get a hash of acctkey values
sub get_acctkeys { return %accounts; }
 
# get a hash of acctnumber values
sub get_acctnumbers { return %acctnumbers; }

# get a hash of category values
sub get_categories { return %categories; }

# get a hash of context values
sub get_contexts { return %contexts; }

# get a hash of cusip values
sub get_cusips { return %cusips; }

# get a hash of kind values
sub get_kinds { return %kinds; }

# get a hash of tickers
sub get_tickers { return %tickers; }

# constructor, as if you didn't know
sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {@_};
    bless $self, $class;
    $self->{AutoCommitStack} = ();
    $self->{db} = DbiIni->connect('finance',
        {'AutoCommit' => 1, 'ShowErrorStatement' => 1}) or die $DBI::errstr;
    $self->{newevt} = undef;
    $self->{quotecache} = {};
    $self->{sql} = {};
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    $self->cleanup_dbi_handles;
}

sub cleanup_dbi_handles {
    my ($self) = @_;
    foreach my $sql (keys %{$self->{sql}}) {
        if ($self->{sql}->{$sql}) {
            $self->{sql}->{$sql}->finish;
            undef $self->{sql}->{$sql};
        }
    }
    if ($self->{db}) {
        $self->{db}->disconnect;
        undef $self->{db};
    }
}

# start a transaction
sub start_transaction
{
    my $self = shift @_;
    my $level = shift @_;
    #NOTE: the AutoCommitStack allows nested calls to start_transaction
    #that won't commit until the stack is empty. Rollback happens right
    #away, however.
    push @{$self->{AutoCommitStack}},$self->{db}->{AutoCommit};
    $self->{db}->{AutoCommit} = 0;
    $self->{db}->do("SET TRANSACTION ISOLATION LEVEL $level") if (defined $level);
}

# commit current transaction
sub commit
{
    my $self = shift @_;
    if (@{$self->{AutoCommitStack}} > 0)
    {
        $self->{db}->commit if (@{$self->{AutoCommitStack}} == 1);
        $self->{db}->{AutoCommit} = pop @{$self->{AutoCommitStack}};
    }
}

# roll back current transaction
sub rollback
{
    my $self = shift @_;
    if (@{$self->{AutoCommitStack}} > 0)
    {
        $self->{db}->rollback;  #NOTE: you must rollback before enabling AutoCommit
        $self->{db}->{AutoCommit} = pop @{$self->{AutoCommitStack}};
    }
}

# set new value for AutoCommit, 0 or 1 please
sub set_AutoCommit
{
    my $self = shift @_;
    $self->{db}->{AutoCommit} = $self->{AutoCommitWas} = shift @_ // 1;
}

# set up to copy into table
sub begin_copy_in
{
    my $self = shift @_;
    my $table = shift @_;
    $self->{db}->do("COPY $table FROM STDIN");
}

# wrap up the active copy_in
sub end_copy_in
{
    my $self = shift @_;
    $self->{db}->pg_putcopyend();
}

# copy a row to the active copy_in table
sub put_copy_in
{
    my $self = shift @_;
    my $row = shift @_;
    $self->{db}->pg_putcopydata($row);
}

# Find a symbol in a given context using the aliases table (or securities), based on a ticker
sub get_symbol
{
    my $self = shift @_;
    my $ticker = shift @_;
    my $context = shift @_;
    croak "need ticker" if ($ticker eq '');
    croak "need valid context" if ($context eq '' || $contexts{$context} eq '');
    # special case NON-aliases table cases
    return $ticker if ($context eq 'SCHWAB');
    if ($context eq 'CUSIP')
    {
        my $sth = $self->prep_sth("SELECT cusip FROM securities WHERE ticker = ?");
        $sth->execute($ticker);
        my ($symbol) = $sth->fetchrow_array;
        return $symbol;
    }
    # special case one that takes much time in recalc
    if ($context eq 'EOD')
    {
        state %eod;
        unless (scalar keys %eod)
        {
            my $sst = $self->prep_sth("SELECT symbol,ticker FROM aliases WHERE context = 'EOD'");
            $sst->execute();
            while (my ($sy,$ti) = $sst->fetchrow_array)
            {
                $eod{$ti} = $sy;
            }
        }
        return $eod{$ticker};
    }
    # do the generic aliases table lookup
    my $sth = $self->prep_sth("SELECT symbol FROM aliases WHERE context = ? AND ticker = ?");
    $sth->execute($context,$ticker);
    my ($symbol) = $sth->fetchrow_array;
    return $symbol;
}

# Find a ticker using the aliases table (or securities), based on a symbol or description
sub get_ticker
{
    my $self = shift @_;
    my $context = shift @_;
    my $symbol = shift @_;
    my $alias = shift @_ || "";
    my $ticker;
    croak "need valid context" if ($context eq '' || $contexts{$context} eq '');
    croak "need symbol or alias" if ($symbol eq '' && $alias eq '');
    # special case NON-aliases table cases
    return $symbol if ($context eq 'SCHWAB' and $alias eq '');
    if ($context eq 'CUSIP' and $alias eq '')
    {
        my $sth = $self->prep_sth("SELECT ticker FROM securities WHERE cusip = ?");
        $sth->execute($symbol);
        ($ticker) = $sth->fetchrow_array;
    }
    # do the generic aliases table lookup
    else
    {
        my $sth = $self->prep_sth("SELECT ticker FROM aliases WHERE context = ? AND (symbol = ? OR alias LIKE ?)");
        $sth->execute($context,$symbol,$alias);
        ($ticker) = $sth->fetchrow_array;
    }
    return (!defined $ticker || $ticker eq "" || $ticker eq "N/A") ? undef : $ticker;
}

# Given a description, return a list of possibly matching securities ordered by likelyhood
sub fuzzy_get_ticker
{
    my $self = shift @_;
    my $alias = shift @_;
    $alias = uc($alias);
    $alias =~ s/'/''/;
    $alias =~ s/%/\\%/;
    $alias =~ s/_/\\_/;
    my @word = split /\s+/,$alias;
    my $sela = $self->prep_sth("SELECT DISTINCT ticker FROM aliases WHERE alias LIKE ? OR symbol LIKE ?");
    my $sels = $self->prep_sth("SELECT DISTINCT ticker FROM securities WHERE name LIKE ? OR ticker LIKE ?");
    my %hitcount;
    foreach my $word (@word)
    {
        $word = "\%$word\%";
        my $incr = length($word) + ($word =~ /\d/); #give more weight to longer words and those with digits
        $sela->execute($word,$word) || confess $sela->errstr;
        while(my $ref = $sela->fetchrow_hashref)
        {
            $hitcount{$ref->{ticker}} += $incr;
        }
        $sels->execute($word,$word) || confess $sels->errstr;
        while(my $ref = $sels->fetchrow_hashref)
        {
            $hitcount{$ref->{ticker}} += $incr;
        }
    }
    my @tickers = sort {$hitcount{$a} <=> $hitcount{$b}} keys %hitcount;
    return reverse grep(@tickers < 5 || $hitcount{$_} > 1,@tickers);
}

# insert an alias
#   insert_alias(ticker,context,symbol)
#   insert_alias(ticker,context,symbol,alias)
sub insert_alias
{
    my $self = shift @_;
    my $ticker = shift @_;
    croak "missing ticker" if ($ticker eq '');
    my $context = shift @_;
    croak "missing context" if ($context eq '');
    my $symbol = shift @_;
    my $alias = shift @_;
    croak "missing both symbol and alias" if ($symbol eq '' && $alias eq '');
    #assure missing values get stored as NULL
    $symbol = undef if (defined($symbol) && $symbol eq '');
    $alias = undef if (defined($alias) && $alias eq '');
    my $sth = $self->prep_sth("INSERT INTO aliases (context,symbol,alias,ticker) VALUES (?,?,?,?) ON CONFLICT (context,symbol) DO UPDATE SET ticker = ?");
    $sth->execute($context,$symbol,$alias,$ticker,$ticker);
}

# Get security given a ticker. Returns a security, possibly empty
sub get_security
{
    my $self = shift @_;
    my $ticker = shift @_;
    croak "missing ticker" if ($ticker eq '');
    my $sth = $self->prep_sth("SELECT sid,ticker,name,kind,category FROM securities WHERE ticker = ?");
    $sth->execute($ticker);
    my $ref = $sth->fetchrow_hashref;
    return ($ref) ? %{$ref} : %{{'ticker' => $ticker}};
}

# Get or add security given a ticker. Also fills in any blanks
# it can when you pass in a prototype security.
sub get_or_add_security
{
    my $self = shift @_;
    my $ticker = shift @_;
    croak "missing ticker" if ($ticker eq '');
    my %security = @_;  #optional initializer
    my $sth = $self->prep_sth("SELECT sid,ticker,name,kind,category,currency,cusip FROM securities WHERE ticker = ?");
    $sth->execute($ticker);
    my $ref = $sth->fetchrow_hashref;
    if ($ref)
    {   # it already exists
        my %row = %{$ref};
        my $update = undef;

        # update database row with any new information
        $update = $row{name} = ($security{name} || $security{description})
            if ($row{name} eq '' and ($security{name} || $security{description}) ne '');
        $update = $row{kind} = $security{kind}
            if ($row{kind} eq '' and $security{kind} ne '');
        $update = $row{category} = $security{category}
            if ($row{category} eq '' and $security{category} ne '');
        $update = $row{cusip} = $security{cusip}
            if ($row{cusip} eq '' and $security{cusip} ne '');
        if (defined $update)
        {
            $sth = $self->prep_sth("UPDATE securities SET (name,kind,category,cusip) = (?,?,?,?) WHERE ticker = ?");
            $sth->execute($row{name},$row{kind},$row{category},$row{cusip},$ticker);
        }

        # update security with data from row
        $security{name} = $row{name} unless($row{name} eq '');
        $security{kind} = $row{kind} unless($row{kind} eq '');
        $security{category} = $row{category} unless($row{category} eq '');
        $security{cusip} = $row{category} unless($row{cusip} eq '');
        $security{added} = 0;
    }
    else
    {   # ok, we need to add it
        my $name = $security{name} || $security{description};
        if ($name eq '')
        {   # attempt to locate the name if we didn't have it
            my $fq = Finance::Quote->new;
            $fq->require_labels(qw{name});
            my %val = $fq->fetch('usa',$ticker);
            $name = $val{$ticker,'name'};
        }
        if ($security{kind} eq '')
        {
            if ($name =~ /[0-9.]+%/ || $name =~ /\bDUE|CD|FDIC|BD|BOND\b/)
            {
                $security{kind} = ($name =~ /\bCD|FDIC\b/) ? 'CD' : 'BOND';
            }
            elsif ($name =~ /\bETF\b/)
            {
                $security{kind} = 'ETF';
            }
            elsif ($name =~ /\bFUND|FD\b/)
            {
                $security{kind} = 'FUND';
            }
            else
            {
                $security{kind} = 'STOCK';
            }
        }
        if ($security{category} eq '')
        {
            if ($security{kind} eq 'CD' or
                $security{kind} eq 'BOND' or
                $name =~ /\bDUE|CD|FDIC|BD|BOND\b/)
            {
                $security{category} = 'FIXED';
            }
            elsif ($security{kind} eq 'SMALL' or $name =~ /\bSMALL(CAP)?\b/)
            {
                $security{category} = 'SMALL';
            }
            elsif ($security{kind} eq 'INTL' or $name =~ /\bINTL\b/)
            {
                $security{category} = 'INTL';
            }
            else
            {
                $security{category} = 'OTHER';
            }
        }
        $security{currency} = $ticker;
        $security{currency} = "C.$ticker" if ($security{kind} eq 'CD');
        $security{currency} = "B.$ticker" if ($security{kind} eq 'BOND');

        $security{added} = 1;
        $security{ticker} = $ticker if ($security{ticker} ne $ticker);
        $sth = $self->prep_sth("INSERT INTO securities (ticker,name,kind,category,currency,cusip) VALUES (?,?,?,?,?,?)");
        $sth->execute($ticker,$name,$security{kind},$security{category},$security{currency},$security{cusip});
}

    return %security;
}

# Return the next private (phony) cusip
#     get_private_cusip()
sub get_private_cusip
{
    my $self = shift @_;
    my $sth = $self->prep_sth("SELECT nextval('private_cusip_seq') AS cusip;");
    $sth->execute();
    my ($cusip) = $sth->fetchrow_array;
    return $cusip;
}

# Return evthash for given event
#     get_evthash(fitid)
#     get_evthash(juncture,acctkey,ticker,action,money,shares)
sub get_evthash
{
    my $self = shift @_;
    if (@_ == 1)    # an arbitrary string like fitid
    {
        return md5_hex(shift @_);
    }
    elsif (@_ >= 6) # juncture,acctkey,ticker,action,money,shares,...
    {
        my ($juncture,$acctkey,$ticker,$action,$money,$shares) = @_[0 .. 5];
        $juncture =~ tr{/}{-};  # assure date uses dash seperators
        my $fitid = sprintf("%8s;%4s;%s;%.2f;%.6f",
                $juncture,$acctkey,$ticker,$money,$shares);
        return md5_hex($fitid);
        # in pgsql it's md5(juncture||';'||acctkey||';'||ticker||';'||money||';'||shares)
    }
    croak "need juncture,acctkey,ticker,action,money,shares";
}

# Return count of evthashes entries for the given evthash
#     count_evthash(evthash)
sub count_evthashes
{
    my $self = shift @_;
    my $evthash = shift @_;
    my $sth = $self->prep_sth("SELECT count(*) FROM evthashes WHERE evthash = ?");
    $sth->execute($evthash);
    my ($n) = $sth->fetchrow_array;
    return $n;
}

# Insert an event into the raw_events table unless it's already there.
#     insert_event(juncture,acctkey,ticker,action,money,shares,quote)
sub insert_event
{
    my $self = shift @_;
    my $evthash = $self->get_evthash(@_);
    my $juncture = shift @_ || croak "need juncture";
    my $acctkey = shift @_ || croak "need acctkey";
    my $ticker = shift @_ || croak "need ticker";
    $ticker = 'cash' if ($ticker eq 'CASH');    #KLUDGE
    my $action = shift @_ || croak "need action";
    my $money = shift @_;
    croak "need money" if (!defined($money));
    my $shares = shift @_;
    croak "need shares" if (!defined($shares));
    my $quote = shift @_;
    croak "need quote" if (!defined($quote));
    #there could be an optional fitid argument
    my $fitid = shift @_;
    my $fitidhash = undef;

    $self->{newevt} = undef; #clear newevt before going any farther
    if (defined $fitid)
    {   # if we've already processed the fitid we're done
        $fitidhash = $self->get_evthash($fitid);
        if ($self->count_evthashes($fitidhash) > 0)
        {
            return 0;
        }
    }

    # if the event already exists, we're done
    if ($self->count_evthashes($evthash) > 0)
    {
        return 0;
    }
    
    # sanity checks
    my $errmsg = "";
    $errmsg .= "; quote is 0" if ($quote == 0);
    $errmsg .= "; money < 0 and shares < 0" if ($money < 0 && $shares < 0 && $action ne 'CASHOUT');
    $errmsg .= "; money < 0 and sell" if ($money < 0 && $actions{$action}->{is_sell} && $action ne 'CASHOUT');
    $errmsg .= "; money > 0 and shares > 0" if ($money > 0 && $shares > 0 && $action ne 'CASHIN');
    $errmsg .= "; money > 0 and buy" if ($money > 0 && $actions{$action}->{is_buy} && $action ne 'CASHIN');
    $errmsg .= "; CASHIN with money != shares" if ($money != $shares && $action eq 'CASHIN');
    $errmsg .= "; CASHOUT with money != shares" if ($money != $shares && $action eq 'CASHOUT');
    $errmsg .= "; buy or sell and shares is 0" if (($actions{$action}->{is_buy} or $actions{$action}->{is_sell}) && $shares == 0 && $action ne 'CASHIN' && $action ne 'CASHOUT');
    $errmsg .= "; money is 0 on a buy" if ($actions{$action}->{is_buy} && $money == 0 && $action ne 'XFERIN');
    warn "    $juncture,$acctkey,$ticker,$action  \$$money,$shares is peculiar$errmsg\n" unless ($errmsg eq '');

    # go ahead and insert the event ...
    my $sth = $self->prep_sth("INSERT INTO raw_events (juncture,acctkey,ticker,action,money,shares,quote) VALUES (?,?,?,?,?,?,?) RETURNING *");
    $sth->execute($juncture,$acctkey,$ticker,$action,$money,$shares,$quote) || warn $sth->errstr;
    $self->{newevt} = $sth->fetchrow_hashref;

    # ... and it that was succesful ...
    if (defined $self->{newevt})
    {
        # ... insert the evthash ...
        $self->insert_evthash($evthash,$self->{newevt}->{eid});

        # ... and the fitidhash, if any
        $self->insert_evthash($fitidhash,$self->{newevt}->{eid}) if (defined $fitidhash && $fitidhash ne $evthash);

        # and the cash, if changing
        if ($money > 0.0 && $action ne 'CASHIN')
        {
            $sth->execute($juncture,$acctkey,'cash','CASHIN',$money,
                $money,1.00) || warn $sth->errstr;
        }
        elsif ($money < 0.0 && $action ne 'CASHOUT')
        {
            $sth->execute($juncture,$acctkey,'cash','CASHOUT',$money,
                $money,1.00) || warn $sth->errstr;
        }
    }
    return $self->{newevt}->{eid};
}

# Insert an evthash,eid pair into the evthashes table
#     insert_evthash(evthash,eid)
sub insert_evthash
{
    my $self = shift @_;
    my $evthash = shift @_;
    my $eid = shift @_;
    my $sth = $self->prep_sth("INSERT INTO evthashes (evthash,eid) VALUES (?,?)");
    $sth->execute(lc($evthash),$eid) || die $sth->errstr;
}

#Get the gain events for a given position
sub get_gain_events
{
    my $self = shift @_;
    my $acctkey = shift @_;
    my $ticker = shift @_;
    my $sth = $self->prep_sth("SELECT *,money-stcapgain-ltcapgain AS salebasis FROM events WHERE acctkey = ? AND ticker = ? AND (stcapgain IS NOT NULL OR ltcapgain IS NOT NULL) ORDER BY juncture,eid");
    $sth->execute($acctkey,$ticker) || confess $sth->errstr;
    my @result;
    while(my $ref = $sth->fetchrow_hashref)
    {
        push @result,$ref;
    }
    return @result;
}

#Get the holdings as of a given date as an array of hash references
sub get_holdings_as_of
{
    my $self = shift @_;
    my $asof = shift @_ // localtime->strftime("%Y-%m-%d");;
    my $sth = $self->prep_sth("SELECT * FROM events WHERE juncture <= ? and sharebalasof <= ? ORDER BY acctkey,ticker,juncture DESC,eid DESC");
    $sth->execute($asof,$asof) || confess $sth->errstr;
    my %seen;
    while(my $ref = $sth->fetchrow_hashref)
    {
        #NOTE: do NOT filter out sharebalance == 0 here or in the SELECT!
        #If you do the caller never sees the final sale and won't balance.
        next if ($asof lt '2021-01-25' && $ref->{acctkey} eq 'ASSO' && $ref->{ticker} eq 'SWISX');  #kludge around xfer of lots from ASIR to ASSO
        my $key = "$ref->{acctkey},$ref->{ticker}";
        $seen{$key} = $ref unless(defined $seen{$key});
    }
    return values %seen;
}

#Get the current positions as an array of hash references.
sub get_positions
{
    my $self = shift @_;
    my $sth = $self->prep_sth("SELECT * FROM positions ORDER BY acctkey,ticker");
    $sth->execute() || confess $sth->errstr;
    my @result;
    while(my $ref = $sth->fetchrow_hashref)
    {
        push @result,$ref;
    }
    return @result;
}

#Get the existing securities as an array of hash references.
sub get_securities
{
    my $self = shift @_;
    my $sth = $self->prep_sth("SELECT * FROM securities ORDER BY ticker");
    $sth->execute() || confess $sth->errstr;
    my @result;
    while(my $ref = $sth->fetchrow_hashref)
    {
        push @result,$ref;
    }
    return @result;
}

#Get the events as an array of hash references.
sub get_events
{
    my $self = shift @_;
    my $acctkey = shift @_; #optional argument defaults to all
    my $ticker = shift @_;  #optional argument defaults to all
    my $sth;
    if (defined $acctkey and defined $ticker)
    {
        $sth = $self->prep_sth(
            "SELECT * FROM events WHERE acctkey = ? AND ticker = ? ORDER BY juncture,eid");
        $sth->execute($acctkey,$ticker) || confess $sth->errstr;
    }
    elsif (defined $acctkey)
    {
        $sth = $self->prep_sth("SELECT * FROM events WHERE acctkey = ? ORDER BY juncture,eid");
        $sth->execute($acctkey) || confess $sth->errstr;
    }
    elsif (defined $ticker)
    {
        $sth = $self->prep_sth("SELECT * FROM events WHERE ticker = ? ORDER BY juncture,eid");
        $sth->execute($ticker) || confess $sth->errstr;
    }
    else
    {
        $sth = $self->prep_sth("SELECT * FROM events ORDER BY juncture,eid");
        $sth->execute() || confess $sth->errstr;
    }
    my @result;
    while(my $ref = $sth->fetchrow_hashref)
    {
        push @result,$ref;
    }
    return @result;
}

#Insert a position from a given event hash
sub insert_position
{
    my $self = shift @_;
    my $evt = shift @_;
    if ($evt->{ticker} ne '' && abs($evt->{sharebalance}) > $epsilon)
    {
        my $inspos = $self->prep_sth("INSERT INTO positions (acctkey, ticker, juncture, eid, quote, paid, sharebalance, mktvalue, basis, unrealizedcapgain, totalvalue, twror, ttm_income, ttm_yield_on_basis, ttm_yield_on_value, name, kind, category, sharebalasof) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);");
        $inspos->execute($evt->{acctkey}, $evt->{ticker}, $evt->{juncture}, $evt->{eid}, $evt->{quote}/100, 10000*$evt->{basis}/$evt->{sharebalance},$evt->{sharebalance}/1000000, $evt->{mktvalue}/100, $evt->{basis}/100, ($evt->{mktvalue}+$evt->{basis})/100, $evt->{totalvalue}/100, 100*$evt->{twror}, $evt->{ttm_income}/100, 100*$evt->{ttm_yield_on_basis}, 100*$evt->{ttm_yield_on_value}, $evt->{name}, $evt->{kind}, $evt->{category}, $evt->{sharebalasof});
    }
}

#Call recalc() to delete and recreate the events and positions tables with running balances
sub recalc
{
    my $self = shift @_;
    #find the date at which income falls within ttm
    my $ttmdate = localtime->add_years(-1);

    # Step through the raw_events in acctkey,ticker,juncture,eid order
    $self->start_transaction();
    my $selpos = $self->prep_sth("SELECT DISTINCT acctkey,ticker FROM raw_events ORDER BY acctkey,ticker");
    my $selevt = $self->prep_sth("SELECT * FROM raw_events JOIN actions USING(action) JOIN securities USING(ticker) WHERE acctkey = ? AND ticker = ? ORDER BY juncture,eid");
    my $insevt = $self->prep_sth("INSERT INTO events (juncture, eid, acctkey, ticker, action, money, shares, quote, stcapgain, ltcapgain, sharebalance, mktvalue, basis, capgain, income, cashreturned, twror, sharebalasof) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);");
    $self->{db}->do("TRUNCATE events;");
    $self->{db}->do("TRUNCATE positions;");

    # for each position (acctkey,ticker pair)
    my $eid = 0;
    my @eventrow;
    $selpos->execute() || confess $selpos->errstr;
    while(my ($acctkey,$ticker) = $selpos->fetchrow_array)
    {
        my @lot;        # list of all lots
        my $ref;
        my $prev = {    # dummy up a null previous event
                acctkey => $acctkey,
                ticker => $ticker,
                sharebalance => 0,
                mktvalue => 0,
                basis => 0,
                capgain => 0,
                income => 0,
                cashreturned => 0,
                ttm_income => 0,
            };

        # for each event in this position
        $selevt->execute($acctkey,$ticker) || confess $selevt->errstr;
        for(my $onward = 1; $onward; $prev = $ref)
        {
            $ref = $selevt->fetchrow_hashref;

            if (!$ref)
            {   # no more events in this position, so generate a QUOTE pseudo-event
                $onward = 0;
                my ($quote,$juncture) = $self->get_quote($ticker);
                last if ($quote eq '');
                $ref->{ticker} = $ticker;
                $ref->{action} = 'QUOTE';
                $ref->{juncture} = $juncture;
                $ref->{eid} = --$eid;
                $ref->{acctkey} = $acctkey;
                $ref->{money} = 0;
                $ref->{shares} = 0;
                $ref->{quote} = $quote;
                $ref->{sid} = $prev->{sid};
                $ref->{name} = $prev->{name};
                $ref->{kind} = $prev->{kind};
                $ref->{category} = $prev->{category};
            }

            # sanity check: quotes are no longer optional, shouldn't be zero
            croak "Missing quote at eid $ref->{eid}!" if (!defined($ref->{quote}));
            carp "Quote at eid $ref->{eid} is zero!" if ($ref->{quote} == 0);

            # sanity check: did you enter a bond as 5000 @ 1.01 instead of 50 @ 101.00
            croak "It looks like you entered a bond in dollars instead of hundreds at eid $ref->{eid}" if ($ref->{quote} >= $epsilon && $ref->{quote} < 10 && $ref->{kind} eq 'BOND');

            # convert values to fixed point; cents for money amounts and microshares for share amounts
            $ref->{money} = round(100*$ref->{money});
            $ref->{shares} = round(1000000*$ref->{shares});
            $ref->{quote} = round(100*$ref->{quote});
            $ref->{twror} /= 100.0;

            # by default carry all running values forward
            $ref->{sharebalance} = $prev->{sharebalance};
            $ref->{mktvalue} = $prev->{mktvalue};
            $ref->{basis} = $prev->{basis};
            $ref->{capgain} = $prev->{capgain};
            $ref->{income} = $prev->{income};
            $ref->{cashreturned} = $prev->{cashreturned};
            $ref->{ttm_income} = $prev->{ttm_income};
            $ref->{sharebalasof} = $prev->{sharebalasof};

            # do some date calculations
            $ref->{date} = Time::Piece->strptime($ref->{juncture},"%Y-%m-%d");

            # update fields that change after a split
            if ($ref->{action} eq 'SPLIT' && $ref->{sharebalance})
            {
                my $ratio = ($ref->{sharebalance} + $ref->{shares}) / $ref->{sharebalance};
                $ref->{sharebalance} += $ref->{shares};
                $ref->{sharebalasof} = $ref->{juncture};
                foreach my $lot (@lot)
                {
                    $lot->{shares} = round($lot->{shares} * $ratio);
                    $lot->{sharesleft} = round($lot->{sharesleft} * $ratio);
                }
            }

            # update or add fields needed for a new lot
            if ($ref->{is_newlot})
            {
                $ref->{basis} += $ref->{money};
                $ref->{basisleft} = $ref->{money};
                $ref->{sharesleft} = $ref->{shares};
                $ref->{ltdate} = Time::Piece->strptime($ref->{juncture},"%Y-%m-%d")->add_years(1);
                $ref->{lotcashreturned} = 0;    # running balance of this lot's income+capgain
                $ref->{lotinitialvalue} = -$ref->{money};
                push @lot,$ref;
            }

            # update fields that change after a buy
            if ($ref->{is_buy})
            {
                $ref->{sharebalance} += $ref->{shares};
                $ref->{sharebalasof} = $ref->{juncture};
            }

            # update fields that change after a sell
            if ($ref->{is_sell})
            {
                $ref->{sharebalance} += $ref->{shares};
                $ref->{sharebalasof} = $ref->{juncture};
            }

            # update fields that change when income is received
            if ($ref->{is_income})
            {
                if ($ref->{action} eq 'RECVSTCG')
                {
                    $ref->{stcapgain} = $ref->{money};
                    $ref->{capgain} += $ref->{money};
                }
                elsif ($ref->{action} eq 'RECVLTCG')
                {
                    $ref->{ltcapgain} = $ref->{money};
                    $ref->{capgain} += $ref->{money};
                }

                # Note that any cap gains recorded here are not from MY selling, but came from
                # a fund as a result of THEIR selling, so I choose to treat them as income and
                # add them to my rate of return calculations.
                $ref->{income} += $ref->{money};
                $ref->{cashreturned} += $ref->{money};
                $ref->{ttm_income} += $ref->{money} if ($ref->{date} >= $ttmdate);
                
                # apportion income to each lot based on its fraction of the sharebalance...
                if ($ref->{sharebalance} != 0)
                {   # ...but only if the position hasn't been sold yet
                    foreach my $lot (@lot)
                    {
                        my $prorata = round($ref->{money}*$lot->{sharesleft}/$ref->{sharebalance});
                        $lot->{lotcashreturned} += $prorata;
                    }
                }
            }

            # reduce lots and recognize gain
            if ($ref->{is_reduce})
            {
                $ref->{cashreturned} += $ref->{money};
                $ref->{stcapgain} = 0;
                $ref->{ltcapgain} = 0;
                my $sharesneeded = $ref->{shares};  #NOTE: <0 if closing a long, >0 if closing a short
                my $exitprice = round(abs($ref->{money}*1000000/$ref->{shares}));# in cents, always >= 0
                my $exitdate = Time::Piece->strptime($ref->{juncture},"%Y-%m-%d");
                for my $lot (@lot)
                {
                    last if ($sharesneeded == 0);
                    next if ($lot->{sharesleft} == 0);
                    my $years = ($ref->{date} - $lot->{date})->years;
                    my $initialvalue = $lot->{basisleft};
                    my $deltashares;
                    my $lotbps = abs($lot->{money}*1000000/$lot->{shares}); # basis of lot in cents per share
                    my $lot_is_st = $exitdate < $lot->{ltdate}; # lot is short term
                    if (($sharesneeded < 0.0 && $lot->{sharesleft} > -$sharesneeded) || #long
                        ($sharesneeded > 0.0 && -$lot->{sharesleft} > $sharesneeded))   #short
                    {   # this lot has more shares than we need
                        $deltashares = $sharesneeded;
                        $lot->{sharesleft} += $deltashares;
                        $lot->{basisleft} = round($lot->{money} * $lot->{sharesleft}/$lot->{shares});
                        $sharesneeded = 0;
                    }
                    else
                    {   # we're consuming this entire lot
                        $deltashares = -$lot->{sharesleft};
                        $lot->{sharesleft} = 0;
                        $lot->{basisleft} = 0;
                        $sharesneeded -= $deltashares;
                    }

                    # When reducing a:
                    #   long, basis < 0, sharebalance > 0, sharesneeded < 0, and deltashares < 0.
                    #   short, basis > 0, sharebalance < 0, sharesneeded > 0, and deltashares > 0.
                    # In either case, lotbps and exitprice are always positive and in cents per
                    # share, and deltashares and sharesneeded have opposite sign to sharebalance.

                    my $gain = round(($exitprice - $lotbps) * -$deltashares / 1000000);
                    $ref->{basis} -= round($deltashares * $lotbps / 1000000);
                    $lot->{lotcashreturned} += round($ref->{money}*$deltashares/$ref->{shares});

                    if ($lot_is_st)
                    {   # short term lot
                        $ref->{stcapgain} += $gain;
                    }
                    else
                    {   # long term lot
                        $ref->{ltcapgain} += $gain;
                    }
                    $ref->{capgain} += $gain;
                }
                $ref->{basis} = 0 if ($ref->{sharebalance} == 0);   # eliminate any roundoff leftovers
                croak "All existing lots are gone and there are $sharesneeded more shares of $ref->{ticker} to close at eid $ref->{eid}" unless($sharesneeded == 0);
            }

            # extract pro rata basis from lots to account for spun off or fractional shares
            if ($ref->{is_dbasis} && $ref->{sharebalance})
            {
                # apportion basis reduction to each lot based on its fraction of the sharebalance
                my $deltabasis = 0;
                foreach my $lot (@lot)
                {
                    my $prorata = round($ref->{money}*$lot->{sharesleft}/$ref->{sharebalance});
                    $lot->{basisleft} += $prorata;
                }
                $ref->{basis} += $ref->{money};
            }

            # update mktvalue only after buys, sells, and splits have been done
            $ref->{mktvalue} = round($ref->{sharebalance} * $ref->{quote} / 1000000);
            $ref->{totalvalue} = $ref->{mktvalue}+$ref->{cashreturned};
            $ref->{ttm_yield_on_basis} = ($ref->{basis} == 0) ?  undef :
                $ref->{ttm_income}/-$ref->{basis};
            $ref->{ttm_yield_on_value} = ($ref->{mktvalue} == 0) ?  undef :
                $ref->{ttm_income}/$ref->{mktvalue};

            # calculate a time weighted rate of return for each lot then average them together weighted by lot value
            print "$ref->{eid} $ref->{juncture}  $ref->{acctkey} $ref->{ticker} $ref->{action} m $ref->{money} s $ref->{shares} q $ref->{quote} tv $ref->{totalvalue}\n" if ($self->{debug}); 
            $ref->{twror} = 0.0;
            if ($ref->{totalvalue} != 0)
            {
                foreach my $lot (@lot)
                {
                    my $lotmktvalue = round($ref->{quote} * ($lot->{sharesleft}/1000000));
                    my $lotvalue = $lotmktvalue + $lot->{lotcashreturned};
                    my $growth = safediv($lotvalue,$lot->{lotinitialvalue});
                    my $years = ($ref->{date} - $lot->{date})->years;
                    my $rplus1 = ($years <= 0.0) ? 1.0 : $growth**(1/$years);
                    $ref->{twror} += $rplus1*safediv($lotvalue,$ref->{totalvalue});
                    printf ("  $lot->{eid} $lot->{juncture} $lot->{sharesleft}: lmv %d + lcr %d => lv %d / liv %d => gr %f ** 1/y %f => r+1 %f\n", $lotmktvalue, $lot->{lotcashreturned}, $lotvalue, $lot->{lotinitialvalue}, $growth, $years, $rplus1) if ($self->{debug});
                }
            }
            $ref->{twror} -= 1.0;
            $ref->{twror} = undef if (abs($ref->{twror}) > 1000);

            print "-----\n" if ($self->{debug});

            push @eventrow, sprintf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                $ref->{juncture},
                $ref->{eid},
                $ref->{acctkey},
                $ref->{ticker},
                $ref->{action},
                (defined $ref->{money}) ? $ref->{money} / 100 : '\N',
                (defined $ref->{shares}) ? $ref->{shares} / 1000000 : '\N',
                (defined $ref->{quote}) ? $ref->{quote} / 100 : '\N',
                (defined $ref->{stcapgain}) ? $ref->{stcapgain} / 100 : '\N',
                (defined $ref->{ltcapgain}) ? $ref->{ltcapgain} / 100 : '\N',
                (defined $ref->{sharebalance}) ? $ref->{sharebalance} / 1000000 : '\N',
                (defined $ref->{mktvalue}) ? $ref->{mktvalue} / 100 : '\N',
                (defined $ref->{basis}) ? $ref->{basis} / 100 : '\N',
                (defined $ref->{capgain}) ? $ref->{capgain} / 100 : '\N',
                (defined $ref->{income}) ? $ref->{income} / 100 : '\N',
                (defined $ref->{cashreturned}) ? $ref->{cashreturned} / 100 : '\N',
                100*$ref->{twror},
                $ref->{sharebalasof});
        }
        $self->insert_position($ref);
        print "=====\n" if ($self->{debug});
    }
    $self->begin_copy_in('events');
    for my $row (@eventrow)
    {
        $self->put_copy_in($row);
    }
    $self->end_copy_in();
    $self->commit();
}

#Get the latest quote available for ticker as of juncture. If called in list context
#returns ($quote,$juncture) so you can see the actual date of the quote.
sub get_quote
{
    my $self = shift @_;
    my $ticker = shift @_;
    my $juncture = shift @_ || localtime->ymd;

    my $key = "$ticker,$juncture";
    if (defined $self->{quotecache}->{$key})
    {
        my $p = $self->{quotecache}->{$key};
        return (wantarray) ? ($p->[0],$p->[1]) : $p->[0];
    }

    # look for the latest quote in dailybars
    my $selbar = $self->prep_sth("SELECT juncture,close FROM dailybars WHERE symbol = ? AND juncture <= ? ORDER BY juncture DESC LIMIT 1");
    my $symbol = $self->get_symbol($ticker,'EOD') || $ticker;
    $selbar->execute($symbol,$juncture) || confess $selbar->errstr;
    my ($jb,$qb) = $selbar->fetchrow_array;

    # look for the latest quote in raw_events
    my $selevt = $self->prep_sth("SELECT juncture,quote FROM raw_events WHERE ticker = ? AND juncture <= ? ORDER BY juncture DESC LIMIT 1");
    $selevt->execute($ticker,$juncture) || confess $selevt->errstr;
    my ($je,$qe) = $selevt->fetchrow_array;
    return undef if ($qb eq '' && $qe eq '');   # can't find a quote anywhere

    # return the latest quote found
    if ($jb gt $je)
    {
        $self->{quotecache}->{$key} = [$qb,$jb];
        return (wantarray) ? ($qb,$jb) : $qb;
    }
    else
    {
        $self->{quotecache}->{$key} = [$qe,$je];
        return (wantarray) ? ($qe,$je) : $qe;
    }
}

#Insert a QUOTE as of a given date if newer than the latest quote
#     set_quote(ticker,quote,juncture)
sub set_quote
{
    my $self = shift @_;
    my $ticker = shift @_;
    my $quote = shift @_;
    my $juncture = shift @_;

    my ($latest_quote,$latest_juncture) = $self->get_quote($ticker);

    if ($juncture gt $latest_juncture)
    {   # insert new quote in every position involving ticker
        my $selkey = $self->prep_sth("SELECT DISTINCT acctkey FROM raw_events WHERE ticker = ?");
        $selkey->execute($ticker) || confess $selkey->errstr;
        while(my ($acctkey) = $selkey->fetchrow_array)
        {
            $self->insert_event($juncture,$acctkey,$ticker,'QUOTE',0,0,$quote);
        }
    }
}

#Get the cash balance for an account. If called in list context
#returns ($money,$juncture) so you can see the date of the balance.
#     get_cash(acctkey)
sub get_cash
{
    my $self = shift @_;
    my $acctkey = shift @_;
    my $selcsh = $self->prep_sth("SELECT money,juncture FROM cash WHERE acctkey = ?");
    $selcsh->execute($acctkey) || confess $selcsh->errstr;
    my ($m,$j) = $selcsh->fetchrow_array;
    confess "Unknown acctkey $acctkey" unless (defined $m);

    # return the latest cash balance
    return (wantarray) ? ($m,$j) : $m;
}

#Update the cash balance for an account
#     set_cash(acctkey,money,juncture)
sub set_cash
{
    my $self = shift @_;
    my $acctkey = shift @_;
    my $money = shift @_;
    my $juncture = shift @_ || localtime->ymd;
    my $updcsh = $self->prep_sth("UPDATE cash SET money = ?, juncture = ? WHERE acctkey = ?");
    $updcsh->execute($money,$juncture,$acctkey) || confess $updcsh->errstr;
}

#Get the split for a multi category ticker
#     get_multicat(ticker)
#     returns hash of percentages keyed by category, totaling 100.00
sub get_multicat
{
    my $self = shift @_;
    my $ticker = shift @_;
    my %pie;
    my $selmul = $self->prep_sth("SELECT category,pct FROM multicat WHERE ticker = ?");
    $selmul->execute($ticker) || confess $selmul->errstr;
    while(my ($category,$pct) = $selmul->fetchrow_array)
    {
        $pie{$category} = $pct;
    }
    return %pie;
}

#Set the split for a multi category ticker; use what you like for the
#values, it'll normalize so the resulting set sums to 100.0
#     set_multicat(ticker, category => value, ...)
sub set_multicat
{
    my $self = shift @_;
    my $ticker = shift @_;
    my %pie = @_;
    $self->start_transaction();
    my $delmul = $self->prep_sth("DELETE FROM multicat WHERE ticker = ?");
    $delmul->execute($ticker) || confess $delmul->errstr;

    my $sum = 0.0;
    map($sum += $_,values %pie);
    if ($sum > 0.0)
    {
        my $insmul = $self->prep_sth("INSERT INTO multicat (ticker,category,pct) VALUES (?,?,?)");
        while(my ($category,$value) = each %pie)
        {
            croak "MULTI doesn't belong in the category split" if ($category eq 'MULTI');
            last unless (defined $category && defined $value);
            my $pct = 100.0*$value/$sum;
            $insmul->execute($ticker,$category,$pct) || confess $insmul->errstr;
        }
    }
    $self->commit();
}

1;
