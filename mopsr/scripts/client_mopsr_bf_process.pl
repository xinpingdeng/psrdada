#!/usr/bin/env perl

##############################################################################
#  
#     Copyright (C) 2013 by Andrew Jameson
#     Licensed under the Academic Free License version 2.1
# 
###############################################################################
#
# client_mopsr_bf_mux_recv.pl 
#
# process a single channel of TS data
# 
###############################################################################

use lib $ENV{"DADA_ROOT"}."/bin";

use IO::Socket;
use Getopt::Std;
use File::Basename;
use Mopsr;
use strict;
use threads;
use threads::shared;


sub usage() 
{
  print "Usage: ".basename($0)." CHAN_ID\n";
}

#
# Global Variables
#
our $dl : shared;
our $quit_daemon : shared;
our $daemon_name : shared;
our %cfg : shared;
our %ct : shared;
our $localhost : shared;
our $chan_id : shared;
our $db_key : shared;
our $log_host;
our $sys_log_port;
our $src_log_port;
our $sys_log_sock;
our $src_log_sock;
our $sys_log_file;
our $src_log_file;

#
# Initialize globals
#
$dl = 1;
$quit_daemon = 0;
$daemon_name = Dada::daemonBaseName($0);
%cfg = Mopsr::getConfig("bf");
%ct = Mopsr::getCornerturnConfig("bp");   # read the BP cornerturn
$chan_id = -1;
$db_key = "dada";
$localhost = Dada::getHostMachineName(); 
$log_host = $cfg{"SERVER_HOST"};
$sys_log_port = $cfg{"SERVER_BF_SYS_LOG_PORT"};
$src_log_port = $cfg{"SERVER_BF_SRC_LOG_PORT"};
$sys_log_sock = 0;
$src_log_sock = 0;
$sys_log_file = "";
$src_log_file = "";


