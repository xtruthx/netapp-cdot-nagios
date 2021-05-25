#!/perl/bin/perl

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

# use lib "/usr/lib/netapp-manageability-sdk/lib/perl/NetApp";
use lib "C:/netapp-manageability-sdk-9.8P1/lib/perl/NetApp";

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

my $version = "1.0.0";

# get list of excluded elements
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
# get average latency
$xi2->child_add_string('average-latency','<average-latency>');


my $xi3 = new NaElement('disk-raid-info');
$xi1->child_add($xi3);
# get container type to later filter out unassigned disks
$xi3->child_add_string('container-type','<container-type>');


# query for specific disk
my $xi4 = new NaElement('query');
$iterator->child_add($xi4);
my $xi5 = new NaElement('storage-disk-info');
$xi4->child_add($xi5);

if($Disk){
    $xi5->child_add_string('disk-name',$Disk);
}


my $next = "";

my (@crit_msg,@warn_msg,@ok_msg,@extended_ok);

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

        my $raid_type = $disk->child_get( "disk-raid-info" );
        my $container = $raid_type->child_get_string( "container-type" );


        # if disk should be excluded from check, ignore and next
        next if exists $Excludelist{$disk_name};
        
        if ($regexp and $excludeliststr) {
            if ($disk_name =~ m/$excludeliststr/) {
                next;
            }
        }

        # skip if disk is unassigned
        next if ($container eq 'unassigned');


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

            $ok_msg = "$disk_name (Latency: $average_latency ms)";
            push (@extended_ok, $ok_msg);

            if(!@ok_msg) {
                if ($Disk) {
                    push (@ok_msg, "Disk $disk_name is in normal condition.\n");  
                } else {
                    push (@ok_msg, "All disks are in normal condition.\n");   
                }
            }
        }

		$disk_count++;
	}
	$next = $output->child_get_string("next-tag");
}

# Version output
print "Script version: $version\n";

if(scalar(@crit_msg) ){
    print "CRITICAL:\n";
    print join (" ", @crit_msg);
    print join ("\n", @extended_ok)."\n";

	exit 2;
} elsif(scalar(@warn_msg) ){
    print "WARN:\n";
    print join (" ", @warn_msg);
    print join ("\n", @extended_ok)."\n";

    exit 1;
} elsif(scalar(@ok_msg) ){
    print "OK: ";
    print join (" ", @ok_msg);
    print join ("\n", @extended_ok)."\n";

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
