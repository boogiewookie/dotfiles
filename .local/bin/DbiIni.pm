package DbiIni;
use Config::Tiny;
use DBI;

my $inifile = $ENV{DATABASEINI} // glob("~/.database.ini");

sub connect {
	my $db = shift @_;
	$db = shift @_ if ($db eq 'DbiIni');
	my $config = Config::Tiny->read($inifile);
	unshift @_, $config->{$db}->{password};
	unshift @_, $config->{$db}->{user};
	unshift @_, "DBI:Pg:database=$db;host=$config->{$db}->{host}";
	return DBI->connect(@_);
}

1;
