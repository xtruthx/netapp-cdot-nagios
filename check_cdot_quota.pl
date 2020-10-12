#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_quota - Check quota usage
# Copyright (C) 2018 operational services GmbH & Co. KG
# Copyright (C) 2016 Joshua Malone (jmalone@nrao.edu)
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
    'capacity-warning=i'  => \my $CapacityWarning,
    'capacity-critical=i' => \my $CapacityCritical,
    'size-warning=i'  => \my $SizeWarning,
    'size-critical=i' => \my $SizeCritical,
    'files-warning=i'  => \my $FilesWarning,
    'files-critical=i' => \my $FilesCritical,
    'P|perf'     => \my $perf,
    'V|volume=s' => \my $Volume,
    'vserver=s'  => \my $Vserver,
    'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'perfdatadir=s' => \my $perfdatadir,
    'perfdataservicedesc=s' => \my $perfdataservicedesc,
    't|target=s'   => \my $Quota,
    'v|verbose' => \my $verbose,
    'h|help'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my $version = "1.0.1";

# separate exclude strings into arrays
my %Excludelist;
@Excludelist{@excludelistarray}=();
my $excludeliststr = join "|", @excludelistarray;

sub Error {
    print "UNKNOWN: $0: " . $_[0] . "\n";
    exit 3;
}
Error('Option --hostname needed!') unless $Hostname;
Error('Option --username needed!') unless $Username;
Error('Option --password needed!') unless $Password;
if ($Quota && !$Volume) {
    Error('Option -t requires a Volume name (-V)!');
}

# Set some conservative default thresholds
$CapacityWarning = 85 unless $CapacityWarning;
$CapacityCritical = 90 unless $CapacityCritical;
$FilesWarning = 85 unless $FilesWarning;
$FilesCritical = 90 unless $FilesCritical;



my ($crit_msg, $warn_msg, $ok_msg);
# Store all perf data points for output at end
my %perfdata=();

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

my $iterator = NaElement->new("quota-report-iter");
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

my $quota_query = NaElement->new("query");
my $quota_info = NaElement->new("quota");

my $quota_extra = NaElement->new("desired-attributes");
my $quota_e = NaElement->new("quota");
# get capacity in percent of hard disk limit and files used in percent of file limit
$quota_extra->child_add_string('disk-used-pct-disk-limit','<disk-used-pct-disk-limit>');
$quota_e->child_add_string('files-used-pct-file-limit','<files-used-pct-file-limit>');


if ($Volume) {
    print("Querying only volume $Volume\n") if ($verbose);
    $iterator->child_add($quota_query);
    $quota_query->child_add($quota_info);
    $quota_info->child_add_string('volume', $Volume);
}
if ($Quota) {
    $quota_info->child_add_string('quota-target', $Quota);
}

if ($Vserver) {
    $quota_info->child_add_string('vserver', $Vserver);
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

    my $quotas = $output->child_get("attributes-list");

    unless($quotas){
	    print "CRITICAL: no quota matching this volume name\n";
	    exit 2;
	}

    my @result = $quotas->children_get();
	my $matching_quotas = @result;

    if($Volume && !$Vserver){
	    if($matching_quotas > 1){
	        print "CRITICAL: more than one volume matching this name\n";
	        exit 2;
	    }
	}


    foreach my $getQuota ( @result ) {
        # Disk limit is in KB
        my $diskLimit = $getQuota->child_get_string('disk-limit');
        if($diskLimit ne "-" || $diskLimit eq 0) {
            $diskLimit = $diskLimit * 1024;
        } else {
            next;
        }

        # Also in KB
        my $diskUsed = $getQuota->child_get_string('disk-used') * 1024;
        my $fileLimit = $getQuota->child_get_string('file-limit');
        my $filesUsed = $getQuota->child_get_string('files-used');
        my $volume = $getQuota->child_get_string('volume');
        my $type = $getQuota->child_get_string('quota-type');
        # my $target = "";
        my $target = $getQuota->child_get_string('quota-target') unless $getQuota->child_get_string('quota-target') eq "*";

        # if Volume quotas should be excluded from check, ignore and next
        next if exists $Excludelist{$volume};
    
        if ($regexp and $excludeliststr) {
            if ($volume =~ m/$excludeliststr/) {
            next;
            }
        }

        if ($type eq "user") {
        #     my $qUsers = $getQuota->child_get('quota-users');
        #     next unless ($qUsers);
        #     my $qUser= $qUsers->child_get('quota-user');
        #     next unless ($qUser);
        #     my $quotaUser = $qUser->child_get_string('quota-user-name');
        #     printf("Found quota for %s on %s\n", $quotaUser, $volume) if ($verbose);
        #     $target = sprintf("%s/%s", $volume, $quotaUser);
        # } else {
            # $target = $getQuota->child_get_string('quota-target') unless $getQuota->child_get_string('quota-target') eq "*";
            next;
        }

        printf ("Quota %s: %s %s %s %s\n", $target, $diskLimit, $diskUsed, $fileLimit, $filesUsed) if ($verbose);
        my $diskPercent = ($diskUsed/$diskLimit*100);

        # Generate pretty-printed scaled numbers
        my $msg = sprintf ("Quota %s is %d%% full (used %s of %s)",
            $target, $diskPercent, humanScale($diskUsed), humanScale($diskLimit) );
        if ($diskPercent >= $CapacityCritical) {
            push (@crit_msg, $msg."\n");
        } elsif ($diskPercent >= $CapacityWarning) {
            push (@warn_msg, $msg."\n");
        } else {
            push (@ok_msg, $msg."\n");
        }

        if ($fileLimit ne "-" ) {
            my $filePercent = ($filesUsed/$fileLimit*100);
            # Check files limit as well as space
            my $msg = sprintf ("Quota %s is %d%% full (files used %s of %s)",
                $target, $filePercent, humanScale($filesUsed), humanScale($fileLimit) );
            if ($diskPercent >= $FilesCritical) {
                push (@crit_msg, $msg."\n");
            } elsif ($diskPercent >= $FilesWarning) {
                push (@warn_msg, $msg."\n");
            } else {
                push (@ok_msg, $msg."\n");
            }
        }


        $perfdata{$target}{'byte_used'}=$diskUsed;
        $perfdata{$target}{'byte_total'}=$diskLimit;
        $perfdata{$target}{'files_used'}=$filesUsed;
        $perfdata{$target}{'file_limit'}=$fileLimit;
    }
    $next = $output->child_get_string("next-tag");
}

