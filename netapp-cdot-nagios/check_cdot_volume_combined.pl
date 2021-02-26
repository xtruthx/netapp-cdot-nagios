#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_volume - Check Volume Usage
# Copyright (C) 2013 noris network AG, http://www.noris.net/
# Copyright (C) 2018 operational services GmbH & Co. KG
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
    'w|size-warning=i'  => \my $SizeWarning,
    'c|size-critical=i' => \my $SizeCritical,
    'inode-warning=i'  => \my $InodeWarning,
    'inode-critical=i' => \my $InodeCritical,
    'snap-warning=i' => \my $SnapWarning,
    'snap-critical=i' => \my $SnapCritical,
    'snap-ignore=s' => \my $SnapIgnore,
	'autosize-warning=s' => \my $AutosizeWarning,
	'autosize-critical=s' => \my $AutosizeCritical,
	'state-critical=s' => \my $StateCritical,
	'snapshot-limit=i' => \my $SnapshotLimit,
    'P|perf'     => \my $perf,
    'V|volume=s'   => \my $Volume,
    'vserver=s'  => \my $Vserver,
    'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'perfdatadir=s' => \my $perfdatadir,
    'perfdataservicedesc=s' => \my $perfdataservicedesc,
    'hostdisplay=s' => \my $hostdisplay,
    'h|help'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my $version = "1.0.2";

# Filter through full names or regex
my %Excludelist;
@Excludelist{@excludelistarray}=();
my $excludeliststr = join "|", @excludelistarray;

sub Error {
    print "$0: " . $_[0] . "\n";
    exit 2;
}

# html output containing the results for space/inode/snap usage,autosize max in %
# _c = critical in red
# _w = warning in yellow
# rest = ok in green
# sub draw_html_table {
# 	my ($hrefInfo) = @_;
# 	my @headers = qw(volume space-usage inodes-usage snap-usage autosize-maximum state);
# 	# define columns that will be filled and shown
# 	my @columns = qw(space_percent inode_percent snap_percent autosize_percent state);
# 	my $html_table="";
# 	$html_table .= "<table class=\"common-table\" style=\"border-collapse:collapse; border: 1px solid black;\">";
# 	$html_table .= "<tr>";
# 	foreach (@headers) {
# 		$html_table .= "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$_."</th>";
# 	}
# 	$html_table .= "</tr>";
# 	foreach my $volume (sort {lc $a cmp lc $b} keys %$hrefInfo) {
# 		$html_table .= "<tr>";
# 		$html_table .= "<tr style=\"border: 1px solid black;\">";
# 		$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #acacac;\">".$volume."</td>";
# 		# loop through all attributes defined in @columns
# 		foreach my $attr (@columns) {
# 			if ($attr eq "space_percent") {
# 				if (defined $hrefInfo->{$volume}->{"space_percent_c"}){
# 					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} elsif (defined $hrefInfo->{$volume}->{"space_percent_w"}){
# 					$html_table .= "<td class=\"state-warning\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #FFFF00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} else {
# 					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				}
# 			} elsif ($attr eq "inode_percent") {
# 				if (defined $hrefInfo->{$volume}->{"inode_percent_c"}){
# 					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} elsif (defined $hrefInfo->{$volume}->{"inode_percent_w"}){
# 					$html_table .= "<td class=\"state-warning\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #FFFF00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} else {
# 					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				}
# 			} elsif ($attr eq "snap_percent") {
# 				if (defined $hrefInfo->{$volume}->{"snap_percent_c"}){
# 					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} elsif (defined $hrefInfo->{$volume}->{"snap_percent_w"}){
# 					$html_table .= "<td class=\"state-warning\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #FFFF00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} else {
# 					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				}
# 			} elsif ($attr eq "autosize_percent") {
# 				if (defined $hrefInfo->{$volume}->{"autosize_percent_c"}){
# 					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} elsif (defined $hrefInfo->{$volume}->{"autosize_percent_w"}){
# 					$html_table .= "<td class=\"state-warning\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #FFFF00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} else {
# 					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				}
# 			} elsif ($attr eq "state") {
# 				if (defined $hrefInfo->{$volume}->{"volume_state_c"}){
# 					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				} else {
# 					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 				}
# 			} else {
# 				$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$hrefInfo->{$volume}->{$attr}."</td>";
# 			}
# 		}
# 		$html_table .= "</tr>";
# 	}
# 	$html_table .= "</table>\n";

