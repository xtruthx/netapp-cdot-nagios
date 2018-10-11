#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_performance - Check Cluster Performance
# Copyright (C) 2018 operational services GmbH & Co. KG
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
    'cpu-critical=i' => \my $CpuCritical,
    'cpu-warning=i' => \my $CpuWarning,
    'disk-load-critical=i' => \my $DiskloadCritical,
    'disk-load-warning=i' => \my $DiskloadWarning,
    'latency-critical=i' => \my $LatencyCritical,
    'latency-warning=i' => \my $LatencyWarning,
    'disk=s' => \my $Disk,
    'P|perf'     => \my $perf,
    'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'perfdatadir=s' => \my $perfdatadir,
    'perfdataservicedesc=s' => \my $perfdataservicedesc,
    'hostdisplay=s' => \my $hostdisplay,
    'h|help'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

# get list of excluded elements
my %Excludelist;
@Excludelist{@excludelistarray}=();
my $excludeliststr = join "|", @excludelistarray;

sub Error {
    print "$0: " . $_[0] . "\n";
    exit 2;
}


# # html output containing the cluster and its status
# # _c = warning in yellow
# # rest = safe in green
# sub draw_html_table {
# 	my ($hrefInfo) = @_;
# 	my @headers = qw(cluster state);
# 	# define columns that will be filled and shown
# 	my @columns = qw(cluster_state);
# 	my $html_table="";
# 	$html_table .= "<table class=\"common-table\" style=\"border-collapse:collapse; border: 1px solid black;\">";
# 	$html_table .= "<tr>";
# 	foreach (@headers) {
# 		$html_table .= "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$_."</th>";
# 	}
# 	$html_table .= "</tr>";
# 	foreach my $cluster (sort {lc $a cmp lc $b} keys %$hrefInfo) {
# 		$html_table .= "<tr>";
# 		$html_table .= "<tr style=\"border: 1px solid black;\">";
# 		$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #acacac;\">".$cluster."</td>";
# 		# loop through all attributes defined in @columns
# 		foreach my $attr (@columns) {
# 			if ($attr eq "cluster_state") {
#                 if (defined $hrefInfo->{$cluster}->{"cluster_state_c"}){
# 					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$cluster}->{$attr}."</td>";
#                 } elsif (defined $hrefInfo->{$cluster}->{"cluster_state_w"}){
# 					$html_table .= "<td class=\"state-warning\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color:  #FFFF00\">".$hrefInfo->{$cluster}->{$attr}."</td>";
# 				} else {
# 					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$cluster}->{$attr}."</td>";
# 				}
# 			} else {
# 				$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$hrefInfo->{$cluster}->{$attr}."</td>";
# 			}
# 		}
# 		$html_table .= "</tr>";
# 	}
# 	$html_table .= "</table>\n";

# 	return $html_table;
# }

# # write performance data for plugin
# sub perfdata_to_file {
#     # write perfdata to a spoolfile in perfdatadir instead of in plugin output

#     my ($s_starttime, $s_perfdatadir, $s_hostdisplay, $s_perfdataservicedesc, $s_perfdata) = @_;

#     if (! $s_perfdataservicedesc) {
#         if (defined $ENV{'NAGIOS_SERVICEDESC'} and $ENV{'NAGIOS_SERVICEDESC'} ne "") {
#             $s_perfdataservicedesc = $ENV{'NAGIOS_SERVICEDESC'};
#         } elsif (defined $ENV{'ICINGA_SERVICEDESC'} and $ENV{'ICINGA_SERVICEDESC'} ne "") {
#             $s_perfdataservicedesc = $ENV{'ICINGA_SERVICEDESC'};
#         } else {
#             print "UNKNOWN: please specify --perfdataservicedesc when you want to use --perfdatadir to output perfdata.";
#             exit 3;
#         }
#     }