# Build perf data string for output
my $perfdatastr="";
foreach my $vol ( keys(%perfdata) ) {
    # DS[1] - Data space used
    $perfdatastr.=sprintf(" %s_space_used=%dB;%d;%d;%d;%d", $vol, $perfdata{$vol}{'byte_used'},
	#$SizeWarning*$perfdata{$vol}{'byte_total'}/100, $SizeCritical*$perfdata{$vol}{'byte_total'}/100,
    #$perfdatastr.=sprintf(" %s_space_used=%dBytes;%d;%d;%d;%d", $vol, $perfdata{$vol}{'byte_used'},
	$CapacityWarning*$perfdata{$vol}{'byte_total'}/100, $CapacityCritical*$perfdata{$vol}{'byte_total'}/100,
    0, $perfdata{$vol}{'byte_total'} );
}

# Version output
print "Script version: $version\n";

if(scalar(@crit_msg) ){
    print "CRITICAL:\n";
    print join ("", @crit_msg, "WARNING:\n", @warn_msg, "OK:\n", @ok_msg);
    if ($perf) {
        print "|$perfdatastr\n";
    }
    exit 2;
} elsif(scalar(@warn_msg) ){
    print "WARNING:\n";
    print join ("", @warn_msg, "OK:\n", @ok_msg);
    if ($perf) {
        print "|$perfdatastr\n";        
    }
    exit 1;
} elsif(scalar(@ok_msg) ){
    print "OK:\n";
    print join ("", @ok_msg);
    if ($perf) {
        print "|$perfdatastr\n";
    }
    exit 0;
} else {
    print "INFO: no online volume found\n";
    exit 0;
}

sub humanScale {
    my ($metric) = @_;
    my $unit='B';
    my @units = qw( KB MB GB TB PB EB );
    while ($metric > 1100) {
	if (scalar(@units)<1) {
	    # Hit our max scaling factor - bail out
	    last;
	}
        $unit=shift(@units);
	$metric=$metric/1024;
    }
    return sprintf("%.1f %s", $metric, $unit);
}

__END__

=encoding utf8

=head1 NAME

check_cdot_quota - Check quota usage

=head1 SYNOPSIS

check_cdot_quota.pl -H HOSTNAME -u USERNAME -p PASSWORD \
           -w PERCENT_WARNING -c PERCENT_CRITICAL \
	   --files-warning PERCENT_WARNING \
           --files-critical PERCENT_CRITICAL [-V VOLUME] [-P]

=head1 DESCRIPTION

Checks the space and files usage of a quota / qtree and alerts
if warning or critical thresholds are reached

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor (Cluster or Node MGMT)

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item --capacity-warning PERCENT_WARNING

The Warning threshold for disk space usage. Defaults to 85% if not given.

=item --capacity-critical PERCENT_CRITICAL

The Critical threshold for disk space usage. Defaults to 90% if not given.

=item --files-warning PERCENT_WARNING

The Warning threshold for files used. Defaults to 85% if not given.

=item --files-critical PERCENT_CRITICAL

The Critical threshold for files used. Defaults to 90% if not given.

=item --exclude

Optional: The name of a volume that has to be excluded from the checks (multiple exclude item for multiple volumes)

=item -V | --volume VOLUME

Optional: The name of the Volume on which quotas should be checked.

=item -t | --target TARGET

Optional: The target of a specific quota / qtree that should be checked.
To use this option, you **MUST** specify a  volume.  

=item -P --perf

Output performance data.

=item -help

=item -h

to see this Documentation

=back

=head1 EXIT CODE

3 on Unknown Error
2 if Critical Threshold has been reached
1 if Warning Threshold has been reached or any problem occured
0 if everything is ok

=head1 AUTHORS

 Therese Ho <thereseh at netapp.com>
 Joshua Malone <jmalone at nrao.edu>
 Alexander Krogloth <git at krogloth.de>
 Stefan Grosser <sgr at firstframe.net>