# 	return $html_table;
# }

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
    my $filename = $s_perfdatadir . "/check_cdot_volume.$s_starttime";
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

# Set some conservative default thresholds
$SizeWarning = 90 unless $SizeWarning;
$SizeCritical = 95 unless $SizeCritical;
$InodeWarning = 65 unless $InodeWarning;
$InodeCritical = 85 unless $InodeCritical;
$SnapWarning = 75 unless $SnapWarning;
$SnapCritical = 90 unless $SnapCritical;
$SnapIgnore = "false" unless $SnapIgnore;
$AutosizeWarning = 90 unless $AutosizeWarning;
$AutosizeCritical = 95 unless $AutosizeCritical;
$StateCritical = "offline" unless $StateCritical;
$SnapshotLimit = 230 unless $SnapshotLimit;

my ($crit_msg, $warn_msg, $ok_msg);
# Store all perf data points for output at end
my %perfdata=();
my $h_warn_crit_info={};
my $volume_count = 0;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

# if more than 50 volumes are read
my $iterator = NaElement->new("volume-get-iter");
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

# get all volume names
my $xi = new NaElement('desired-attributes');
$iterator->child_add($xi);
my $xi1 = new NaElement('volume-attributes');
$xi->child_add($xi1);
my $xi2 = new NaElement('volume-id-attributes');
$xi1->child_add($xi2);
$xi2->child_add_string('name','<name>');

# get volume space attributes
my $xi3 = new NaElement('volume-space-attributes');
$xi1->child_add($xi3);

# get vol size used in percent, bytes, usable in bytes; reserved/used for snapshots in bytes, percent; 
$xi3->child_add_string('percentage-size-used','<percentage-size-used>');
$xi3->child_add_string('size-used', '<size-used>');
$xi3->child_add_string('size-total', '<size-total>');
$xi3->child_add_string('snapshot-reserve-size', '<snapshot-reserve-size>');
$xi3->child_add_string('size-used-by-snapshots', '<size-used-by-snapshots>');
$xi3->child_add_string('percentage-snapshot-reserve-used', '<percentage-snapshot-reserve-used>');

my $xi13 = new NaElement('volume-inode-attributes');
$xi1->child_add($xi13);

# get total, used inodes
$xi13->child_add_string('files-total','<files-total>');
$xi13->child_add_string('files-used','<files-used>');

# get autosize maximum size
my $xi14 = new NaElement('volume-autosize-attributes');
$xi1->child_add($xi14);
$xi14->child_add_string('maximum-size','<maximum-size>');

# get volume state
my $xi_state = new NaElement('volume-state-attributes');
$xi1->child_add($xi_state);
$xi_state->child_add_string('state','<state>');

# get volume snapshot count
my $xi_snapshot = new NaElement('volume-snapshot-attributes');
$xi1->child_add($xi_snapshot);
$xi_snapshot->child_add_string('snapshot-count','<snapshot-count>');

# query only volumes with given names
my $xi4 = new NaElement('query');
$iterator->child_add($xi4);
my $xi5 = new NaElement('volume-attributes');
$xi4->child_add($xi5);
my $xi6 = new NaElement('volume-id-attributes');
$xi5->child_add($xi6);
if($Volume){
    $xi6->child_add_string('name',$Volume);
}
if($Vserver){
    $xi6->child_add_string('owning-vserver-name',$Vserver);
}

my $next = "";

