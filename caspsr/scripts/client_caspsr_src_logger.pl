#!/usr/bin/env perl

use lib $ENV{"DADA_ROOT"}."/bin";

use strict;
use warnings;
use Caspsr;
use Dada::client_logger qw(%cfg);


#
# Function Prototypes
#
sub usage();

#
# Global Variable Declarations
#
%cfg = Caspsr::getConfig();

#
# Initialize module variables
#
$Dada::client_logger::dl = 1;
$Dada::client_logger::log_host = $cfg{"SERVER_HOST"};
$Dada::client_logger::log_port = $cfg{"SERVER_SYS_LOG_PORT"};
$Dada::client_logger::log_sock = 0;
$Dada::client_logger::daemon_name = Dada::daemonBaseName($0);
$Dada::client_logger::type = "src";
$Dada::client_logger::daemon = "proc";
$Dada::client_logger::pwc_id = Dada::getHostMachineName();

if ($#ARGV != 0)
{
  usage();
  exit(1);
}

$Dada::client_logger::daemon = $ARGV[0];
if ($Dada::client_logger::daemon =~ m/demux/)
{
  $Dada::client_logger::log_port = $cfg{"SERVER_DEMUX_LOG_PORT"};
}


# Autoflush STDOUT and STDERR
my $ofh = select STDOUT;
$| = 1;
select STDERR;
$| = 1;
select $ofh;

my $result = 0;
$result = Dada::client_logger->main();

exit($result);

########################################
#
#
sub usage()
{
  print STDERR "Usage: ".Dada::daemonBaseName($0)." daemon\n";
  print STDERR "   daemon    short name of program generating output\n";
}