#     if (! $s_hostdisplay) {
#         if (defined $ENV{'NAGIOS_HOSTNAME'} and $ENV{'NAGIOS_HOSTNAME'} ne "") {
#             $s_hostdisplay = $ENV{'NAGIOS_HOSTNAME'};
#         }  elsif (defined $ENV{'ICINGA_HOSTDISPLAYNAME'} and $ENV{'ICINGA_HOSTDISPLAYNAME'} ne "") {
#             $s_hostdisplay = $ENV{'ICINGA_HOSTDISPLAYNAME'};
#         } else {
#             print "UNKNOWN: please specify --hostdisplay when you want to use --perfdatadir to output perfdata.";
#             exit 3;
#         }
#     }

    
#     # PNP Data example: (without the linebreaks)
#     # DATATYPE::SERVICEPERFDATA\t
#     # TIMET::$TIMET$\t
#     # HOSTNAME::$HOSTNAME$\t                       -| this relies on getting the same hostname as in Icinga from -H or -h
#     # SERVICEDESC::$SERVICEDESC$\t
#     # SERVICEPERFDATA::$SERVICEPERFDATA$\t
#     # SERVICECHECKCOMMAND::$SERVICECHECKCOMMAND$\t -| not needed (interfacetables uses own templates)
#     # HOSTSTATE::$HOSTSTATE$\t                     -|
#     # HOSTSTATETYPE::$HOSTSTATETYPE$\t              | not available here
#     # SERVICESTATE::$SERVICESTATE$\t                | so its skipped
#     # SERVICESTATETYPE::$SERVICESTATETYPE$         -|

#     # build the output
#     my $s_perfoutput;
#     $s_perfoutput .= "DATATYPE::SERVICEPERFDATA\tTIMET::".$s_starttime;
#     $s_perfoutput .= "\tHOSTNAME::".$s_hostdisplay;
#     $s_perfoutput .= "\tSERVICEDESC::".$s_perfdataservicedesc;
#     $s_perfoutput .= "\tSERVICEPERFDATA::".$s_perfdata;
#     $s_perfoutput .= "\n";

#     # flush to spoolfile
#     my $filename = $s_perfdatadir . "/check_cdot_clusterstat.$s_starttime";
#     umask "0000";
#     open (OUT,">>$filename") or die "cannot open $filename $!";
#     flock (OUT, 2) or die "cannot flock $filename ($!)"; # get exclusive lock;
#     print OUT $s_perfoutput;
#     close(OUT);
    
# }


Error('Option --hostname needed!') unless $Hostname;
Error('Option --username needed!') unless $Username;
Error('Option --password needed!') unless $Password;
$perf = 0 unless $perf;

# Set some default thresholds
    $CpuCritical = 75 unless $CpuCritical;
    $CpuWarning = 60 unless $CpuWarning;
    $DiskloadCritical = 85 unless $DiskloadCritical;
    $DiskloadWarning = 70 unless $DiskloadWarning;
    $LatencyCritical = 50 unless $LatencyCritical;
    $LatencyWarning = 20 unless $LatencyWarning;

my ($crit_msg, $warn_msg, $ok_msg);
# Store all perf data points for output at end
my %perfdata=();
my $h_warn_crit_info={};
my $disk_count = 0;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

my $iterator = NaElement->new("storage-disk-get-iter");

# if more than max items are read
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

# get all disks with names and statistics
my $xi = new NaElement('desired-attributes');
$iterator->child_add($xi);
my $xi1 = new NaElement('storage-disk-info');
$xi->child_add($xi1);
$xi1->child_add_string('disk-name','<disk-name>');

my $xi2 = new NaElement('disk-stats-info');
$xi1->child_add($xi2);

# $xi1->child_add_string('disk-stats-info','<disk-stats-info>');

# get average latency
$xi2->child_add_string('average-latency','<average-latency>');

# query for specific disk
my $xi4 = new NaElement('query');
$iterator->child_add($xi4);
my $xi5 = new NaElement('storage-disk-info');
$xi4->child_add($xi5);

if($Disk){
    $xi5->child_add_string('disk-name',$Disk);
}


my $next = "";

my (@crit_msg,@warn_msg,@ok_msg);

