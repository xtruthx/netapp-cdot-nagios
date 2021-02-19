#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot$svm - Check$svm State
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

# html output containing the$svms and their status
# _c = warning in yellow
# rest = safe in green
sub draw_html_table {
	my ($hrefInfo) = @_;
	my @headers = qw(vserver state);
	# define columns that will be filled and shown
	my @columns = qw(svm_state);
	my $html_table="";
	$html_table .= "<table class=\"common-table\" style=\"border-collapse:collapse; border: 1px solid black;\">";
	$html_table .= "<tr>";
	foreach (@headers) {
		$html_table .= "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$_."</th>";
	}
	$html_table .= "</tr>";
	foreach my $svm (sort {lc $a cmp lc $b} keys %$hrefInfo) {
		$html_table .= "<tr>";
		$html_table .= "<tr style=\"border: 1px solid black;\">";
		$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #acacac;\">".$svm."</td>";
		# loop through all attributes defined in @columns
		foreach my $attr (@columns) {
			if ($attr eq "svm_state") {
                if (defined $hrefInfo->{$svm}->{"svm_state_c"}){
					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$svm}->{$attr}."</td>";
				} elsif (defined $hrefInfo->{$svm}->{"svm_state_w"}){
                    $html_table .= "<td class=\"state-warning\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #FFFF00\">".$hrefInfo->{$svm}->{$attr}."</td>";
				} else {
					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$svm}->{$attr}."</td>";
				}
			} else {
				$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$hrefInfo->{$svm}->{$attr}."</td>";
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
    my $filename = $s_perfdatadir . "/check_cdot_svmstat.$s_starttime";
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
$StateCritical = "stopped" unless $StateCritical;

my ($crit_msg, $warn_msg, $ok_msg);
# Store all perf data points for output at end
my %perfdata=();
my $h_warn_crit_info={};
my $svm_count = 0;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

# if more than max svms are read
my $iterator = NaElement->new("vserver-get-iter");
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

# get all svm names
my $xi = new NaElement('desired-attributes');
$iterator->child_add($xi);
my $xi1 = new NaElement('vserver-info');
$xi->child_add($xi1);
$xi1->child_add_string('vserver-name','<name>');

# get svm state
$xi1->child_add_string('state','<state>');

# get svm type
$xi1->child_add_string('vserver-type','<type>');

my $xi4 = new NaElement('query');
$iterator->child_add($xi4);
my $xi5 = new NaElement('vserver-info');
$xi4->child_add($xi5);

if($Vserver){
    $xi5->child_add_string('vserver-name',$Vserver);
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
	
	my $svms = $output->child_get("attributes-list");

	unless($svms){
	    print "CRITICAL: no svm matching this name\n";
	    exit 2;
	}
	
	my @result = $svms->children_get();

	foreach my $svm (@result){

        my $svm_name = $svm->child_get_string("vserver-name");
        my $svm_type = $svm->child_get_string("vserver-type");

        next if $svm_type ne "data";

		my $svm_state = $svm->child_get_string("state");

        # if svm should be excluded from check, ignore and next
        next if exists $Excludelist{$svm_name};
        
        if ($regexp and $excludeliststr) {
            if ($svm_name =~ m/$excludeliststr/) {
                next;
            }
        }

        # if svm is stopped, set it to critical
		if ($svm_state eq $StateCritical){

			my $crit_msg = "SVM $svm_name ";

			$perfdata{$svm_name}{'svm_state'}=$svm_state;
			$crit_msg .= "is $svm_state";

			$h_warn_crit_info->{$svm_name}->{'svm_state_c'} = 1;
			$h_warn_crit_info->{$svm_name}->{'svm_state'}=$svm_state;
			
			$crit_msg .= ".";
			push (@crit_msg, "$crit_msg" );
        } elsif ($svm_state ne "running") {
            
            my $warn_msg = "SVM $svm_name ";

			$perfdata{$svm_name}{'svm_state'}=$svm_state;
			$warn_msg .= "is $svm_state";

			$h_warn_crit_info->{$svm_name}->{'svm_state_w'} = 1;
			$h_warn_crit_info->{$svm_name}->{'svm_state'}=$svm_state;
			
			$warn_msg .= ")";
			push (@warn_msg, "$warn_msg" );
        } else {
            $h_warn_crit_info->{$svm_name}->{'svm_state'}=$svm_state;
            # Build ok string once
            if($Vserver) {
                push (@ok_msg, "SVM $svm_name is $svm_state. ");   
            }
            elsif(!@ok_msg) {
                push (@ok_msg, "All SVMs are $svm_state.");                    
            }
        }

		$svm_count++;
	}
	$next = $output->child_get_string("next-tag");
}



# Build perf data string for output
my $perfdataglobalstr=sprintf("svm_count::check_cdot_svm_count::count=%d;;;0;;", $svm_count);
my $perfdatavolstr="";
foreach my $svm ( keys(%perfdata) ) {
	# DS[1] -$svm state
	if( $perfdata{$svm}{'svm_state'} ) {
		$perfdatavolstr.=sprintf(" svm_state=%s", $perfdata{$svm}{'svm_state'} );
	}
}

$perfdatavolstr =~ s/^\s+//;
my $perfdataallstr = "$perfdataglobalstr $perfdatavolstr";

if(scalar(@crit_msg) ){
    print "CRITICAL: ";
    print join (" ", @crit_msg, @warn_msg);
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
    print "WARNING: no running SVM found\n";
    exit 1;
}

__END__

=encoding utf8

=head1 NAME

check_cdot$svm - Check$svm state

=head1 SYNOPSIS

check_cdot_aggr.pl -H HOSTNAME -u USERNAME -p PASSWORD \
           -w PERCENT_WARNING -c PERCENT_CRITICAL \
           --state-critical STATE_CRITICAL \
           [--perfdatadir DIR] [--perfdataservicedesc SERVICE-DESC] \
		   [--hostdisplay HOSTDISPLAY] [--vserver VSERVER-NAME] \
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

=item --state-warning STATE_WARNING

The Warning threshold state.

=item --vserver VSERVER-NAME

Name of the destination vserver to be checked. If not specificed, search only the base server.

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
