#!/perl/bin/perl

# nagios: -epn
# --
# check_cdot_vserver_peer - Check Vserver peer relationship status
# Copyright (C) 2021 operational services GmbH & Co. KG
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
    'H|hostname=s' => \my $Hostname,
    'u|username=s' => \my $Username,
    'p|password=s' => \my $Password,
    'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'h|help'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my $version = "1.0.2";

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


my (@warn_msg, @ok_msg);
my %failed_names;
my %normal_names;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

my $iterator = NaElement->new("vserver-peer-get-iter");
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

my $next = "";

while(defined($next)){
    unless($next eq ""){
        $tag_elem->set_content($next);
    }
    
    $iterator->child_add_string("max-records", '50');
    
    my $output = $s->invoke_elem($iterator);

    if ($output->results_errno != 0) {
        my $r = $output->results_reason();
        print "UNKNOWN: $r\n";
        exit 3;
    }

    my $vserver_peers = $output->child_get('attributes-list');

    unless($vserver_peers){
        print "OK - No vserver peering found\n";
        exit 0;
    }    

    my @result = $vserver_peers->children_get();

    unless(@result){
        print "OK - No vserver peering found\n";
        exit 0;
    }

    foreach my $peer (@result) {
        my ($warn_msg, $ok_msg);

        my $vserver_name = $peer->child_get_string("vserver");
        my $peer_vserver = $peer->child_get_string("peer-vserver");
        my $peer_state = $peer->child_get_string("peer-state");
        my @applications = $peer->child_get("applications");
        my $peer_cluster = $peer->child_get_string("peer-cluster");
        my $remote_vserver_name = $peer->child_get_string("remote-vserver-name");

        next if exists $Excludelist{$vserver_name};
        next if exists $Excludelist{$peer_vserver};

        if ($regexp and $excludeliststr) {
            if (($vserver_name =~ m/$excludeliststr/) || ($peer_vserver =~ m/$excludeliststr/)) {
                next;
            }
        }

        foreach my $app_list (@applications) {
            my @application_list = $app_list->children_get();
            
            foreach my $app (@application_list) {
                my $application_name = $app->{"content"};
                
                next if $application_name ne "snapmirror";
            
                if($peer_state ne "peered") {
                    $failed_names{$vserver_name} = [ "$peer_cluster:$peer_vserver", $application_name, $peer_state ];
                } else {
                    $normal_names{$vserver_name} = [ "$peer_cluster:$peer_vserver", $application_name, $peer_state ];
                }
            }
        }
    }
    $next = $output->child_get_string("next-tag");
}


# Version output
print "Script version: $version\n\n";

if (keys %failed_names gt 0) {
    my $size = keys %failed_names;
    print "WARNING: $size vserver peering relationships are not peered\n";
    printf ("%-*s%*s%*s%*s\n", 50, "Vserver", 25, "Peer", 15, "Application", 10, "State");
	for my $peering ( keys %failed_names ) {
		my $peer = $failed_names{$peering};
		my @peer_info = @{ $peer };
		printf ("%-*s%*s%*s%*s\n", 50, $peering, 25, $peer_info[0], 15, $peer_info[1], 10, $peer_info[2]);
	}

	exit 1;
} elsif (keys %normal_names gt 0) {
    my $size = keys %normal_names;
    print "OK: $size vserver peering relationships are peered\n";
    printf ("%-*s%*s%*s%*s\n", 50, "Vserver", 25, "Peer", 15, "Application", 10, "State");
	for my $peering ( keys %normal_names ) {
		my $peer = $normal_names{$peering};
		my @peer_info = @{ $peer };
		printf ("%-*s%*s%*s%*s\n", 50, $peering, 25, $peer_info[0], 15, $peer_info[1], 10, $peer_info[2]);
	}
    exit 0;
} else {
    print "WARNING: no peering found\n";
    exit 1;
}

__END__

=encoding utf8

=head1 NAME

check_cdot_vserver_peer - Check Vserver peer relationship status

=head1 SYNOPSIS

check_cdot_vserver_peer.pl -H HOSTNAME -u USERNAME -p PASSWORD \

=head1 DESCRIPTION

Checks if all vserver peer relationships running application "snapmirror" are in status "peered"

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item --exclude

Optional: The name of a vserver that has to be excluded from the checks (multiple exclude item for multiple vservers). Both partners will be checked

=item --regexp

Optional: Enable regexp matching for the exclusion list

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