my (@crit_msg, @warn_msg, @ok_msg);

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
	
	my $volumes = $output->child_get("attributes-list");

	unless($volumes){
		if($Volume) {
			print "Error - No volume matching this name\n";
		} else {
			print "ERROR: no volumes found. Please check connections to the cluster.\n";
		}
		last;
	}
	
	my @result = $volumes->children_get();
	my $matching_volumes = @result;

    if($Volume && !$Vserver){
	    if($matching_volumes > 1){
	        print "CRITICAL: more than one volume matching this name\n";
	        exit 2;
	    }
	}
	
	foreach my $vol (@result){

		# get basic volume id info
        my $vol_info = $vol->child_get("volume-id-attributes");
        my $vserver_name = $vol_info->child_get_string("owning-vserver-name");
        my $vol_name = "$vserver_name/" . $vol_info->child_get_string("name");

		# check volume status first
		my $vol_state_info = $vol->child_get("volume-state-attributes");

        if($Volume && $Vserver) {
            next if($vserver_name ne $Vserver);
        }

		next if exists $Excludelist{$vol_name};
	
		if ($regexp and $excludeliststr) {
			next if ($vol_name =~ m/$excludeliststr/);
		}


        if (!$vol_state_info) {
            push (@ok_msg, "Volume $vol_name is unknown (mirror volume?).\n");                  
			
			# $h_warn_crit_info->{$vol_name}->{'state'}=$vol_state;
			# $h_warn_crit_info->{$vol_name}->{'space_percent'}="unknown, volume is in unknown state";
			# $h_warn_crit_info->{$vol_name}->{'inode_percent'}="unknown, volume is in unknown state";
			# $h_warn_crit_info->{$vol_name}->{'snap_percent'}="unknown, volume is in unknown state";
			# $h_warn_crit_info->{$vol_name}->{'autosize_percent'}="unknown, volume is in unknown state";

			next;
        } else {
            my $vol_state = $vol_state_info->child_get_string("state");

			if ($vol_state eq $StateCritical){
				my $crit_msg = "Volume $vol_name ";

				$perfdata{$vol_name}{'state'}=$vol_state;
				$crit_msg .= "is $vol_state";
				$h_warn_crit_info->{$vol_name}->{'volume_state_c'} = 1;

				$h_warn_crit_info->{$vol_name}->{'state'}=$vol_state;
				$h_warn_crit_info->{$vol_name}->{'space_percent'}="unknown, volume is offline";
				$h_warn_crit_info->{$vol_name}->{'inode_percent'}="unknown, volume is offline";
				$h_warn_crit_info->{$vol_name}->{'snap_percent'}="unknown, volume is offline";
				$h_warn_crit_info->{$vol_name}->{'autosize_percent'}="unknown, volume is offline";

				if($Volume) {
					push (@crit_msg, "Volume $vol_name is $vol_state");   
				} else {
					$crit_msg .= ".\n";
					push (@crit_msg, "$crit_msg" );
				}

				next;
			} else {
				$h_warn_crit_info->{$vol_name}->{'state'}=$vol_state;
				
				if($Volume) {
					push (@ok_msg, "Volume $vol_name is $vol_state");   
				}
        	}
		}


		# check inode data
		my $inode_info = $vol->child_get("volume-inode-attributes");
	
		if($inode_info){

			my $inode_used = $inode_info->child_get_int("files-used");
			my $inode_total = $inode_info->child_get_int("files-total");
			
			my $inode_percent = sprintf("%.3f", $inode_used/$inode_total*100);


			my $vol_space = $vol->child_get("volume-space-attributes");
			my $percent = $vol_space->child_get_int("percentage-size-used");
			my $snaptotal = $vol_space->child_get_int("snapshot-reserve-size");
			my $snapused = $vol_space->child_get_int("size-used-by-snapshots");
			my $snapusedpct = $vol_space->child_get_int("percentage-snapshot-reserve-used");
			my $sizetotal = $vol_space->child_get_int("size-total");
		
			$perfdata{$vol_name}{'byte_used'}=$vol_space->child_get_int("size-used");
			$perfdata{$vol_name}{'byte_total'}=$sizetotal;
			$perfdata{$vol_name}{'inode_used'}=$inode_used;
			$perfdata{$vol_name}{'inode_total'}=$inode_total;
			$perfdata{$vol_name}{'snap_total'}=$snaptotal;
			$perfdata{$vol_name}{'snap_used'}=$snapused;


			my $space_used = $perfdata{$vol_name}{'byte_used'}/1073741824;
			my $space_total = $perfdata{$vol_name}{'byte_total'}/1073741824;

			
			# get autosize data for volume
			my $vol_autogrow_info = $vol->child_get("volume-autosize-attributes");
			my($autogrow_percent,$autogrow_bytes);

			if($vol_autogrow_info) {
				$autogrow_bytes = $vol_autogrow_info->child_get_string("maximum-size") / 1073741824;
				$autogrow_percent = $space_used / $autogrow_bytes * 100;
				$autogrow_percent = sprintf("%.0f",$autogrow_percent);

				$perfdata{$vol_name}{'autosize_grow'}=$autogrow_percent;
			} else {
				print "INFO: $vol_name no autosize info could be retrieved \n";
			}

			# get snapshot count for volume
			my $vol_snapshot_info = $vol->child_get("volume-snapshot-attributes");
			my $snapshot_count = $vol_snapshot_info->child_get_string("snapshot-count");

			if($space_used >1024){
				$space_used /= 1024;
				$space_total /= 1024;
				$autogrow_bytes /= 1024;
				
				$space_used = sprintf("%.2f TB", $space_used);
				$space_total = sprintf("%.2f TB", $space_total);
				$autogrow_bytes = sprintf("%.2f TB", $autogrow_bytes);
			} else {
				$space_used = sprintf("%.2f GB", $space_used);
				$space_total = sprintf("%.2f GB", $space_total);
				$autogrow_bytes = sprintf("%.2f GB", $autogrow_bytes);
			}

			if(($percent>$SizeCritical) || ($inode_percent>$InodeCritical) || (($SnapIgnore eq "false") && ($snapusedpct > $SnapCritical)) || ($autogrow_percent > $AutosizeCritical)) {

				$h_warn_crit_info->{$vol_name}->{'space_percent'}=$percent;
				$h_warn_crit_info->{$vol_name}->{'inode_percent'}=$inode_percent;
				$h_warn_crit_info->{$vol_name}->{'snap_percent'}=$snapusedpct;
				$h_warn_crit_info->{$vol_name}->{'autosize_percent'}=$autogrow_percent;

				my $crit_msg = "$vol_name (";

				if ($percent>$SizeCritical){
					$crit_msg .= "Size: $space_used/$space_total, $percent%[>$SizeCritical%], ";
					$h_warn_crit_info->{$vol_name}->{'space_percent_c'} = 1;
				} elsif ($percent>$SizeWarning){
					$crit_msg .= "Size: $space_used/$space_total, $percent%[>$SizeWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'space_percent_w'} = 1;
				}

				if ($inode_percent>$InodeCritical){
					$crit_msg .= "Inodes: $inode_percent%[>$InodeCritical%], ";
					$h_warn_crit_info->{$vol_name}->{'inode_percent_c'} = 1;
				} elsif ($inode_percent>$InodeWarning){
					$crit_msg .= "Inodes: $inode_percent%[>$InodeWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'inode_percent_w'} = 1;
				}

				if ($snapusedpct > $SnapCritical){
					$crit_msg .= "Snapreserve: $snapusedpct%[>$SnapCritical%], ";
					$h_warn_crit_info->{$vol_name}->{'snap_percent_c'} = 1;
				} elsif ($snapusedpct > $SnapWarning){
					$warn_msg .= "Snapreserve: $snapusedpct%[>$SnapWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'snap_percent_w'} = 1;
				}

				if ($autogrow_percent > $AutosizeCritical) {
					$crit_msg .= "Autosize: $space_total/$autogrow_bytes, $autogrow_percent%[>$AutosizeCritical%], ";
					$h_warn_crit_info->{$vol_name}->{'autosize_percent_c'} = 1;
				} elsif ($autogrow_percent > $AutosizeWarning) {
					$crit_msg .= "Autosize: $space_used/$autogrow_bytes, $autogrow_percent%[>$AutosizeWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'autosize_percent_w'} = 1;
				}

				chop($crit_msg); chop($crit_msg); $crit_msg .= ")";
				push (@crit_msg, "$crit_msg\n" );

			} elsif (($percent>$SizeWarning) || ($inode_percent>$InodeWarning) || (($SnapIgnore eq "false") && ($snapusedpct > $SnapWarning)) || ($autogrow_percent > $AutosizeWarning) || ($snapshot_count > $SnapshotLimit)) {

				$h_warn_crit_info->{$vol_name}->{'space_percent'}=$percent;
				$h_warn_crit_info->{$vol_name}->{'inode_percent'}=$inode_percent;
				$h_warn_crit_info->{$vol_name}->{'snap_percent'}=$snapusedpct;
				$h_warn_crit_info->{$vol_name}->{'autosize_percent'}=$autogrow_percent;

				my $warn_msg = "$vol_name (";

				if ($percent > $SizeWarning){
					$warn_msg .= "Size: $space_used/$space_total, $percent%[>$SizeWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'space_percent_w'} = 1;
				}
				if ($inode_percent > $InodeWarning){
					$warn_msg .= "Inodes: $inode_percent%[>$InodeWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'inode_percent_w'} = 1;
				}
				if ($snapusedpct > $SnapWarning){
					$warn_msg .= "Snapreserve: $snapusedpct%[>$SnapWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'snap_percent_w'} = 1;
				}
				if ($autogrow_percent > $AutosizeWarning) {
					$warn_msg .= "Autosize: $space_used/$autogrow_bytes, $autogrow_percent%[>$AutosizeWarning%], ";
					$h_warn_crit_info->{$vol_name}->{'autosize_percent_w'} = 1;
				}
				if ($snapshot_count > $SnapshotLimit) {
					$warn_msg .= "Snapshots: $snapshot_count [>$SnapshotLimit], ";
					#$h_warn_crit_info->{$vol_name}->{'autosize_percent_c'} = 1;
				}

				chop($warn_msg); chop($warn_msg); $warn_msg .= ")";
				push (@warn_msg, "$warn_msg\n" );

			} else {
				if ($SnapIgnore eq "true"){
					push (@ok_msg, "$vol_name (Size: $space_used/$space_total, $percent%, Inodes: $inode_percent%, Maximum Autosize Grow: $autogrow_percent%)\n" );
				} else {
					push (@ok_msg, "$vol_name (Size: $space_used/$space_total, $percent%, Inodes: $inode_percent%, Snapreserve: $snapusedpct%, Maximum Autosize Grow: $autogrow_percent%), Snapshots: $snapshot_count\n" );
				}
			}

			$volume_count++;
	    } 
	}
	$next = $output->child_get_string("next-tag");
}

