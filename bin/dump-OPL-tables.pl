#!/usr/bin/env perl

# This script dumps the OPL library tables to a dump file.
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

# Get mysqldump_command

my $mysqldump_command = $ce->{externalPrograms}->{mysqldump};

# The tables to dump are:

my $OPL_tables_to_dump =
	"OPL_DBsubject OPL_DBchapter OPL_DBsection OPL_author OPL_path OPL_pgfile OPL_keyword OPL_pgfile_keyword OPL_textbook OPL_chapter OPL_section OPL_problem OPL_morelt OPL_pgfile_problem";

# Tables NOT dumped:
# OPL_problem_user - is created by bin/update-OPL-statistics and need not be archived
# OPL_global_statistics - loaded from a special file provide by the OPL
# OPL_local_statistics - locally generated

print "Dumping OPL tables\n";

# Conditionally add --column-statistics=0 as MariaDB databases do not support it
# see: https://serverfault.com/questions/912162/mysqldump-throws-unknown-table-column-statistics-in-information-schema-1109
#      https://github.com/drush-ops/drush/issues/4410

my $column_statistics_off      = "";
my $test_for_column_statistics = `$mysqldump_command --help | grep 'column-statistics'`;
if ($test_for_column_statistics) {
	$column_statistics_off = " --column-statistics=0 ";
}

`$mysqldump_command --host=$host --port=$port --user=$dbuser --default-character-set=$character_set $column_statistics_off $db $OPL_tables_to_dump  > $prepared_OPL_tables_file`;

print "OPL database dump created: $prepared_OPL_tables_file\n";

1;
