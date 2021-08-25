#!/usr/bin/perl

use LoxBerry::System;
use LoxBerry::IO;
use LoxBerry::Log;
use LoxBerry::JSON;
use Getopt::Long;
#use warnings;
#use strict;
use Data::Dumper;

# Version of this script
my $version = "0.9.0";

# Globals
my $error;
my $verbose;
my $action;

# Logging
# Create a logging object
my $log = LoxBerry::Log->new (  name => "watchdog",
package => 'multiio',
logdir => "$lbplogdir",
addtime => 1,
);

# Commandline options
GetOptions ('verbose=s' => \$verbose,
            'action=s' => \$action);

# Verbose
if ($verbose) {
        $log->stdout(1);
        $log->loglevel(7);
}

LOGSTART "Starting Watchdog";

# Lock
my $status = LoxBerry::System::lock(lockfile => 'multiio-watchdog', wait => 120);
if ($status) {
    print "$status currently running - Quitting.";
    exit (1);
}

# Change config on the fly and convert to yaml for mqtt-io
system ("cp $lbpconfigdir/mqttio.json /dev/shm");
system ("chmod 600 /dev/shm/mqttio.json");
my $cfgfile ="/dev/shm/mqttio.json";
my $jsonobjcfg = LoxBerry::JSON->new();
my $cfg = $jsonobjcfg->open(filename => $cfgfile);
if ( !%$cfg ) {
	LOGERR "Cannot open config file $cfgfile. Exiting.";
	exit (1);
}

my $mqtt = LoxBerry::IO::mqtt_connectiondetails();
$cfg->{'mqtt'}->{'host'} = $mqtt->{'brokerhost'};
$cfg->{'mqtt'}->{'port'} = $mqtt->{'brokerport'};
$cfg->{'mqtt'}->{'user'} = $mqtt->{'brokeruser'} if ($mqtt->{'brokeruser'});
$cfg->{'mqtt'}->{'password'} = $mqtt->{'brokerpass'} if ($mqtt->{'brokerpass'});
$jsonobjcfg->write();

system ("cat /dev/shm/mqttio.json | $lbpconfigdir/helpers/json2yaml.py > /dev/shm/mqttio.yaml");
system ("chmod 600 /dev/shm/mqttio.yaml && rm /dev/shm/mqttio.json");

if (!-e "/dev/shm/mqttio.yaml") {
	LOGERR "Cannot create yaml config file /dev/shm/mqttio.json. Exiting.";
	exit (1);
}







exit;

# Set Defaults from config
# OWFS Server Port
if ( $owfscfg->{"serverport"} ) {
	$serverport=$owfscfg->{"serverport"};
} else {
	$serverport="4304";
}
LOGDEB "Server Port: $serverport";

# Todo
if ( $action eq "start" ) {

	&start();

}

elsif ( $action eq "stop" ) {

	&stop();

}

elsif ( $action eq "restart" ) {

	&restart();

}

elsif ( $action eq "check" ) {

	&check();

}

else {

	LOGERR "No valid action specified. action=start|stop|restart|check is required. Exiting.";
	print "No valid action specified. action=start|stop|restart|check is required. Exiting.\n";
	exit(1);

}

exit;


#############################################################################
# Sub routines
#############################################################################

##
## Start
##
sub start
{

	LOGINF "START called...";
	LOGINF "Starting OWServer...";
	system ("sudo systemctl start owserver");
	sleep (1);
	system ("sudo systemctl start owhttpd");
	sleep (1);
	&readbusses();

	LOGINF "Starting owfs2mqtt instances...";
	for (@busses) {

		my $bus = $_;
		$bus =~ s/^\/bus\.//;
		LOGINF "Starting owfs2mqtt for $_...";
		LOGDEB "Call: $lbpbindir/owfs2mqtt.pl --bus=$bus --verbose=$verboseval";
		eval {
			system("$lbpbindir/owfs2mqtt.pl --bus=$bus --verbose=$verboseval &");
		} or do {
			my $error = $@ || 'Unknown failure';
			LOGERR "Could not start $lbpbindir/owfs2mqtt.pl --bus=$bus --verbose=$verboseval - $error";
		};
	
	}

	return(0);

}

