#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_snapmirror - Checks SnapMirror Healthnes
# Copyright (C) 2013 noris network AG, http://www.noris.net/
# Copyright (C) 2020 Operational Services GmbH & Co. KG, http://www.operational-services.de/

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
use Getopt::Long;
use Data::Dumper;
use List::Util qw(max);
#use Time::Piece;
#use Time::Seconds qw/ ONE_DAY /;

GetOptions(
    'H|hostname=s' => \my $Hostname,
    'u|username=s' => \my $Username,
    'p|password=s' => \my $Password,
    'l|lag=i'      => \my $LagOpt,
    'V|volume=s'   => \my $VolumeName,
    'vserver=s'  => \my $VServer,
    'exclude=s'  => \my @excludelistarray,
    'regexp'     => \my $regexp,
    'v|verbose'  => \my $verbose,
    'help|?'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my $version = "1.0.4";

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
$LagOpt = 3600 * 28 unless $LagOpt; # 1 day 4 hours

sub sec2human {
    my $secs = shift;
    if    ($secs >= 365*24*60*60) { return sprintf '%.1f year(s)', $secs/(365*24*60*60) }
    elsif ($secs >=     24*60*60) { return sprintf '%.1f day(s)', $secs/(24*60*60) }
    elsif ($secs >=        60*60) { return sprintf '%.1f hour(s)', $secs/(60*60) }
    elsif ($secs >=           60) { return sprintf '%.1f min(s)', $secs/(60) }
    else                          { return sprintf '%.1f sec(s)', $secs}
}

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

my $snap_iterator = NaElement->new("snapmirror-get-iter");
my $tag_elem = NaElement->new("tag");
$snap_iterator->child_add($tag_elem);

my $query_elem;
my $sminfo_elem;
if(defined($VolumeName) || defined($VServer)) {
	$query_elem = NaElement->new("query");
    $snap_iterator->child_add($query_elem);
	$sminfo_elem = NaElement->new("snapmirror-info");
	$query_elem->child_add($sminfo_elem);
	if(defined($VolumeName)) {
		$sminfo_elem->child_add_string("destination-volume", $VolumeName);
	}
	if(defined($VServer)) {
		$sminfo_elem->child_add_string("destination-vserver", $VServer);
	}
}

my $next = "";
my @return;
my $snapmirror_failed = 0;
my $snapmirror_lag = 0;
my $snapmirror_ok = 0;
my %failed_names;
my %lagged_names;
my %normal_names;
my @excluded_volumes;
my $exclude_printed = 0;

while(defined($next)){
	unless($next eq ""){
		$tag_elem->set_content($next);    
	}

	$snap_iterator->child_add_string("max-records", 100);
	my $snap_output = $s->invoke_elem($snap_iterator);

	if ($snap_output->results_errno != 0) {
		my $r = $snap_output->results_reason();
		print "UNKNOWN: $r\n";
		exit 3;
	}

	my $num_records = $snap_output->child_get_string("num-records");

	if($num_records eq 0){
        last;
	}

	my @snapmirrors = $snap_output->child_get("attributes-list")->children_get();

	foreach my $snap (@snapmirrors){

		my $status = $snap->child_get_string("relationship-status");
		my $healthy = $snap->child_get_string("is-healthy");
		my $lag = $snap->child_get_string("lag-time");
        my $dest_vserver = $snap->child_get_string("destination-vserver");
		my $dest_vol = $snap->child_get_string("destination-volume");
		my $source_vol = $snap->child_get_string("source-volume");
		my $current_transfer = $snap->child_get_string("current-transfer-type");

        if ($verbose) {
            print "[DEBUG] dest_vol=$dest_vol,\t status=$status,\t healthy=$healthy,\t lag=$lag\n";
        }

        if($dest_vol) {
            if (exists $Excludelist{$dest_vol}) {
                push(@excluded_volumes,$dest_vol."\n");
                next;
            }
            if ($regexp and $excludeliststr) {
                if ($dest_vol =~ m/$excludeliststr/) {
                    push(@excluded_volumes,$dest_vol."\n");
                    next;
                }
            }
        }

		# check for unhealthy relationships
		unless ($healthy eq "true"){
            if ($verbose) {
                print "[DEBUG] ".Dumper($snap);
            }
            if(! $current_transfer){
                if($dest_vol){
                    $failed_names{$dest_vol} = [ $healthy, $lag ];
                } elsif($source_vol) {
                    $failed_names{$source_vol} = [ $healthy, $lag ];
                } else {
                    $failed_names{$dest_vserver} = [ $healthy, $lag ];
                }
    		
                $snapmirror_failed++;
            } elsif (($status eq "transferring") || ($status eq "finalizing")){
    			$snapmirror_ok++;
    		}
        }

        # check for lags
        if (defined($lag) && ($lag >= $LagOpt)){
            if ($verbose) {
                print "[DEBUG] ".Dumper($snap);
            }
            if($dest_vol) {
                unless(($failed_names{$dest_vol}) || ($status eq "transferring") || ($status eq "finalizing")){
                    $lagged_names{$dest_vol} = [ $healthy, $lag ];
                    $snapmirror_lag++;
                }
            } elsif($source_vol) {
                unless(($failed_names{$source_vol}) || ($status eq "transferring") || ($status eq "finalizing")){
                    $lagged_names{$source_vol} = [ $healthy, $lag ];
                    $snapmirror_lag++;
                }
            }
        }

        # all remaining relationships
        if($dest_vol) {
            unless(($failed_names{$dest_vol}) || ($lagged_names{$dest_vol}) ){
                $normal_names{$dest_vol} = [ $healthy, $lag ];
                $snapmirror_ok++;
            }
        } elsif($source_vol) {
            unless(($failed_names{$dest_vol}) || ($lagged_names{$dest_vol}) ){
                $normal_names{$source_vol} = [ $healthy, $lag ];
                $snapmirror_ok++;
            }
        }
	}
$next = $snap_output->child_get_string("next-tag");
}

# Version output
print "Script version: $version\n";

# Return erweitern, auch bei Fehlern und OK alles zurückgeben (Liste an Snapmirror)
if ($snapmirror_failed) {
	print "WARNING: $snapmirror_failed snapmirror(s) failed\n";
	print "Failing snapmirror(s):\n";
	printf ("%-*s%*s%*s\n", 80, "Name", 10, "Healthy", 20, "Delay");
	for my $vol ( keys %failed_names ) {
		my $health_lag = $failed_names{$vol};
		my @health_lag_value = @{ $health_lag };
		unless($health_lag_value[1]) { $health_lag_value[1] = "--- " } else { $health_lag_value[1] = sec2human($health_lag_value[1] )  };
		printf ("%-*s%*s%*s\n", 80, $vol, 10, $health_lag_value[0], 20, $health_lag_value[1]);
	}

	if (@excluded_volumes) {
		print "\nExcluded volume(s):\n";
		print "@excluded_volumes\n";
		$exclude_printed = 1;
	}
	push @return, 1;
} 
if ($snapmirror_lag){	
	print "\nINFO: $snapmirror_lag snapmirror(s) lagging\n";
	print "Lagging snapmirror(s):\n";
	printf ("%-*s%*s%*s\n", 80, "Name", 10, "Healthy", 20, "Delay");
	for my $vol ( keys %lagged_names ) {
		my $health_lag = $lagged_names{$vol};
		my @health_lag_value = @{ $health_lag };
		unless($health_lag_value[1]) { $health_lag_value[1] = "--- " } else { $health_lag_value[1] = sec2human($health_lag_value[1] ) };
		printf ("%-*s%*s%*s\n", 80, $vol, 10, $health_lag_value[0], 20, $health_lag_value[1]);
	}

	if (@excluded_volumes && !$exclude_printed) {
		print "\nExcluded volume(s):\n";
		print "@excluded_volumes\n";
	}
	push @return, 0;
}

print "\nOK: $snapmirror_ok snapmirror(s) ok\n";
printf ("%-*s%*s%*s\n", 80, "Name", 10, "Healthy", 20, "Delay");
for my $vol ( keys %normal_names ) {
    my $health_lag = $normal_names{$vol};
    my @health_lag_value = @{ $health_lag };
    unless($health_lag_value[1]) { $health_lag_value[1] = "--- " } else { $health_lag_value[1] = sec2human($health_lag_value[1] ) };
    printf ("%-*s%*s%*s\n", 80, $vol, 10, $health_lag_value[0], 20, $health_lag_value[1]);
}	

if (@excluded_volumes && !$exclude_printed) {
    print "\nExcluded volume(s):\n";
    print "@excluded_volumes\n";
}

push @return, 0;

exit max( @return );


__END__

=encoding utf8

=head1 NAME

check_cdot_snapmirror - Checks SnapMirror Healthness

=head1 SYNOPSIS

check_cdot_snapmirror.pl --hostname HOSTNAME --username USERNAME
           --password PASSWORD [--lag DELAY-SECONDS]
           [--volume VOLUME-NAME] [--vserver VSERVER-NAME] 
           [--exclude VOLUME-NAME] [--regexp] [--verbose]

=head1 DESCRIPTION

Checks the Healthnes of the SnapMirror and wheather every snapshot has a lag lower than one day

=head1 OPTIONS

=over 4

=item --hostname FQDN

The Hostname of the NetApp to monitor (Cluster or Node MGMT)

=item --username USERNAME

The Login Username of the NetApp to monitor

=item --password PASSWORD

The Login Password of the NetApp to monitor

=item --lag DELAY-SECONDS

Snapmirror delay in Seconds. Default 28h

=item --volume VOLUME-NAME

Name of the destination volume to be checked. If not specified, check all volumes.

=item --vserver VSERVER-NAME

Name of the destination vserver to be checked. If not specificed, search only the base server.

=item --exclude

Optional: The name of a volume that has to be excluded from the checks (multiple exclude item for multiple volumes)

=item --regexp

Optional: Enable regexp matching for the exclusion list

=item -v | --verbose

Enable verbose mode

=item -help

=item -?

to see this Documentation

=back

=head1 EXIT CODE

3 if timeout occured
2 if there is an error in the SnapMirror
0 if everything is ok

=head1 AUTHORS

 Alexander Krogloth <git at krogloth.de>
 Stelios Gikas <sgikas at demokrit.de>