# Check command line argument
if ($#ARGV != 0)
{
  usage();
  exit(1);
}

$chan_id  = $ARGV[0];

# ensure that our chan_id is valid 
if (($chan_id >= 0) &&  ($chan_id < $cfg{"NCHAN"}))
{
  # and matches configured hostname
  if ($cfg{"RECV_".$chan_id} ne Dada::getHostMachineName())
  {
    print STDERR "RECV_".$chan_id." did not match configured hostname [".Dada::getHostMachineName()."]\n";
    usage();
    exit(1);
  }
}
else
{
  print STDERR "chan_id was not a valid integer between 0 and ".($cfg{"NCHAN"}-1)."\n";
  usage();
  exit(1);
}

#
# Sanity check to prevent multiple copies of this daemon running
#
Dada::preventDuplicateDaemon(basename($0)." ".$chan_id);

###############################################################################
#
# Main
#
{
  # Register signal handlers
  $SIG{INT} = \&sigHandle;
  $SIG{TERM} = \&sigHandle;
  $SIG{PIPE} = \&sigPipeHandle;

  $sys_log_file = $cfg{"CLIENT_LOG_DIR"}."/".$daemon_name."_".$chan_id.".log";
  $src_log_file = $cfg{"CLIENT_LOG_DIR"}."/".$daemon_name."_".$chan_id.".src.log";
  my $pid_file =  $cfg{"CLIENT_CONTROL_DIR"}."/".$daemon_name."_".$chan_id.".pid";

  # this is data stream we will be reading from
  $db_key = Dada::getDBKey($cfg{"DATA_BLOCK_PREFIX"}, $chan_id, $cfg{"NUM_BF"}, $cfg{"PROCESSING_DATA_BLOCK"});

  # Autoflush STDOUT
  $| = 1;

  # become a daemon
  Dada::daemonize($sys_log_file, $pid_file);

  # Open a connection to the server_sys_monitor.pl script
  $sys_log_sock = Dada::nexusLogOpen($log_host, $sys_log_port);
  if (!$sys_log_sock) {
    print STDERR "Could open sys log port: ".$log_host.":".$sys_log_port."\n";
  }

  $src_log_sock = Dada::nexusLogOpen($log_host, $src_log_port);
  if (!$src_log_sock) {
    print STDERR "Could open src log port: ".$log_host.":".$src_log_port."\n";
  }

  msg (0, "INFO", "STARTING SCRIPT");

  my $control_thread = threads->new(\&controlThread, $pid_file);

  my ($cmd, $result, $response, $raw_header, $full_cmd, $proc_cmd_file);
  my ($proc_cmd, $proc_dir, $chan_dir, $tracking);

  $chan_dir  = "CH".sprintf("%02d", $chan_id);

  # continuously run mopsr_dbib for this PWC
  while (!$quit_daemon)
  {
    $cmd = "dada_header -k ".$db_key;
    msg(2, "INFO", "main: ".$cmd);
    $raw_header = `$cmd 2>&1`;
    msg(2, "INFO", "main: ".$cmd." returned");

    if ($? != 0)
    {
      if ($quit_daemon)
      {
        msg(2, "INFO", "dada_header failed, but quit_daemon true");
      }
      else
      {
        msg(0, "ERROR", "dada_header failed: ".$raw_header);
        $quit_daemon = 1;
      }
    }
    else
    {
      my %header = Dada::headerToHash($raw_header);
      msg (2, "INFO", "UTC_START=".$header{"UTC_START"}." NCHAN=".$header{"NCHAN"}." NANT=".$header{"NANT"});

      # Add the dada header file to the proc_cmd
      $proc_cmd_file = $cfg{"CONFIG_DIR"}."/".$header{"BF_PROC_FILE"};

      # tracking is the default
      $tracking = 1;
      if ($header{"OBSERVING_TYPE"} ne "TRACKING") 
      {
        $tracking = 0;
      } 

      msg(2, "INFO", "Full path to BF_PROC_FILE: ".$proc_cmd_file);
      if ( ! ( -f $proc_cmd_file ) ) 
      {
        msg(0, "ERROR", "BF_PROC_FILE did not exist: ".$proc_cmd_file);
        $proc_cmd = "dada_dbnull -z -s -k ".$db_key;
      }
      elsif ($cfg{"BF_STATE_".$chan_id} eq "active")
      {
        my %proc_cmd_hash = Dada::readCFGFile($proc_cmd_file);
        $proc_cmd = $proc_cmd_hash{"PROC_CMD"};
      }   
      else
      {
        msg(0, "INFO", "BF_STATE_".$chan_id." == ".$cfg{"BF_STATE_".$chan_id});
        $proc_cmd = "dada_dbnull -z -s -k ".$db_key;
        msg(1, "INFO", "PROC_CMD=".$proc_cmd);
      }

      # create a local directory for the output from this channel
      #my $remote_dirs_thread = 0;
      ($result, $response) = createLocalDirs(\%header);
      if ($result ne "ok")
      {
        msg(0, "ERROR", "could not create local dir for chan_id=".$chan_id.": ".$response);
        $proc_cmd = "dada_dbnull -z -s -k ".$db_key;
        $proc_dir = "/";
      }
      else
      {
        $proc_dir = $response;
        my $obs_header = $proc_dir."/obs.header";

        #$remote_dirs_thread = threads->new(\&createRemoteDirs,$header{"UTC_START"}, $chan_dir, $obs_header);
        #($result, $response) = createRemoteDirs ($header{"UTC_START"}, $chan_dir, $obs_header);
      }

      # replace the SHM key with db_key
      $proc_cmd =~ s/<DADA_KEY>/$db_key/;

      $proc_cmd =~ s/<IN_DADA_KEY>/$db_key/;

      # replace <DADA_RAW_DATA> tag with processing dir
      $proc_cmd =~ s/<DADA_DATA_PATH>/$proc_dir/;

      # replace DADA_UTC_START with actual UTC_START
      $proc_cmd =~ s/<DADA_UTC_START>/$header{"UTC_START"}/;

      # replace DADA_GPU_ID with actual GPU_ID 
      $proc_cmd =~ s/<DADA_GPU_ID>/$cfg{"BF_GPU_ID_".$chan_id}/;

      # replace DADA_GPU_ID with actual GPU_ID 
      $proc_cmd =~ s/<DADA_CORE>/$cfg{"BF_CORE_".$chan_id}/;

      # replace DADA_CH_ID with chan_dir
      $proc_cmd =~ s/<DADA_CH_ID>/$chan_dir/;

      # replace MOPSR_BF_NBEAMS with cfg{NBEAM}
      $proc_cmd =~ s/<MOPSR_BF_NBEAMS>/$ct{"NBEAM"}/;

      my @best_mods = split(/,/,$header{"RANKED_MODULES"});
      my $i = 0;
      my $primary_ants = "";
      for ($i=0; $i<=$#best_mods; $i++)
      {
        if ($best_mods[$i] >= 0)
        {
          $primary_ants .= " -p ".$best_mods[$i];
        }
      }

      # replace MOPSR_PRIMARY_ANTS with the top ranked 8 antennas for this configuration
      $proc_cmd =~ s/<MOPSR_PRIMARY_ANTS>/$primary_ants/;

      # replace <DADA_INFO> tags with the matching input .info file
      if ($proc_cmd =~ m/<DADA_INFO>/)
      {
        my $tmp_info_file =  "/tmp/mopsr_".$db_key.".info";
        # ensure a file exists with the write processing key
        if (! -f $tmp_info_file)
        {
          open FH, ">".$tmp_info_file;
          print FH "DADA INFO:\n";
          print FH "key ".$db_key."\n";
          close FH;
        }
        $proc_cmd =~ s/<DADA_INFO>/$tmp_info_file/;
      }

      my ($binary, $junk) = split(/ /,$proc_cmd, 2);
      $cmd = "ls -l ".$cfg{"SCRIPTS_DIR"}."/".$binary;
      ($result, $response) = Dada::mySystem($cmd);
      msg(2, "INFO", "main: ".$cmd.": ".$result." ".$response);

      # if the processing is a calibration, then additionally dump the antenna configuration
      # mapping used in memory to the file also
      #if (($binary eq "mopsr_dbcalib") || ($binary eq "mopsr_dbcorr"))
      #{
      #  ($result, $response) = dumpAntennaMapping ($tracking, $proc_dir."/obs.antenna", $proc_dir."/obs.baselines", $proc_dir."/obs.refant");
      #  if ($result ne "ok")
      #  {
      #    msg(1, "WARN", "failed to dump Antenna Mapping to ".$proc_dir.": ".$response);
      #  }
      #}

      if ($binary eq "dspsr")
      {
        $proc_cmd = "export T2USER=".$cfg{"USER"}.$chan_id."; ".$proc_cmd;

        # need to ensure that the sub-integration length is at least twice the 
        # folding period
        $cmd = "psrcat -x -all -c P0 ".$header{"SOURCE"}." | awk '{print \$1}'";
        ($result, $response) = Dada::mySystem($cmd);
        msg(2, "INFO", "main: ".$cmd.": ".$result." ".$response);
      }

      $cmd = "cd ".$proc_dir."; ".$proc_cmd;
      msg(1, "INFO", "START ".$proc_cmd);
      ($result, $response) = Dada::mySystemPiped($cmd, $src_log_file, $src_log_sock, "src", sprintf("%02d",$chan_id), $daemon_name, "proc");
      msg(1, "INFO", "END   ".$proc_cmd);
      if ($result ne "ok")
      {
        $quit_daemon = 1;
        if ($result ne "ok")
        {
          msg(0, "ERROR", $cmd." failed: ".$response);
        }
      }

      #msg(2, "INFO", "joining remote_dirs thread");
      #$remote_dirs_thread->join();
    }
  }

  # Rejoin our daemon control thread
  msg(2, "INFO", "joining control thread");
  $control_thread->join();

  msg(0, "INFO", "STOPPING SCRIPT");

  # Close the nexus logging connection
  Dada::nexusLogClose($sys_log_sock);

  exit (0);
}

#
# Create the local directories required for this observation
#
sub createLocalDirs(\%)
{
  my ($h_ref) = @_;

  msg(2, "INFO", "createLocalDirs()");

  my %h = %$h_ref;
  my $utc_start = $h{"UTC_START"};
  my $chan_dir  = "CH".sprintf("%02d", $chan_id);
  my $dir   = $cfg{"CLIENT_RESULTS_DIR"}."/".$chan_dir."/".$utc_start;

  my ($cmd, $result, $response);

  msg(2, "INFO", "createLocalDirs: mkdirRecursive(".$dir.", 0755)");
  ($result, $response) = Dada::mkdirRecursive($dir, 0755);
  msg(3, "INFO", "createLocalDirs: ".$result." ".$response);
  if ($result ne "ok")
  {
    return ("fail", "Could not create local dir: ".$response);
  }

  # create an obs.header file in the processing dir:
  msg(2, "INFO", "createLocalDirs: creating obs.header");
  my $file = $dir."/obs.header";
  open(FH,">".$file.".tmp");
  my $k = "";
  foreach $k ( keys %h)
  {
    print FH Dada::headerFormat($k, $h{$k})."\n";
  }
  close FH;
  rename($file.".tmp", $file);

  return ("ok", $dir);
}


#
# some custom sorting routines
#
sub intsort
{
  if ((int $a) < (int $b))
  {
    return -1;
  }
  elsif ((int $a) > (int $b))
  {
    return 1;
  }
  else
  {
    return 0;
  }
}

sub modsort
{
  my $mod_a = $a;
  my $mod_b = $b;

  $mod_a =~ s/-B/-0/;
  $mod_a =~ s/-G/-1/;
  $mod_a =~ s/-Y/-2/;
  $mod_a =~ s/-R/-3/;
  $mod_b =~ s/-B/-0/;
  $mod_b =~ s/-G/-1/;
  $mod_b =~ s/-Y/-2/;
  $mod_b =~ s/-R/-3/;

  return $mod_a cmp $mod_b;
}

#
# Dumps the antenna mapping for this observation
#
sub dumpAntennaMapping($$$$)
{
  my ($tracking, $antennas_file, $baselines_file, $refant_file) = @_;
 
  my $ct_file = $cfg{"CONFIG_DIR"}."/mopsr_cornerturn.cfg";
  my $sp_file = $cfg{"CONFIG_DIR"}."/mopsr_signal_paths.txt";
  my $mo_file = $cfg{"CONFIG_DIR"}."/molonglo_modules.txt";
  my $ba_file = $cfg{"CONFIG_DIR"}."/molonglo_bays.txt";
  
  my %ct = Dada::readCFGFileIntoHash($ct_file, 0);
  my %sp = Dada::readCFGFileIntoHash($sp_file, 1);
  my %mo = Dada::readCFGFileIntoHash($mo_file, 1);
  my %ba = Dada::readCFGFileIntoHash($ba_file, 1);
  my %aq_cfg = Mopsr::getConfig("aq");

  my @sp_keys_sorted = sort modsort keys %sp;

  # now generate the listing of antennas the correct ordering
  my ($i, $send_id, $first_ant, $last_ant, $pfb_id, $imod, $rx);
  my ($pfb, $pfb_input, $bay_id);
  my %pfb_mods = ();
  my @mods = ();
  for ($i=0; $i<$aq_cfg{"NUM_PWC"}; $i++)
  {
    msg(1, $dl, "dumpAntennaMapping: i=".$i);
    # if this PWC is an active or passive
    if ($aq_cfg{"PWC_STATE_".$i} ne "inactive")
    {
      $send_id = $aq_cfg{"PWC_SEND_ID_".$i};

      # this is the mapping in RAM for the input to the calibration code
      $first_ant = $cfg{"ANT_FIRST_SEND_".$send_id};
      $last_ant  = $cfg{"ANT_LAST_SEND_".$send_id};

      # now find the physics antennnas for this PFB
      $pfb_id  = $aq_cfg{"PWC_PFB_ID_".$i};

      msg(1, $dl, "dumpAntennaMapping: pfb_id=".$pfb_id." ants=".$first_ant."->".$last_ant);

      $imod = $first_ant;
      %pfb_mods = ();
      foreach $rx ( @sp_keys_sorted )
      {
        ($pfb, $pfb_input) = split(/ /, $sp{$rx});
        msg(3, $dl, "dumpAntennaMapping: pfb=".$pfb." pfb_input=".$pfb_input);
        if ($pfb eq $pfb_id)
        {
          $pfb_mods{$pfb_input} = $rx;
          msg(1, $dl, "dumpAntennaMapping: pfb_mods{".$pfb_input."}=".$rx);
        }
      }

      foreach $pfb_input ( sort intsort keys %pfb_mods )
      {
        msg(1, $dl, "dumpAntennaMapping: pfb_input=".$pfb_input." imod=".$imod." first_ant=".$first_ant." last_ant=".$last_ant);
        if (($imod >= $first_ant) && ($imod <= $last_ant))
        {
          $mods[$imod] = $pfb_mods{$pfb_input};
          $imod++;
        }
        #else
        #{
        #  return ("fail", "failed to identify modules correctly on pfb_input=".$pfb_input);
        #}
      }
    }
  }
  
  open(FHA,">".$antennas_file) or return ("fail", "could not open antennas file for writing");
  open(FHB,">".$baselines_file) or return ("fail", "could not open baselines file for writing");
  open(FHC,">".$refant_file) or return ("fail", "could not open reference antenna file for writing");

  # ants should contain a listing of the antenna orderings
  my ($mod_id, $dist, $delay, $scale, $jmod);
  my $ref_mod = -1;
  my $ref_dist = 0;

  # determine the reference module/antenna
  for ($imod=0; $imod<=$#mods; $imod++)
  {
    if ($ref_mod == -1)
    {
      if ($mods[$imod] =~ m/W25/)
      {
        print FHC $mods[$imod]."\n";
        $ref_mod = $imod;
      }
    }
  }
  if ($ref_mod == -1)
  {
    print FHC $mods[0]."\n";
    $ref_mod = 0;
  }
  close FHC;

  # distance to the reference module is dependant on tracking / transiting
  if ($tracking)
  {
    # get the bay name
    $bay_id = substr($mods[$ref_mod],0,3);
    $ref_dist = $ba{$bay_id};
  }
  else
  {
    ($ref_dist, $delay, $scale) = split(/ /,$mo{$ref_mod},3);
  }

  for ($imod=0; $imod<=$#mods; $imod++)
  {
    $mod_id = $mods[$imod];
    $bay_id = substr($mod_id,0,3);
    if ($tracking)
    {
      $dist = $ba{$bay_id};
    }
    else
    {
      ($dist, $delay, $scale) = split(/ /,$mo{$mod_id},3);
    }
    
    # $dist -= $ref_dist;

    msg(2, "INFO", "imod=".$imod." ".$mod_id.": dist=".$dist." delay=".$delay." scale=".$scale);
    print FHA $mod_id." ".$dist." ".$delay."\n";
  
    for ($jmod=$imod+1; $jmod<=$#mods; $jmod++)
    {
      msg(2, "INFO", $mods[$imod]." ".$mods[$jmod]);
      print FHB $mods[$imod]." ".$mods[$jmod]."\n";
    }
  }

  close(FHA);
  close(FHB);

  return ("ok", "");
}

#
# Thread to create remote NFS links on the server
#
sub createRemoteDirs($$$)
{
  my ($utc_start, $ch_id, $obs_header) = @_;

  msg(2, "INFO", "createRemoteDirs(".$utc_start.", ".$ch_id.", ".$obs_header.")");

  my $user = $cfg{"USER"};
  my $host = $cfg{"SERVER_HOST"};
  my $remote_dir = $cfg{"SERVER_RESULTS_DIR"}."/".$utc_start."/".$ch_id;
  my $cmd = "mkdir -m 2755 -p ".$remote_dir;

  my $result = "";
  my $response = "";
  my $rval = 0;

  my $attempts_left = 5;
  my $use_nfs = 0;

  while ($attempts_left > 0)
  {
    if ($use_nfs)
    {
      msg(2, "INFO", "createRemoteDirs: ".$cmd);
      ($result, $response) = Dada::mySystem($cmd);
      msg(2, "INFO", "createRemoteDirs: ".$result." ".$response);
    }
    else
    {
      msg(2, "INFO", "createRemoteDirs: ".$user."@".$host.":".$cmd);
      ($result, $rval, $response) = Dada::remoteSshCommand($user, $host, $cmd);
      msg(2, "INFO", "createRemoteDirs: ".$result." ".$rval." ".$response);
    }

    if (($result eq "ok") && ($rval == 0))
    {
      msg(2, "INFO", "createRemoteDirs: remote directory created");

      # now copy obs.header file to remote directory
      if (-f $obs_header)
      { 
        if ($use_nfs)
        {
          $cmd = "cp ".$obs_header." ".$remote_dir."/";
        }
        else
        {
          $cmd = "scp ".$obs_header." ".$user."@".$host.":".$remote_dir."/";
        }
        msg(2, "INFO", "createRemoteDirs: ".$cmd);
        ($result, $response) = Dada::mySystem($cmd);
        msg(2, "INFO", "createRemoteDirs: ".$result." ".$response);
        if ($result ne "ok")
        {
          msg(0, "INFO", "createRemoteDirs: ".$cmd." failed: ".$response);
          msg(0, "WARN", "could not copy obs.header file to server");
          return ("fail", "could not copy obs.header file");
        }
        else
        {
          return ("ok", "");
        }
      }
      else
      {
        $attempts_left--;
        sleep(1);
      }
    }
    else
    {
      if ($result ne "ok")
      {
        msg(0, "INFO", "createRemoteDir: ssh failed ".$user."@".$host.": ".$response);
        msg(0, "WARN", "could not ssh to server");
      }
      else
      {
        msg(0, "INFO", "createRemoteDir: ".$cmd." failed: ".$response);
        msg(0, "WARN", "could not create dir on server");
      }
      $attempts_left--;
      sleep(1);
    }
  }

  return ("fail", "could not create remote directory");
}


#
# Logs a message to the nexus logger and print to STDOUT with timestamp
#
sub msg($$$)
{
  my ($level, $type, $msg) = @_;

  if ($level <= $dl)
  {
    my $time = Dada::getCurrentDadaTime();
    if (!($sys_log_sock)) {
      $sys_log_sock = Dada::nexusLogOpen($log_host, $sys_log_port);
    }
    if ($sys_log_sock) {
      Dada::nexusLogMessage($sys_log_sock, sprintf("%02d",$chan_id), $time, "sys", $type, "bfproc", $msg);
    }
    print "[".$time."] ".$msg."\n";
  }
}

sub controlThread($)
{
  (my $pid_file) = @_;

  msg(2, "INFO", "controlThread : starting");

  my $host_quit_file = $cfg{"CLIENT_CONTROL_DIR"}."/".$daemon_name.".quit";
  my $pwc_quit_file  = $cfg{"CLIENT_CONTROL_DIR"}."/".$daemon_name."_".$chan_id.".quit";

  while ((!$quit_daemon) && (!(-f $host_quit_file)) && (!(-f $pwc_quit_file)))
  {
    sleep(1);
  }

  $quit_daemon = 1;

  my ($cmd, $result, $response);

  $cmd = "^dada_header -k ".$db_key;
  msg(2, "INFO" ,"controlThread: killProcess(".$cmd.", mpsr)");
  ($result, $response) = Dada::killProcess($cmd, "mpsr");
  msg(3, "INFO" ,"controlThread: killProcess() ".$result." ".$response);

  $cmd = "^dada_dbnull -k ".$db_key;
  msg(2, "INFO" ,"controlThread: killProcess(".$cmd.", mpsr)");
  ($result, $response) = Dada::killProcess($cmd, "mpsr");
  msg(3, "INFO" ,"controlThread: killProcess() ".$result." ".$response);

  if ( -f $pid_file) {
    msg(2, "INFO", "controlThread: unlinking PID file");
    unlink($pid_file);
  } else {
    msg(1, "WARN", "controlThread: PID file did not exist on script exit");
  }

  msg(2, "INFO", "controlThread: exiting");

}

sub sigHandle($)
{
  my $sigName = shift;
  print STDERR $daemon_name." : Received SIG".$sigName."\n";

  # if we CTRL+C twice, just hard exit
  if ($quit_daemon) {
    print STDERR $daemon_name." : Recevied 2 signals, Exiting\n";
    exit 1;

  # Tell threads to try and quit
  } else {

    $quit_daemon = 1;
    if ($sys_log_sock) {
      close($sys_log_sock);
    }
  }
}

sub sigPipeHandle($)
{
  my $sigName = shift;
  print STDERR $daemon_name." : Received SIG".$sigName."\n";
  $sys_log_sock = 0;
  if ($log_host && $sys_log_port) {
    $sys_log_sock = Dada::nexusLogOpen($log_host, $sys_log_port);
  }
}