while(defined($next)){
    unless($next eq ""){
        $tag_elem->set_content($next);    
    }

    $iterator->child_add_string("max-records", 100);
    my $output = $s->invoke_elem($iterator);

	if ($output->results_errno != 0) {
	    my $r = $output->results_reason();
	    print "UNKNOWN: $r\n";
	    exit 3;
	}

	my $disks = $output->child_get("attributes-list");

	unless($disks){
	    print "CRITICAL: no disk matching this name\n";
	    exit 2;
	}
	
	my @result = $disks->children_get();

	foreach my $disk (@result){

        my $disk_name = $disk->child_get_string( "disk-name" );

        my $disk_info = $disk->child_get( "disk-stats-info" );
        my $average_latency = $disk_info->child_get_string( "average-latency" );

        # if disk should be excluded from check, ignore and next
        next if exists $Excludelist{$disk_name};
        
        if ($regexp and $excludeliststr) {
            if ($disk_name =~ m/$excludeliststr/) {
                next;
            }
        }


        # if latency is higher than threshold, set it to critical
		if ($average_latency > $LatencyCritical){
                $h_warn_crit_info->{$disk_name}->{'average_latency'}=$average_latency;

				my $crit_msg = "$disk_name (";

				if ($average_latency > $LatencyCritical) {
					$crit_msg .= "Latency: $average_latency ms[>$LatencyCritical ms], ";
					$h_warn_crit_info->{$disk_name}->{'average_latency_c'} = 1;
				} elsif ($average_latency > $LatencyWarning) {
					$crit_msg .= "Latency: $average_latency ms[>$LatencyWarning ms], ";
					$h_warn_crit_info->{$disk_name}->{'average_latency_w'} = 1;
				}

                chop($crit_msg); chop($crit_msg); $crit_msg .= ")\n";
                push (@crit_msg, "$crit_msg" );
        } elsif ($average_latency > $LatencyWarning){
                $h_warn_crit_info->{$disk_name}->{'average_latency'}=$average_latency;

				my $warn_msg = "$disk_name (";

				if ($average_latency > $LatencyWarning) {
					$warn_msg .= "Latency: $average_latency ms[>$LatencyWarning ms], ";
					$h_warn_crit_info->{$disk_name}->{'average_latency_c'} = 1;
				} elsif ($average_latency > $LatencyWarning) {
					$warn_msg .= "Latency: $average_latency ms[>$LatencyWarning ms], ";
					$h_warn_crit_info->{$disk_name}->{'average_latency_w'} = 1;
				}

                chop($warn_msg); chop($warn_msg); $warn_msg .= ")\n";
                push (@warn_msg, "$warn_msg" );
        } else {
            $h_warn_crit_info->{$disk_name}->{'average_latency'}=$average_latency;
            if(!@ok_msg) {
                push (@ok_msg, "All disks are in normal condition.\n");                    
            }
        }

		$disk_count++;
	}
	$next = $output->child_get_string("next-tag");
}


# Build perf data string for output
my $perfdataglobalstr=sprintf("disk_count::check_cdot_disk_count::count=%d;;;0;;", $disk_count);
my $perfdatavolstr="";
foreach my $disk ( keys(%perfdata) ) {
	# DS[1] -$cluster state
	if( $perfdata{$disk}{'cluster_state'} ) {
		$perfdatavolstr.=sprintf(" cluster_state=%s", $perfdata{$disk}{'cluster_state'} );
	}
}


$perfdatavolstr =~ s/^\s+//;
my $perfdataallstr = "$perfdataglobalstr $perfdatavolstr";


if(scalar(@crit_msg) ){
    print "CRITICAL:\n";
    print join (" ", @crit_msg);
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
	#my $strHTML = draw_html_table($h_warn_crit_info);
    #print $strHTML if $output_html; 
	exit 2;
} elsif(scalar(@warn_msg) ){
    print "WARN:\n";
    print join (" ", @warn_msg);
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
    #my $strHTML = draw_html_table($h_warn_crit_info);
    #print $strHTML if $output_html; 
    exit 1;
} elsif(scalar(@ok_msg) ){
    print "OK: ";
    print join (" ", @ok_msg);
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
    exit 0;
} else {
    print "WARNING: no cluster found\n";
    exit 1;
}


__END__

=encoding utf8

=head1 NAME

check_cdot_performance - Check Disk performance (latency values only)

=head1 SYNOPSIS

check_cdot_performance.pl -H HOSTNAME -u USERNAME -p PASSWORD \
           [--latency-critical LATENCY-CRITICAL] \ [--latency-warning LATENCY-WARNING] \
           [--perfdatadir DIR] [--perfdataservicedesc SERVICE-DESC] \
		   [--hostdisplay HOSTDISPLAY] \
		   [--snap-ignore] [-P] [--exclude]

=head1 DESCRIPTION

Checks the SVM State of the NetApp System and warns if warning Thresholds are reached

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item --latency-critical LATENCY-CRITICAL

The Critical threshold for disk latency.

=item --latency-warning LATENCY-WARNING

The Warning threshold for disk latency.

=item -P | --perf

Flag for performance data output

=item --exclude

Optional: The name of a$svm that has to be excluded from the checks (multiple exclude item for multiple$svms)

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

 Therese Ho <thereseh at netapp.com>