sub stop
{

	LOGINF "STOP called...";
	LOGINF "Stopping OWServer...";
	system ("sudo pkill -f owserver"); # kill needed because stop does take too long (until timeout)
	system ("sudo systemctl stop owserver");
	sleep (1);
	system ("sudo systemctl stop owhttpd");
	sleep (1);

	LOGINF "Stopping owfs2mqtt instances...";
	system ("pkill -f owfs2mqtt.pl");

	return(0);

}

sub restart
{

	LOGINF "RESTART called...";
	&stop();
	sleep (2);
	&start();

	return(0);

}

sub check
{

	LOGINF "CHECK called...";
	my $output;
	my $errors;
	my $exitcode;
	
	# Creating tmp file with failed checks
	if (!-e "/dev/shm/1-wire-ng-watchdog-fails.dat") {
		my $response = LoxBerry::System::write_file("/dev/shm/1-wire-ng-watchdog-fails.dat", "0");
	}

	# owserver
	$output = qx(sudo systemctl -q status owserver);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGERR "owServer seems to be dead - Error $exitcode";
		$errors++;
	}

	# owhttpd
	$output = qx(sudo systemctl -q status owhttpd);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGERR "owhttpd seems to be dead - Error $exitcode";
		$errors++;
	}

	# owfs2mqtt
	$output = qx(pgrep -f owfs2mqtt.pl);
	$exitcode  = $? >> 8;
	if ($exitcode != 0) {
		LOGERR "owfs2mqtt seems to be dead - Error $exitcode";
		$errors++;
	}

	if ($errors) {
		my $fails = LoxBerry::System::read_file("/dev/shm/1-wire-ng-watchdog-fails.dat");
		chomp ($fails);
		$fails++;
		my $response = LoxBerry::System::write_file("/dev/shm/1-wire-ng-watchdog-fails.dat", "$fails");
		if ($fails > 9) {
			LOGERR "Too many failures. Will stop watchdogging... Check your configuration and start services manually.";
		} else {
			&restart();
		}
	} else {
		LOGINF "All processes seems to be alive. Nothing to do.";	
		my $response = LoxBerry::System::write_file("/dev/shm/1-wire-ng-watchdog-fails.dat", "0");
	}

	return(0);

}

##
## Read available busses
##
sub readbusses
{

	# Connect to OWServer
	$error = owconnect();
	if ($error) {
		LOGERR "Error while connecting to OWServer.";
		exit(1);
	}

	LOGINF "Scanning for busses...";
	my $busses;
	
	# Scan for busses
	eval {
		$busses = $owserver->dir("/");
	};
	if ($@ || !$busses) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error Busses: $busses";
		exit (1);
	};
	LOGDEB "OWServer Root Folder: $busses";
	
	# Set default values
	my @temp = split(/,/,$busses);
	for (@temp) {
		if ( $_ =~ /^\/bus.*$/ ) {
			LOGDEB "Found Bus $_";
			push (@busses, $_),
		}
	}

	return();

};

##
## Connect to OWServer
##
sub owconnect
{
	eval {
		$owserver = OWNet->new('localhost:' . $owfscfg->{"serverport"} . " -v -" .$owfscfg->{"tempscale"} );
	};
	if ($@ || !$owserver) {
		my $error = $@ || 'Unknown failure';
        	LOGERR "An error occurred - $error";
		exit (1);
	};
	return($error);

};

##
## Always execute when Script ends
##
END {

	LOGEND "This is the end - My only friend, the end...";
	LoxBerry::System::unlock(lockfile => '1-wire-ng-watchdog');

}
