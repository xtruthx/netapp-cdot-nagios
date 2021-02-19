#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_volume - Check Volume State
# Copyright (C) 2018 operational services GmbH & Co. KG
# Copyright (C) 2013 noris network AG, http://www.noris.net/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

use strict;
use warnings;
use Data::Dumper;

use lib "/usr/lib/netapp-manageability-sdk/lib/perl/NetApp";

use NaServer;
use NaElement;
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
	'state-critical=s' => \my $StateCritical,
    'P|perf'     => \my $perf,
    'v|volume-name=s'   => \my $Volume,
    'vserver=s'  => \my $Vserver,
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

# html output containing the volumes and their status
# _c = critical in red
# rest = safe in green
sub draw_html_table {
	my ($hrefInfo) = @_;
	my @headers = qw(volume state);
	# define columns that will be filled and shown
	my @columns = qw(volume_state);
	my $html_table="";
	$html_table .= "<table class=\"common-table\" style=\"border-collapse:collapse; border: 1px solid black;\">";
	$html_table .= "<tr>";
	foreach (@headers) {
		$html_table .= "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$_."</th>";
	}
	$html_table .= "</tr>";
	foreach my $volume (sort {lc $a cmp lc $b} keys %$hrefInfo) {
		$html_table .= "<tr>";
		$html_table .= "<tr style=\"border: 1px solid black;\">";
		$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #acacac;\">".$volume."</td>";
		# loop through all attributes defined in @columns
		foreach my $attr (@columns) {
			if ($attr eq "volume_state") {
				if (defined $hrefInfo->{$volume}->{"volume_state_c"}){
					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$volume}->{$attr}."</td>";
				} else {
					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$volume}->{$attr}."</td>";
				}
			} else {
				$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$hrefInfo->{$volume}->{$attr}."</td>";
			}
		}
		$html_table .= "</tr>";
	}
	$html_table .= "</table>\n";

	return $html_table;
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
    my $filename = $s_perfdatadir . "/check_cdot_volumestat.$s_starttime";
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
$StateCritical = "offline" unless $StateCritical;

my ($crit_msg, $warn_msg, $ok_msg);
# Store all perf data points for output at end
my %perfdata=();
my $h_warn_crit_info={};
my $volume_count = 0;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

# if more than max volumes are read
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

# get volume state
my $xi_state = new NaElement('volume-state-attributes');
$xi1->child_add($xi_state);
$xi_state->child_add_string('state','<state>');

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

# ?
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
	    print "CRITICAL: no volume matching this name\n";
	    exit 2;
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

        my $vol_info = $vol->child_get("volume-id-attributes");
        if (!$vol_info) { print Dumper($vol_info); }
        
        my $vserver_name = $vol_info->child_get_string("owning-vserver-name");
        if (!$vserver_name) { print Dumper($vserver_name); }

        my $vol_name = "$vserver_name/" . $vol_info->child_get_string("name");
        if (!$vol_name) { print Dumper($vol_name); }

		my $vol_state_info = $vol->child_get("volume-state-attributes");

        my $vol_state;

        if (!$vol_state_info) {
            $h_warn_crit_info->{$vol_name}->{'volume_state'}="unknown";

            if($Volume) {
                push (@ok_msg, "Volume $vol_name is offline.");   
            } else {
                push (@ok_msg, "Volume $vol_name is offline (mirror volume?).\n");                  
            }

            $vol_state = "unknown";
        } else {
            $vol_state = $vol_state_info->child_get_string("state");
            if (!$vol_state) { print Dumper($vol_state); }
        }



        if($Volume && $Vserver) {
            if($vserver_name ne $Vserver) {
                next;
            }
        }

        # if Volume should be excluded from check, ignore and next
        next if exists $Excludelist{$vol_name};
        my $excludemore = "sdw_cl_";
        
        if ($regexp and $excludeliststr) {
            if ($vol_name =~ m/$excludeliststr/ || $vol_name =~ m/$excludemore/) {
                next;
            }
        }

        # if volume is offline, only set it as critical for being offline
		if ($vol_state eq $StateCritical){

			my $crit_msg = "Volume $vol_name ";

			$perfdata{$vol_name}{'volume_state'}=$vol_state;
			$crit_msg .= "is $vol_state";
			$h_warn_crit_info->{$vol_name}->{'volume_state_c'} = 1;

			$h_warn_crit_info->{$vol_name}->{'volume_state'}=$vol_state;
			
			$crit_msg .= ".\n";
			push (@crit_msg, "$crit_msg" );
		} else {
            $h_warn_crit_info->{$vol_name}->{'volume_state'}=$vol_state;
            # Build ok string once
            if($Volume) {
                push (@ok_msg, "Volume $vol_name is $vol_state");   
            }
            elsif(!@ok_msg) {
                push (@ok_msg, "All volumes are $vol_state\n");                    
            }
        }

		$volume_count++;
	}
	$next = $output->child_get_string("next-tag");
}


# Build perf data string for output
my $perfdataglobalstr=sprintf("Volume_count::check_cdot_volume_count::count=%d;;;0;;", $volume_count);
my $perfdatavolstr="";
foreach my $vol ( keys(%perfdata) ) {
	# DS[1] - Volume state
	if( $perfdata{$vol}{'volume_state'} ) {
		$perfdatavolstr.=sprintf(" volume_state=%s", $perfdata{$vol}{'volume_state'} );
	}
}

$perfdatavolstr =~ s/^\s+//;
my $perfdataallstr = "$perfdataglobalstr $perfdatavolstr";

if(scalar(@crit_msg) ){
    print "CRITICAL:\n";
    print join ("", @crit_msg, @warn_msg);
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
	my $strHTML = draw_html_table($h_warn_crit_info);
    print $strHTML if $output_html; 
	exit 2;
} elsif(scalar(@warn_msg) ){
    print "WARNING: ";
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
    my $strHTML = draw_html_table($h_warn_crit_info);
    print $strHTML if $output_html;
	exit 1;
} elsif(scalar(@ok_msg) ){
    print "OK: ";
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

check_cdot_volume - Check Volume state

=head1 SYNOPSIS

check_cdot_aggr.pl -H HOSTNAME -u USERNAME -p PASSWORD \
           -w PERCENT_WARNING -c PERCENT_CRITICAL \
           --state-critical STATE_CRITICAL \
           [--perfdatadir DIR] [--perfdataservicedesc SERVICE-DESC] \
		   [--hostdisplay HOSTDISPLAY] [--vserver VSERVER-NAME] \
		   [--snap-ignore] [-V|volume-name VOLUME] [-P] \
            [--exclude]

=head1 DESCRIPTION

Checks the Volume State of the NetApp System and warns if critical Thresholds are reached

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item --state-critical STATE_CRITICAL

The Critical threshold state.

=item -V | --volume-name VOLUME

Optional: The name of the Volume to check

=item --vserver VSERVER-NAME

Name of the destination vserver to be checked. If not specificed, search only the base server.

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
 Stefan Grosser <sgr at firstframe.net>
 Therese Ho <thereseh at netapp.com>