# Build perf data string for output
my $perfdataglobalstr=sprintf("Volume_count::check_cdot_volume_count::count=%d;;;0;;", $volume_count);
my $perfdatavolstr="";
foreach my $vol ( keys(%perfdata) ) {
    # DS[1] - Data space used
	if( $perfdata{$vol}{'byte_total'} ) {
		$perfdatavolstr.=sprintf(" Vol_%s::check_cdot_volume_usage::space_used=%dB;%d;%d;%d;%d", $vol, $perfdata{$vol}{'byte_used'},
		$SizeWarning*$perfdata{$vol}{'byte_total'}/100, $SizeCritical*$perfdata{$vol}{'byte_total'}/100,
		0, $perfdata{$vol}{'byte_total'} );
	}
    # DS[2] - Inodes used
	if( $perfdata{$vol}{'inode_total'} ) {
		$perfdatavolstr.=sprintf(" inode_used=%d;%d;%d;%d;%d", $perfdata{$vol}{'inode_used'},
		$InodeWarning*$perfdata{$vol}{'inode_total'}/100, $InodeCritical*$perfdata{$vol}{'inode_total'}/100,
		0, $perfdata{$vol}{'inode_total'} );
	}
    # DS[3] - Snapshot space used
	if( $perfdata{$vol}{'snap_total'} ) {
		$perfdatavolstr.=sprintf(" snap_used=%dB;%d;%d;%d;%d", $perfdata{$vol}{'snap_used'},
		$SnapWarning*$perfdata{$vol}{'snap_total'}/100, $SnapCritical*$perfdata{$vol}{'snap_total'}/100,
		0, $perfdata{$vol}{'snap_total'} );
	}
    # DS[4] - Data total space
	if( $perfdata{$vol}{'byte_total'} ) {
   		$perfdatavolstr.=sprintf(" data_total=%dB", $perfdata{$vol}{'byte_total'} );
	}
    # DS[5] - Snap total space
	if( $perfdata{$vol}{'snap_total'} ) {
    	$perfdatavolstr.=sprintf(" snap_total=%dB", $perfdata{$vol}{'snap_total'} );
	}
    # DS[6] - Maximum Autosize Threshold
	if( $perfdata{$vol}{'autosize_grow'} ) {
    	$perfdatavolstr.=sprintf(" autosize_grow=%d", $perfdata{$vol}{'autosize_grow'} );
	}
	# DS[7] - Volume state
	if( $perfdata{$vol}{'state'} ) {
		$perfdatavolstr.=sprintf(" state=%s", $perfdata{$vol}{'state'} );
	}
	# DS[8] - Volume snapshot count
	if( $perfdata{$vol}{'snapshot_count'} ) {
		$perfdatavolstr.=sprintf(" state=%s", $perfdata{$vol}{'snapshot_count'} );
	}
}
$perfdatavolstr =~ s/^\s+//;
my $perfdataallstr = "$perfdataglobalstr $perfdatavolstr";

