#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_aggr - Check Aggregate State
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
use Data::Dumper;

# High resolution alarm, sleep, gettimeofday, interval timers
use Time::HiRes qw();

my $STARTTIME_HR = Time::HiRes::time();           # time of program start, high res
my $STARTTIME    = sprintf("%.0f",$STARTTIME_HR); # time of program start

GetOptions(
    'H|hostname=s' => \my $Hostname,
    'u|username=s' => \my $Username,
    'p|password=s' => \my $Password,
    'state-critical=s' => \my $StateCritical,
    'A|aggr=s'     => \my $Aggr,
    'P|perf'       => \my $perf,
    'exclude=s'  => \my @excludelistarray,
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
$StateCritical = "offline" unless $StateCritical;

my ($crit_msg, $warn_msg, $ok_msg);

my %perfdata=();
my $h_warn_crit_info={};
my $aggr_count = 0;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

# if more than max aggr are read
my $iterator = NaElement->new("aggr-get-iter");
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

# get all aggr names
my $xi = new NaElement('desired-attributes');
$iterator->child_add($xi);
my $xi1 = new NaElement('aggr-attributes');
$xi->child_add($xi1);
$xi1->child_add_string('aggregate-name','<aggregate-name>');

# get aggr state
my $xi_state = new NaElement('aggr-raid-attributes');
$xi1->child_add($xi_state);
$xi_state->child_add_string('state','<state>');

my $xi3 = new NaElement('query');
$iterator->child_add($xi3);
my $xi4 = new NaElement('aggr-attributes');
$xi3->child_add($xi4);
if($Aggr){
    $xi4->child_add_string('aggregate-name',$Aggr);
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

    my $aggrs = $output->child_get("attributes-list");

    	unless($aggrs){
            print "CRITICAL: no aggregate matching this name\n";
            exit 2;
	    }

    my @result = $aggrs->children_get();

    foreach my $aggr (@result){

        my $aggr_name = $aggr->child_get_string("aggregate-name");
        my $aggr_info = $aggr->child_get("aggr-raid-attributes");
        my $aggr_state = $aggr_info->child_get_string("state");

    	# exclude root aggregates
        unless($aggr_name =~ m/^aggr0_/){

            next if exists $Excludelist{$aggr_name};

            if ($regexp and $excludeliststr) {
                if ($aggr_name =~ m/$excludeliststr/) {
                    next;
                }
            }

            if($aggr_state eq $StateCritical) {

                my $crit_msg = "Aggregate $aggr_name ";

                $perfdata{$aggr_name}{'aggr_state'}=$aggr_state;
                $crit_msg .= "is $aggr_state";
                #$h_warn_crit_info->{$vol_name}->{'volume_state_c'} = 1;
                #$h_warn_crit_info->{$vol_name}->{'volume_state'}=$vol_state;
                
                $crit_msg .= ". ";
                push (@crit_msg, "$crit_msg" );
            } elsif ($aggr_state ne "online"){
                my $warn_msg = "Aggregate $aggr_name ";

                $perfdata{$aggr_name}{'aggr_state'}=$aggr_state;
                $warn_msg .= "is $aggr_state";
                #$h_warn_crit_info->{$vol_name}->{'volume_state_c'} = 1;
                #$h_warn_crit_info->{$vol_name}->{'volume_state'}=$vol_state;
                
                $warn_msg .= ".";
                push (@warn_msg, "$warn_msg" );
            } else {
                #$h_warn_crit_info->{$aggr_name}->{'volume_state'}=$aggr_state;
                # Build ok string once
                if($Aggr) {
                    push (@ok_msg, "Aggregate $aggr_name is $aggr_state");   
                }
                elsif(!@ok_msg) {
                    push (@ok_msg, "All aggregates are $aggr_state");                    
                }
            }
        }
        
        $aggr_count++;
    }
    $next = $output->child_get_string("next-tag");
}

# Build perf data string for output
my $perfdataglobalstr=sprintf("Aggregate_count::check_cdot_aggr_count::count=%d;;;0;;", $aggr_count);
my $perfdataaggrstr="";
foreach my $aggregate ( keys(%perfdata) ) {
	# DS[1] - Volume state
	if( $perfdata{$aggregate}{'aggr_state'} ) {
		$perfdataaggrstr.=sprintf(" aggr_state=%s", $perfdata{$aggregate}{'aggr_state'} );
	}
}

$perfdataaggrstr =~ s/^\s+//;
my $perfdataallstr = "$perfdataglobalstr $perfdataaggrstr";

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
	#my $strHTML = draw_html_table($h_warn_crit_info);
    #print $strHTML if $output_html; 
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
    print "WARNING: no online aggregate found\n";
    exit 1;
}

__END__

=encoding utf8

=head1 NAME

check_cdot_aggr - Check Aggregate state

=head1 SYNOPSIS

check_cdot_aggr.pl -H HOSTNAME -u USERNAME \
           -p PASSWORD --state-critical STATE_CRITICAL \
           [-A|aggr AGGREGATE] [--exclude] \
           [--perf|-P] [--perfdatadir DIR] \
           [--perfdataservicedesc SERVICE-DESC] [--hostdisplay HOSTDISPLAY] 

=head1 DESCRIPTION

Checks the Aggregate state of the NetApp System and warns
if warning or critical Thresholds are reached

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item --state-critical STATE_CRITICAL

The Critical threshold state. Possible values are:
"creating"|"destroying"|"failed"|"frozen"|"inconsistent"|"iron_restricted"|"mounting"|"online"|
"offline"|"partial"|"quiesced"|"quiescing"|"restricted"|"reverted"|"unknown"|"unmounted"|"unmounting"|"relocating"

=item -P | --perf

Flag for performance data output

=item -A | --aggr

Check only specific aggregate

=item --exclude

Optional: The name of an aggregate that has to be excluded from the checks (multiple exclude item for multiple aggregates)

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
1 if Warning Threshold has been reached
0 if everything is ok

=head1 AUTHORS

 Alexander Krogloth <git at krogloth.de>
 Stelios Gikas <sgikas at demokrit.de>
 Stefan Grosser <sgr at firstframe.net>
 Stephan Lang <stephan.lang at acp.at>
 Therese Ho <thereseh at netapp.com>

