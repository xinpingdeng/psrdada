#!/usr/bin/env perl

###############################################################################
#

use lib $ENV{"DADA_ROOT"}."/bin";

use strict;
use warnings;
use Hispec;
use Dada::client_master_control qw(%cfg);

#
# Function prototypes
#
sub setupClientType();


#
# Global Variables
# 
%cfg = Hispec::getConfig();

#
# Initialize module variables
#
$Dada::client_master_control::dl = 1;
$Dada::client_master_control::daemon_name = Dada::daemonBaseName($0);
$Dada::client_master_control::pwc_add = " -d ";

my $client_setup = setupClientType();
if (! $client_setup) 
{
  print "ERROR: Failed to setup client type based on hispec.cfg\n";
  exit(1);
}

# Autoflush STDOUT, making it "hot"
select STDOUT;
$| = 1;

my $result = 0;
$result = Dada::client_master_control->main();

exit($result);


###############################################################################
#
# Funtions


# 
# Determine what type of host we are, and if we have any datablocks
# to monitor
#
sub setupClientType() 
{

  my %roach = Hispec::getROACHConfig();
  my $host = Dada::getHostMachineName();
  my $i = 0;
  my $found = 0;

  @Dada::client_master_control::dbs = ();
  @Dada::client_master_control::pwcs = ();

  # if running on the server machine
  if ($cfg{"SERVER_ALIASES"} =~ m/$host/) {
    $Dada::client_master_control::host = $host;
    $Dada::client_master_control::user = "dada";
    @Dada::client_master_control::daemons = split(/ /,$cfg{"SERVER_DAEMONS"});
    $Dada::client_master_control::daemon_prefix = "server";
    $Dada::client_master_control::control_dir = $cfg{"SERVER_CONTROL_DIR"};
    $Dada::client_master_control::log_dir = $cfg{"SERVER_LOG_DIR"};
    push (@Dada::client_master_control::pwcs, "server");
    $found = 1;
  }
  else
  {
    $Dada::client_master_control::daemon_prefix = "client";
    $Dada::client_master_control::control_dir = $cfg{"CLIENT_CONTROL_DIR"};
    $Dada::client_master_control::log_dir = $cfg{"CLIENT_LOG_DIR"};
    $Dada::client_master_control::user = $cfg{"USER"};

		# Ensure the required directories exist
		my $cmd = "";
		my $dir = "";
		my $result = "";
		my $response = "";
		my @dirs = ($cfg{"CLIENT_LOCAL_DIR"}, $cfg{"CLIENT_CONTROL_DIR"}, $cfg{"CLIENT_LOG_DIR"}, 
							  $cfg{"CLIENT_ARCHIVE_DIR"}, $cfg{"CLIENT_RECORDING_DIR"}, $cfg{"CLIENT_SCRATCH_DIR"});

    for ($i=0; ($i<$cfg{"NUM_PWC"}); $i++)
    {
      if ($host =~ m/$cfg{"PWC_".$i}/)
      {
        my $beam = $roach{"BEAM_".$i};
        push @dirs, $cfg{"CLIENT_ARCHIVE_DIR"}."/".$beam;
      }
    }

		foreach $dir ( @dirs )
		{
			if (! -d $dir)
			{
				$cmd = "mkdir -m 0755 ".$dir;
				($result, $response) = Dada::mySystem($cmd);
				if ($result ne "ok")
				{
					print STDERR "Could not create ".$dir.": ".$response."\n";
					return 0;
				}
			}
		}

    # see how many PWCs are running on this host
    for ($i=0; ($i<$cfg{"NUM_PWC"}); $i++) 
    {
      if ($host =~ m/$cfg{"PWC_".$i}/) 
      {
        # add to list of PWCs on this host
        push (@Dada::client_master_control::pwcs, $i);

        # determine data blocks for this PWC
        my @ids = split(/ /,$cfg{"DATA_BLOCK_IDS"});
        my $key = "";
        my $id = 0;
        foreach $id (@ids) 
        {
          $key = Dada::getDBKey($cfg{"DATA_BLOCK_PREFIX"}, $i, $id);
          # check nbufs and bufsz
          if ((!defined($cfg{"BLOCK_BUFSZ_".$id})) || (!defined($cfg{"BLOCK_NBUFS_".$id}))) {
            return 0;
          }
          $Dada::client_master_control::dbs{$i}{$id} = $key;
        }

        if (!$found) 
        {
          @Dada::client_master_control::daemons = split(/ /,$cfg{"CLIENT_DAEMONS"});
          @Dada::client_master_control::binaries = ();
          push @Dada::client_master_control::binaries, $cfg{"PWC_BINARY"};
          $found = 1;
        }
      }
    }
    
    # If we matched a PWC
    if ($found) 
    {
      $Dada::client_master_control::pwc_add = " -d ";
    }
    else
    {
      @Dada::client_master_control::daemons = ();
      @Dada::client_master_control::dbs = ();
      @Dada::client_master_control::binaries = ();
    }
    $Dada::client_master_control::host = Dada::getHostMachineName();
  }

  return $found;

}

