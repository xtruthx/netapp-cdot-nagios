#!/usr/bin/perl


# nagios: -epn
# --
# check_cdot_lun - Check LUN State
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
	'state-not-warning=s' => \my $StateNotWarning,
    'P|perf'     => \my $perf,
    'v|volume-name=s'   => \my $Volume,
    'vserver=s'  => \my $Vserver,
    'l|lun-path=s' => \my $Lunpath,
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

# html output containing the luns and their status
# _w = warning in red
# rest = safe in green
sub draw_html_table {
	my ($hrefInfo) = @_;
	my @headers = qw(lun state);
	# define columns that will be filled and shown
	my @columns = qw(lun_state);
	my $html_table="";
	$html_table .= "<table class=\"common-table\" style=\"border-collapse:collapse; border: 1px solid black;\">";
	$html_table .= "<tr>";
	foreach (@headers) {
		$html_table .= "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$_."</th>";
	}
	$html_table .= "</tr>";
	foreach my $lun (sort {lc $a cmp lc $b} keys %$hrefInfo) {
		$html_table .= "<tr>";
		$html_table .= "<tr style=\"border: 1px solid black;\">";
		$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #acacac;\">".$lun."</td>";
		# loop through all attributes defined in @columns
		foreach my $attr (@columns) {
			if ($attr eq "lun_state") {
				if (defined $hrefInfo->{$lun}->{"lun_state_w"}){
					$html_table .= "<td class=\"state-warning\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #FFFF00\">".$hrefInfo->{$lun}->{$attr}."</td>";
				} else {
					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$lun}->{$attr}."</td>";
				}
			} else {
				$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$hrefInfo->{$lun}->{$attr}."</td>";
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
    my $filename = $s_perfdatadir . "/check_cdot_lunstat.$s_starttime";
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
$StateNotWarning = "online" unless $StateNotWarning;

my ($warn_msg, $ok_msg);
# Store all perf data points for output at end
my %perfdata=();
my $h_warn_crit_info={};
my $lun_count = 0;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );
$s->set_timeout(30);

# get vserver subtype and check which are mcc destination (subtype != sync_source, operational_state = 'stopped')
my $mcc_target_check = NaElement->new("vserver-get-iter");

my $xo = new NaElement("desired-attributes");
$mcc_target_check->child_add($xo);
my $desired_attributes = new NaElement("vserver-info");
$xo->child_add($desired_attributes);
$desired_attributes->child_add_string("vserver-name",'<vserver-name>');
$desired_attributes->child_add_string("vserver-type",'<vserver-type>');
$desired_attributes->child_add_string("vserver-subtype",'<vserver-subtype>');
$desired_attributes->child_add_string("operational-state",'<operational-state>');

my $vserver_api_invoke = $s->invoke_elem($mcc_target_check);
my $vservers = $vserver_api_invoke->child_get("attributes-list");
my @result = $vservers->children_get();

my @svm_whitelist;

foreach my $svm (@result){
    my $vserver_name = $svm->child_get_string("vserver-name");
    my $vserver_type = $svm->child_get_string("vserver-type");

    if ($vserver_type eq 'data') {
        my $vserver_state = $svm->child_get_string("operational-state");
        my $vserver_subtype = $svm->child_get_string("vserver-subtype");

        if ($vserver_state eq "running" && $vserver_subtype eq "default") {
            # create a list of all svms that are not metrocluster destinations
            push @svm_whitelist, $vserver_name;
        }
    }
}

# turn array into hash for easier check later
# my %svm_whitelist = map { $_ => 1 } @svm_whitelist;

# if more than max luns are read
my $iterator = NaElement->new("lun-get-iter");
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

# get all lun names
my $xi = new NaElement('desired-attributes');
$iterator->child_add($xi);
my $xi1 = new NaElement('lun-info');
$xi->child_add($xi1);
$xi1->child_add_string('path','<path>');

# get lun state
$xi1->child_add_string('state','<state>');

my $xi4 = new NaElement('query');
$iterator->child_add($xi4);
my $xi5 = new NaElement('lun-info');
if($Lunpath){
    $xi5->child_add_string('path',$Lunpath);
}
if($Volume){
    $xi5->child_add_string('volume',$Volume);
}
if($Vserver){
    $xi5->child_add_string('vserver',$Vserver);
}

my $next = "";

# ?
my (@warn_msg, @ok_msg);

while(defined($next)){
    unless($next eq ""){
        $tag_elem->set_content($next);    
    }

    $iterator->child_add_string("max-records", 50);
    my $output = $s->invoke_elem($iterator);

	if ($output->results_errno != 0) {
	    my $r = $output->results_reason();
	    print "UNKNOWN: $r\n";
	    exit 3;
	}
	
	my $luns = $output->child_get("attributes-list");

	unless($luns){
	    print "INFO: no lun matching this name\n";
	    exit 0;
	}
	
	my @result = $luns->children_get();
	my $matching_luns = @result;

    if($Lunpath && !$Volume && !$Vserver){
	    if($matching_luns > 1){
	        print "CRITICAL: more than one lun matching this path\n";
	        exit 2;
	    }
	}

	
	foreach my $lun (@result){

        my $vserver_name = $lun->child_get_string("vserver");
        my $vol_name = $lun->child_get_string("volume");
        my $lun_path = $lun->child_get_string("path");
		my $lun_state = $lun->child_get_string("state");

        if($Lunpath && $Volume && $Vserver) {
            if($vserver_name ne $Vserver) {
                next;
            }
            if($vol_name ne $Volume) {
                next;
            }
        }

        # if LUN should be excluded from check, ignore and next
        next if ( grep( /^$vserver_name$/, @svm_whitelist) );
        
        if ($regexp and $excludeliststr) {
            if ($lun_path =~ m/$excludeliststr/) {
                next;
            }
        }

        # if lun is not online, set state to critical
		if ($lun_state ne $StateNotWarning){

			my $warn_msg = "LUN $lun_path ";

			$perfdata{$lun_path}{'lun_state'}=$lun_state;
			$warn_msg .= "is $lun_state";
			$h_warn_crit_info->{$lun_path}->{'lun_state_w'} = 1;
			$h_warn_crit_info->{$lun_path}->{'lun_state'}=$lun_state;
			
			$warn_msg .= ". ";
			push (@warn_msg, "$warn_msg" );
		} else {
            # lun is online, set state to ok
            $h_warn_crit_info->{$lun_path}->{'lun_state'}=$lun_state;
            # Build ok string once
            if($Lunpath) {
                push (@ok_msg, "LUN $lun_path is $lun_state.");   
            }
            elsif(!@ok_msg) {
                push (@ok_msg, "All LUNs are $lun_state.");                    
            }
        }

		$lun_count++;
	}
	$next = $output->child_get_string("next-tag");
}



# Build perf data string for output
my $perfdataglobalstr=sprintf("Lun_count::check_cdot_lun_count::count=%d;;;0;;", $lun_count);
my $perfdatalunstr="";
foreach my $lun ( keys(%perfdata) ) {
	# DS[1] - Volume state
	if( $perfdata{$lun}{'lun_state'} ) {
		$perfdatalunstr.=sprintf(" lun_state=%s", $perfdata{$lun}{'lun_state'} );
	}
}

$perfdatalunstr =~ s/^\s+//;
my $perfdataallstr = "$perfdataglobalstr $perfdatalunstr";

if(scalar(@warn_msg) ){
    print "WARNING: ";
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
    my $strHTML = draw_html_table($h_warn_crit_info);
    print $strHTML if $output_html;
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
    print "OK: 0 online lun found\n";
    exit 1;
}

__END__

=encoding utf8

=head1 NAME

check_cdot_lunstat - Check LUN state

=head1 SYNOPSIS

check_cdot_lunstat.pl -H HOSTNAME -u USERNAME -p PASSWORD \
           --state-non-critical STATE_NON_CRITICAL \
           [--perfdatadir DIR] [--perfdataservicedesc SERVICE-DESC] \
		   [--hostdisplay HOSTDISPLAY] [--vserver VSERVER-NAME] \
		   [--snap-ignore] [-V|volume-name VOLUME] [-P] \
           [--lun-path LUN] [--exclude]

=head1 DESCRIPTION

Checks the LUN State of the NetApp System and warns if critical Thresholds are reached

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item --state-non-critical STATE_NON_CRITICAL

The Critical threshold state.

=item -V | --lun-path LUN

Optional: The path of the LUN to check. Syntax must be "/vol/<svm>/lunname".

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

 Therese Ho <thereseh at netapp.com>
