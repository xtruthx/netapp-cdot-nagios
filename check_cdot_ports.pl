#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_ports.pl - Check physical ports of the cluster
# Copyright (C) 2019 operational services GmbH & Co. KG
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

use strict;
use warnings;

use lib "/usr/lib/netapp-manageability-sdk/lib/perl/NetApp";

use NaServer;
use NaElement;
use Getopt::Long qw(:config no_ignore_case);

# High resolution alarm, sleep, gettimeofday, interval timers
use Time::HiRes qw();

my $STARTTIME_HR = Time::HiRes::time();           # time of program start, high res
my $STARTTIME    = sprintf("%.0f",$STARTTIME_HR); # time of program start

GetOptions(
    'H|hostname=s' => \my $Hostname,
    'u|username=s' => \my $Username,
    'p|password=s' => \my $Password,
    'P|port=s'     => \my $Port,
    'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'perfdatadir=s' => \my $perfdatadir,
    'perfdataservicedesc=s' => \my $perfdataservicedesc,
    'help|?'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

# separate exclude strings into arrays
my %Excludelist;
@Excludelist{@excludelistarray}=();
my $excludeliststr = join "|", @excludelistarray;

sub Error {
    print "$0: " . $_[0] . "\n";
    exit 2;
}
Error('Option --hostname needed!') unless $Hostname;
Error('Option --username needed!') unless $Username;
Error('Option --password needed!') unless $Password;

my ($crit_msg, $warn_msg, $ok_msg);
# Store all perf data points for output at end
my %perfdata=();
my $port_count = 0;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

my $iterator = new NaElement('net-port-get-iter');
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

my $desired_attributes = NaElement->new("desired-attributes");
$iterator->child_add($desired_attributes);

# specify which attributes should be returned
my $netportinfo = new NaElement('net-port-info');
$desired_attributes->child_add($netportinfo);
$netportinfo->child_add_string('link-status','link-status');
$netportinfo->child_add_string('port','port');
$netportinfo->child_add_string('node','node');

# specify physical ports only or specific portname provided
my $xi1 = new NaElement('query');
$iterator->child_add($xi1);
my $xi2 = new NaElement('net-port-info');
$xi1->child_add($xi2);
$xi2->child_add_string('port-type','physical');
if($Port){
    $xi2->child_add_string('port',$Port);
}

my $next = "";

my (@crit_msg, @warn_msg, @ok_msg);

while(defined($next)){
    unless($next eq ""){
        $tag_elem->set_content($next);    
    }

    $iterator->child_add_string("max-records", 100);
    my $output = $s->invoke_elem($iterator);
    last if ($output->child_get_string("num-records") eq 0 );

    if ($output->results_errno ne 0) {
	my $r = $output->results_reason();
	print "UNKNOWN: $r\n";
	exit 3;
    }

    my $ports = $output->child_get("attributes-list");

    unless($ports){
	    print "CRITICAL: no port matching this name\n";
	    exit 2;
	}

    my @result = $ports->children_get();

    my @down_ports;

    foreach my $port (@result){

        my $port_name = $port->child_get_string("port");
        my $node_name = $port->child_get_string("node");
        my $link_status = $port->child_get_string("link-status");

        if($link_status eq "down") {
            my $crit_msg = "$port_name (node $node_name) link-status is $link_status";
            push (@crit_msg, "$crit_msg\n");
        } elsif ($link_status eq "unknown") {
            my $warn_msg = "$port_name (node $node_name) is $link_status";
            push (@warn_msg, "$warn_msg\n");
        } else {
            my $ok_msg = "$port_name (node $node_name) is $link_status";
            push (@ok_msg, "$ok_msg\n");
        }
        $port_count++;
        
    }
    $next = $output->child_get_string("next-tag");
}

if(scalar(@crit_msg) ){
    print "CRITICAL:\n";
    print join ("", @crit_msg);
    # if ($perf) { 
	# 	if($perfdatadir) {
	# 		perfdata_to_file($STARTTIME, $perfdatadir, $hostdisplay, $perfdataservicedesc, $perfdataallstr);
	# 		print "|$perfdataglobalstr\n";
	# 	} else {
	# 		print "|$perfdataallstr\n";
	# 	}
	# } else {
	# 	print "\n";
	# }
	exit 2;
} if(scalar(@warn_msg) ){
    print "WARNING:\n";
    print join ("", @warn_msg);
    # if ($perf) {
    #             if($perfdatadir) {
    #                     perfdata_to_file($STARTTIME, $perfdatadir, $hostdisplay, $perfdataservicedesc, $perfdataallstr);
    #                     print "|$perfdataglobalstr\n";
    #             } else {
    #                     print "|$perfdataallstr\n";
    #             }
    #     } else {
    #             print "\n";
    #     }
	exit 1;
} if(scalar(@ok_msg) ){
    print "OK:\n";
    print join ("", @ok_msg);
    # if ($perf) {
    #             if($perfdatadir) {
    #                     perfdata_to_file($STARTTIME, $perfdatadir, $hostdisplay, $perfdataservicedesc, $perfdataallstr);
    #                     print "|$perfdataglobalstr\n";
    #             } else {
    #                     print "|$perfdataallstr\n";
    #             }
    #     } else {
    #             print "\n";
    #     }
    exit 0;
} else {
    print "WARNING: no port with this name found\n";
    exit 1;
}

__END__

=encoding utf8

=head1 NAME

check_cdot_ports - Check physical ports of the cluster

=head1 SYNOPSIS

check_cdot_ports.pl --hostname HOSTNAME --username USERNAME \
           --password PASSWORD

=head1 DESCRIPTION

Checks if all physical ports of the system are up

=head1 OPTIONS

=over 4

=item --hostname FQDN

The Hostname of the NetApp to monitor

=item --username USERNAME

The Login Username of the NetApp to monitor

=item --password PASSWORD

The Login Password of the NetApp to monitor

=item -help

=item -?

to see this Documentation

=back

=head1 EXIT CODE

3 on Unknown Error
2 if any link is down
0 if everything is ok

=head1 AUTHORS

 Alexander Krogloth <git at krogloth.de>
 Therese Ho <thereseh at netapp.com>
