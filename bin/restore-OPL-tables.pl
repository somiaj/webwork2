#!/usr/bin/env perl

# This script restores the OPL library tables from a dump file.
use strict;

# Get the necessary packages, including adding webwork to our path.

BEGIN {
	use Mojo::File qw(curfile);
	use Env        qw(WEBWORK_ROOT);

	$WEBWORK_ROOT = curfile->dirname->dirname;
}

use lib "$ENV{WEBWORK_ROOT}/lib";

use WeBWorK::CourseEnvironment;

use String::ShellQuote;
use DBI;

# get course environment and configured OPL path

my $ce = WeBWorK::CourseEnvironment->new({ webwork_dir => $ENV{WEBWORK_ROOT} });

my $configured_OPL_path = $ce->{problemLibrary}{root};

# Drop the "OpenProblemLibrary" from the end of the path

$configured_OPL_path =~ s+OpenProblemLibrary++;

# Check that it exists

if (-d "$configured_OPL_path") {
	print "OPL path seems to be $configured_OPL_path\n";
} else {
	print "OPL path seems to be misconfigured as $configured_OPL_path which does not exist.\n";
	exit;
}

# Set TABLE-DUMP path and make directory if necessary

my $prepared_OPL_tables_dir = "${configured_OPL_path}/TABLE-DUMP";
if (!-d "$prepared_OPL_tables_dir") {
	`mkdir -p $prepared_OPL_tables_dir`;
}

# Set dump file name

my $prepared_OPL_tables_file = "$prepared_OPL_tables_dir/OPL-tables.sql";

# Get DB connection settings

my $db     = $ce->{database_name};
my $host   = $ce->{database_host};
my $port   = $ce->{database_port};
my $dbuser = $ce->{database_username};
my $dbpass = $ce->{database_password};

$dbuser = shell_quote($dbuser);
$db     = shell_quote($db);

$ENV{'MYSQL_PWD'} = $dbpass;

# decide whether the mysql installation can handle
# utf8mb4 and that should be used for the OPL

my $ENABLE_UTF8MB4 = $ce->{ENABLE_UTF8MB4} ? 1 : 0;

my $character_set = ($ENABLE_UTF8MB4) ? "utf8mb4" : "utf8";

my $mysql_command = $ce->{externalPrograms}->{mysql};

# check to see if the prepared_OPL_tables_file exists and if it does load it in

if (-e $prepared_OPL_tables_file) {
	`$mysql_command --host=$host --port=$port --user=$dbuser --default-character-set=$character_set $db < $prepared_OPL_tables_file`;
}

1;
