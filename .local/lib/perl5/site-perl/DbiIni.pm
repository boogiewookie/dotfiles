package DbiIni;
use Carp;
use Config::Tiny;
use DBI;
use Scalar::Util 'refaddr';

my $trace = defined($ENV{DBI_TRACE});
my $inifile = $ENV{'DATABASEINI'} // glob("~/.database.ini");
Carp::cluck("    ## DbiIni reading $inifile\n") if $trace;

my %handle;

sub connect {
    my $db = shift @_;
    $db = shift @_ if ($db eq 'DbiIni');
    my $config = Config::Tiny->read($inifile);
    unshift @_, $config->{$db}->{password};
    unshift @_, $config->{$db}->{user};
    unshift @_, "DBI:Pg:database=$db;host=$config->{$db}->{host}";
    my $dbh = DBI->connect(@_);
    $handle{ refaddr($dbh) } = $dbh;
    Carp::cluck("    ## DbiIni::connect($db) = $dbh\n") if $trace;
    return $dbh;
}

sub disconnect_all {
    foreach my $key (keys %handle) {
        my $dbh = delete $handle{$key};
        $dbh->disconnect if $dbh;
    }
}

END {
    disconnect_all();
}

1;
