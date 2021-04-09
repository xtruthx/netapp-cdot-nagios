#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_clusterhealth - Check Clusternode Health, HA-Interconnect and Cluster Links
# Copyright (C) 2021 operational services GmbH & Co. KG
# Copyright (C) 2013 noris network AG, http://www.noris.net/
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
use Data::Dumper;
use List::Util qw(max);
use Getopt::Long qw(:config no_ignore_case);

# High resolution alarm, sleep, gettimeofday, interval timers
use Time::HiRes qw();

my $STARTTIME_HR = Time::HiRes::time();           # time of program start, high res
my $STARTTIME    = sprintf("%.0f",$STARTTIME_HR); # time of program start

# Parameters for script exec
GetOptions(
    'output-html' => \my $output_html,
    'H|hostname=s' => \my $Hostname,
    'u|username=s' => \my $Username,
    'p|password=s' => \my $Password,
    'autogiveback' => \my $Autogiveback,
    'P|perf'     => \my $perf,
    'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'perfdatadir=s' => \my $perfdatadir,
    'perfdataservicedesc=s' => \my $perfdataservicedesc,
    'hostdisplay=s' => \my $hostdisplay,
    'h|help'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my $version = "1.0.6";

# get list of excluded elements
my %Excludelist;
@Excludelist{@excludelistarray}=();
my $excludeliststr = join "|", @excludelistarray;

sub Error {
    print "$0: " . $_[0] . "\n";
    exit 2;
}

# write performance data for plugin
sub perfdata_to_file {
    # write perfdata to a spoolfile in perfdatadir instead of in plugin output

    my ($s_starttime, $s_perfdatadir, $s_hostdisplay, $s_perfdataservicedesc, $s_perfdata) = @_;

    if (! $s_perfdataservicedesc) {
        if (defined $ENV{'NAGIOS_SERVICEDESC'} and $ENV{'NAGIOS_SERVICEDESC'} ne "") {
            $s_perfdataservicedesc = $ENV{'NAGIOS_SERVICEDESC'};
        } elsif (defined $ENV{'ICINGA_SERVICEDESC'} and $ENV{'ICINGA_SERVICEDESC'} ne "") {
            $s_perfdataservicedesc = $ENV{'ICINGA_SERVICEDESC'};
        } else {
            print "UNKNOWN: please specify --perfdataservicedesc when you want to use --perfdatadir to output perfdata.";
            exit 3;
        }
    }

    if (! $s_hostdisplay) {
        if (defined $ENV{'NAGIOS_HOSTNAME'} and $ENV{'NAGIOS_HOSTNAME'} ne "") {
            $s_hostdisplay = $ENV{'NAGIOS_HOSTNAME'};
        }  elsif (defined $ENV{'ICINGA_HOSTDISPLAYNAME'} and $ENV{'ICINGA_HOSTDISPLAYNAME'} ne "") {
            $s_hostdisplay = $ENV{'ICINGA_HOSTDISPLAYNAME'};
        } else {
            print "UNKNOWN: please specify --hostdisplay when you want to use --perfdatadir to output perfdata.";
            exit 3;
        }
    }

    
    # PNP Data example: (without the linebreaks)
    # DATATYPE::SERVICEPERFDATA\t
    # TIMET::$TIMET$\t
    # HOSTNAME::$HOSTNAME$\t                       -| this relies on getting the same hostname as in Icinga from -H or -h
    # SERVICEDESC::$SERVICEDESC$\t
    # SERVICEPERFDATA::$SERVICEPERFDATA$\t
    # SERVICECHECKCOMMAND::$SERVICECHECKCOMMAND$\t -| not needed (interfacetables uses own templates)
    # HOSTSTATE::$HOSTSTATE$\t                     -|
    # HOSTSTATETYPE::$HOSTSTATETYPE$\t              | not available here
    # SERVICESTATE::$SERVICESTATE$\t                | so its skipped
    # SERVICESTATETYPE::$SERVICESTATETYPE$         -|

    # build the output
    my $s_perfoutput;
    $s_perfoutput .= "DATATYPE::SERVICEPERFDATA\tTIMET::".$s_starttime;
    $s_perfoutput .= "\tHOSTNAME::".$s_hostdisplay;
    $s_perfoutput .= "\tSERVICEDESC::".$s_perfdataservicedesc;
    $s_perfoutput .= "\tSERVICEPERFDATA::".$s_perfdata;
    $s_perfoutput .= "\n";

    # flush to spoolfile
    my $filename = $s_perfdatadir . "/check_cdot_clusterhealth.$s_starttime";
    umask "0000";
    open (OUT,">>$filename") or die "cannot open $filename $!";
    flock (OUT, 2) or die "cannot flock $filename ($!)"; # get exclusive lock;
    print OUT $s_perfoutput;
    close(OUT);
    
}


Error('Option --hostname needed!') unless $Hostname;
Error('Option --username needed!') unless $Username;
Error('Option --password needed!') unless $Password;
$perf = 0 unless $perf;


my (@crit_msg, @ok_msg);
# Store all perf data points for output at end
my %perfdata=();
# my $h_warn_crit_info={};
my $node_count = 0;
my @failed_ports;
my @failed_ics;
my @ret;

my $s = NaServer->new( $Hostname, 1, 130 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

# Check cluster lifs
my $lif_api = new NaElement('net-port-get-iter');
$lif_api->child_add_string('max-records','1000000');

my $lif_output = $s->invoke_elem($lif_api);

if ($lif_output->results_errno != 0) {
    my $r = $lif_output->results_reason();
    print "UNKNOWN: $r\n";
    exit 3;
}

my $lifs = $lif_output->child_get("attributes-list");
my @lif_result = $lifs->children_get();

foreach my $lif (@lif_result){

    my $role = $lif->child_get_string("role");

    if($role eq "cluster"){

        my $link = $lif->child_get_string("link-status");
        my $name = $lif->child_get_string("port");
        my $node = $lif->child_get_string("node");

        if($link eq "down"){
            push(@failed_ports, "$node:$name");
        }
    }
}

# Check cluster health
my $node_iterator = NaElement->new("cf-get-iter");
my $nodeoutput = $s->invoke_elem($node_iterator);

if ($nodeoutput->results_errno != 0) {
    my $r = $nodeoutput->results_reason();
    print "UNKNOWN: $r\n";
    exit 3;
}

my $nodes = $nodeoutput->child_get('attributes-list');    
my @result = $nodes->children_get();

my $cluster_size = @result;

foreach my $node (@result) {
    my ($crit_msg, $ok_msg);
    # get node related ha and state information
    my $node_info = $node->child_get('sfo-node-info');
    my @node_related_object = $node_info->children_get();
    my $node_name;
    my $node_state;
    my $node_current_mode;
    my $takeover_state;
    my $takeover_of;
    my $takeover_by;
    my $failover_enabled;
    my $auto_giveback_enabled;

    foreach my $node_related_info (@node_related_object) {
        $node_name = $node_related_info->child_get_string('node');

        # next if exists $Excludelist{$node_name};

        # if ($regexp and $excludeliststr) {
		# 	if ($node_name =~ m/$excludeliststr/) {
		# 		next;
		# 	}
		# }

        $node_state = $node_related_info->child_get_string('node-state');
        my $node_state_description = $node_related_info->child_get_string('state-description');
        my $node_current_mode = $node_related_info->child_get_string('current-mode');
        my $node_ha_type = $node_related_info->child_get_string('ha-type');

        $ok_msg = "$node_name (";
        
        if(($node_state_description !~ m/Connected/) || $node_current_mode ne 'ha' ) {

            if($node_state_description !~ m/Connected/) {
                $crit_msg .= "State: $node_state, Description: $node_state_description, ";
                # $h_warn_crit_info->{$node_name}->{'node_state_c'} = 1;
            }
            if (($node_current_mode ne 'ha') && ($cluster_size le 2)) {
                $ok_msg .= "Current HA Mode: $node_current_mode, ";
                # $h_warn_crit_info->{$node_name}->{'node_mode_c'} = 1;
            } else {
                $crit_msg .= "Current HA Mode: $node_current_mode, ";
            }
        } else {
            $ok_msg .= "State: $node_state, $node_current_mode, ";
        }
    }

    if($cluster_size ge 2) {
        # get takover related information
        my $takeover_info = $node->child_get('sfo-takeover-info');
        my @takeover_related_object = $takeover_info->children_get();

        foreach my $takeover_related_info (@takeover_related_object) {
            $takeover_state = $takeover_related_info->child_get_string('takeover-state');
            my $takeover_reason = $takeover_related_info->child_get_string('takeover-reason');
            $takeover_of = $takeover_related_info->child_get_string('takeover-of-partner-possible');
            $takeover_by = $takeover_related_info->child_get_string('takeover-by-partner-possible');
            my $takeover_of_reason = $takeover_related_info->child_get_string('takeover-of-partner-not-possible-reason');
            my $takeover_by_reason = $takeover_related_info->child_get_string('takeover-by-partner-not-possible-reason');

            #print $takeover_state." ".$takeover_of." ".$takeover_by."\n";
            if(($takeover_reason) || ($takeover_of_reason) || ($takeover_by_reason)) {
                if($takeover_reason) {
                    $crit_msg .= "Reason for takeover: $takeover_reason, ";
                    # $h_warn_crit_info->{$node_name}->{'node_takeover_c'} = 1;
                }
                if($takeover_of_reason) {
                    $crit_msg .= "Reason why takeover of partner not possible: $takeover_of_reason, ";
                    # $h_warn_crit_info->{$node_name}->{'node_takeover_of_c'} = 1;
                }
                if($takeover_by_reason) {
                    $crit_msg .= "Reason why takeover by partner not possible: $takeover_by_reason, ";
                    # $h_warn_crit_info->{$node_name}->{'node_takeover_by_c'} = 1;
                }
            } else {
                $ok_msg .= "Takeover State: $takeover_state, Takeover of Partner: $takeover_of, Takeover by Partner: $takeover_by, ";
            }
        }

        # get storage failover options
        my $failover_info = $node->child_get('sfo-options-info');
        my @failover_object = $failover_info->children_get();

        foreach my $failover_options_info (@failover_object) {
            $failover_enabled = $failover_options_info->child_get_string('failover-enabled');
            $auto_giveback_enabled = $failover_options_info->child_get_string('auto-giveback-enabled');

            if(($failover_enabled ne 'true') || ($auto_giveback_enabled ne 'true')) {
                if($failover_enabled ne 'true') {
                    $crit_msg .= "Failover enabled: $failover_enabled, ";
                    # $h_warn_crit_info->{$node_name}->{'node_failover_c'} = 1;
                }
                if($auto_giveback_enabled ne 'true') {
                    $ok_msg .= "Giveback enabled: $auto_giveback_enabled, ";
                    # $h_warn_crit_info->{$node_name}->{'node_giveback_c'} = 1;
                }
            } else {
                if($auto_giveback_enabled eq 'true') {
                    $ok_msg .= "Giveback enabled: $auto_giveback_enabled, ";
                    # $h_warn_crit_info->{$node_name}->{'node_giveback_c'} = 1;
                }
            }
        }

        # get missing disk information
        my $missing_info = $node->child_get('sfo-storage-info');
        my @missing_object = $missing_info->children_get();

        foreach my $missing_disk_info (@missing_object) {
            my $local_missing_disks = $missing_disk_info->child_get_string('local-missing-disks');
            my $partner_missing_disks = $missing_disk_info->child_get_string('partner-missing-disks');

            #print $local_missing_disks." ".$partner_missing_disks."\n";
            if(($local_missing_disks) || ($partner_missing_disks)) {
                if($local_missing_disks) {
                    $crit_msg .= "Disks local node is missing but partner node sees: $local_missing_disks, ";
                    # $h_warn_crit_info->{$node_name}->{'node_missing_local_c'} = 1;
                }
                if($partner_missing_disks) {
                    $crit_msg .= "Disks partner node missing but local node sees: $partner_missing_disks, ";
                    # $h_warn_crit_info->{$node_name}->{'node_missing_partner_c'} = 1;
                }
            }
        }

        # get interconnect link information for clusters with more than 1 node
        unless($cluster_size < 2) {
            my $interconnect_info = $node->child_get('sfo-interconnect-info');
            my @interconnect_object = $interconnect_info->children_get();

            foreach my $interconnect_disk_info (@interconnect_object) {
                my $interconnect_up = $interconnect_disk_info->child_get_string('is-interconnect-up');
                my $interconnect_type = $interconnect_disk_info->child_get_string('interconnect-type');
                my $interconnect_links = $interconnect_disk_info->child_get_string('interconnect-links');

                # print $link_status."\n";
                my $link_status = (split(/[()]/, $interconnect_links))[1];

                if($interconnect_up eq 'false' || grep(/down/, $link_status)){
                    push @failed_ics, "$node_name: $interconnect_links";
                    chop($ok_msg); chop($ok_msg);
                } else {
                    $ok_msg .= $interconnect_links;
                }
            }
        } else { print "INFO: Skipping interconnect link check for one-node-cluster\n"; }
    }

    # chop off last comma from critical message and push to array
    if ($crit_msg) {
        $crit_msg = $node_name . " (" . $crit_msg; chop($crit_msg); chop($crit_msg); $crit_msg .= ")";
        push (@crit_msg, "$crit_msg");
    }
    
    $ok_msg .= ")";
    push (@ok_msg, "$ok_msg"); 

    # gather all data for perfdata output
    $perfdata{$node_name}{'node_state'}=$node_state;
    $perfdata{$node_name}{'node_current_mode'}=$node_current_mode;
    $perfdata{$node_name}{'takeover_state'}=$takeover_state;
    $perfdata{$node_name}{'takeover_of'}=$takeover_of;
    $perfdata{$node_name}{'takeover_by'}=$takeover_by;
    $perfdata{$node_name}{'failover_enabled'}=$failover_enabled;
    $perfdata{$node_name}{'auto_giveback_enabled'}=$auto_giveback_enabled;

    $node_count++;
}

# Build perf data string for output
my $perfdataglobalstr=sprintf("Node_count::check_cdot_node_count::count=%d;;;0;;", $node_count);
my $perfdatavolstr="";
foreach my $node ( keys(%perfdata) ) {
	# DS[1] - node state
	if( $perfdata{$node}{'node_state'} ) {
		$perfdatavolstr.=sprintf(" node_state=%s", $perfdata{$node}{'node_state'} );
	}
	# DS[2] - high availability setting
	if( $perfdata{$node}{'node_current_mode'} ) {
		$perfdatavolstr.=sprintf(" node_current_mode=%s", $perfdata{$node}{'node_current_mode'} );
	}
	# DS[3] - takeover state
	if( $perfdata{$node}{'takeover_state'} ) {
		$perfdatavolstr.=sprintf(" takeover_state=%s", $perfdata{$node}{'takeover_state'} );
	}
	# DS[4] - takeover of partner possible
	if( $perfdata{$node}{'takeover_of'} ) {
		$perfdatavolstr.=sprintf(" takeover_of=%s", $perfdata{$node}{'takeover_of'} );
	}
	# DS[5] - takeover by partner possible
	if( $perfdata{$node}{'takeover_by'} ) {
		$perfdatavolstr.=sprintf(" takeover_by=%s", $perfdata{$node}{'takeover_by'} );
	}
	# DS[6] - failover enabled
	if( $perfdata{$node}{'failover_enabled'} ) {
		$perfdatavolstr.=sprintf(" failover_enabled=%s", $perfdata{$node}{'failover_enabled'} );
	}
	# DS[7] - auto giveback enabled
	if( $perfdata{$node}{'auto_giveback_enabled'} ) {
		$perfdatavolstr.=sprintf(" auto_giveback_enabled=%s", $perfdata{$node}{'auto_giveback_enabled'} );
	}
}

$perfdatavolstr =~ s/^\s+//;
my $perfdataallstr = "$perfdataglobalstr $perfdatavolstr";

# Version output
print "Script version: $version\n";

if(scalar(@crit_msg) || scalar(@failed_ics) || scalar(@failed_ports)){
    print "CRITICAL:\n";

    if(scalar(@crit_msg) ){
        print join ("\n", @crit_msg);
        if ($perf) { 
            if($perfdatadir) {
                perfdata_to_file($STARTTIME, $perfdatadir, $hostdisplay, $perfdataservicedesc, $perfdataallstr);
                print "|$perfdataglobalstr\n";
            } else {
                print "|$perfdataallstr\n";
            }
        } else {
            print "\n";
        }
        push @ret, 2;
    }
    if(scalar(@failed_ics) ){
        print join ("\n", @failed_ics);
        push @ret, 2;
    }
    if(scalar(@failed_ports) ){
        print "\n".scalar(@failed_ports)." cluster ports are down: \n";
        print join ("\n", @failed_ports)."\n\n";
        push @ret, 2;
    }
}
if(scalar(@ok_msg) ){
    print "OK:\n";
    print join ("\n", @ok_msg);
    if ($perf) {
                if($perfdatadir) {
                        perfdata_to_file($STARTTIME, $perfdatadir, $hostdisplay, $perfdataservicedesc, $perfdataallstr);
                        print "|$perfdataglobalstr\n";
                } else {
                        print "|$perfdataallstr\n";
                }
        } else {
                print "\n";
        }
    push @ret, 0;
} else {
    print "WARNING: no node found\n";
    push @ret, 1;
}

exit max(@ret);

__END__

=encoding utf8

=head1 NAME

check_cdot_cluster - Check Clusternode health and clusterlinks

=head1 SYNOPSIS

check_cdot_cluster.pl -H HOSTNAME -u USERNAME -p PASSWORD \
           [--perfdatadir DIR] [--perfdataservicedesc SERVICE-DESC] \
		   [--hostdisplay HOSTDISPLAY] \

=head1 DESCRIPTION

Checks high availability and failover options of all nodes, HA-Interconnect and Cluster Links and warns if it deviates from best practice

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item -P | --perf

Flag for performance data output

=item --exclude

Optional: The name of a volume that has to be excluded from the checks (multiple exclude item for multiple volumes)

=item --perfdatadir DIR

Optional: When specified, the performance data are written directly to a file in the specified location instead of 
transmitted to Icinga/Nagios. Please use the same hostname as in Icinga/Nagios for --hostdisplay. Perfdata format is 
for pnp4nagios currently.

=item --perfdataservicedesc SERVICE-DESC

(only used when using --perfdatadir). Service description to use in the generated performance data. 
Should match what is used in the Nagios/Icinga configuration. Optional if environment macros are enabled in 
nagios.cfg/icinga.cfg (enable_environment_macros=1).

=item --hostdisplay HOSTDISPLAY

(only used when using --perfdatadir). Specifies the host name to use for the perfdata. Optional if environment 
macros are enabled in nagios.cfg/icinga.cfg (enable_environment_macros=1).

=item -help

=item -?

to see this Documentation

=back

=head1 EXIT CODE

3 on Unknown Error
2 if Critical Threshold has been reached
1 if Warning Threshold has been reached or any problem occured
0 if everything is ok

=head1 AUTHORS
 Alexander Krogloth <git at krogloth.de>
 Therese Ho <thereseh at netapp.com>