# Version output
print "Script version: $version\n";

if(scalar(@crit_msg) ){
    print "CRITICAL:\n";
    print join ("", @crit_msg);
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
	#print Dumper($h_warn_crit_info);
	# my $strHTML = draw_html_table($h_warn_crit_info);
    # print $strHTML if $output_html; 
	exit 2;
# } elsif(scalar(@warn_msg) ){
} if(scalar(@warn_msg) ){
    print "WARNING:\n";
    print join ("", @warn_msg);
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
# } elsif(scalar(@ok_msg) ){
} if(scalar(@ok_msg) ){
    print "OK:\n";
    print join ("", @ok_msg);
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
    print "WARNING: no online volume found\n";
    exit 1;
}

__END__

=encoding utf8

=head1 NAME

check_cdot_volume - Check Volume Usage

=head1 SYNOPSIS

check_cdot_aggr.pl -H HOSTNAME -u USERNAME -p PASSWORD \
           -w PERCENT_WARNING -c PERCENT_CRITICAL \
	       --snap-warning PERCENT_WARNING \
	       --snap-critical PERCENT_CRITICAL \
	       --inode-warning PERCENT_WARNING \
           --inode-critical PERCENT_CRITICAL \
	       --autosize-warning PERCENT_WARNING \
           --autosize-critical PERCENT_CRITICAL \
		   --state-critical STATE_CRITICAL \
           [--perfdatadir DIR] [--perfdataservicedesc SERVICE-DESC] \
		   [--hostdisplay HOSTDISPLAY] [--vserver VSERVER-NAME] \
		   [--snap-ignore] [-V VOLUME] [-P]

=head1 DESCRIPTION

Checks the Volume Space, Inode Usage and Autosize Grow Maximum of the NetApp System and warns
if warning or critical Thresholds are reached

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item --size-warning PERCENT_WARNING

The Warning threshold for data space usage.

=item --size-critical PERCENT_CRITICAL

The Critical threshold for data space usage.

=item --inode-warning PERCENT_WARNING

The Warning threshold for inodes (files). Defaults to 65% if not given.

=item --inode-critical PERCENT_CRITICAL

The Critical threshold for inodes (files). Defaults to 85% if not given.

=item --snap-warning PERCENT_WARNING

The Warning threshold for snapshot space usage. Defaults to 75%.

=item --snap-critical PERCENT_CRITICAL

The Critical threshold for snapshot space usage. Defaults to 90%.

=item --autosize-warning PERCENT_WARNING

The Warning threshold for autosize grow maximum. Defaults to 75%.

=item --autosize-critical PERCENT_CRITICAL

The Critical threshold for autosize grow maximum. Defaults to 90%.

=item --state-critical STATE_CRITICAL

The Critical threshold for volume status. Default is "offline".

=item --snapshot-limit SNAPSHOT_LIMIT

The threshold for volume snapshot counts. Default is 230.

=item -V | --volume VOLUME

Optional: The name of the Volume to check

=item --vserver VSERVER-NAME

Name of the destination vserver to be checked. If not specificed, search only the base server.

=item --snap-ignore

Optional: Disable snapshot usage check

=item -P | --perf

Flag for performance data output

=item --exclude

Optional: The name of a volume that has to be excluded from the checks (multiple exclude item for multiple volumes)

=item --regexp

Optional: Uses the input in "exclude" parameter as a regex filter for volume names. A value must not be set.

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
 Stefan Grosser <sgr at firstframe.net>
 Therese Ho <thereseh at netapp.com>
