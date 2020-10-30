#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_vscan - Check Vscan connectivity
# Copyright (C) 2020 NetApp
# Copyright (C) 2020 Operational Services GmbH
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

GetOptions(
    'H|hostname=s' => \my $Hostname,
    'username=s' => \my $Username,
    'P|password=s' => \my $Password,
    'vserver=s'	 => \my $Vserver,
    'perf'     => \my $perf,
    'excludevserver=s'  =>  \my @excludevserverlistarray,
    'help|?'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my %Excludevserverlist;
@Excludevserverlist{@excludevserverlistarray}=();
my $excludevserverliststr = join "|", @excludevserverlistarray;

my $version = "1.0.2";

sub Error {
    print "$0: " . $_[0] . "\n";
    exit 2;
}
Error('Option --hostname needed!') unless $Hostname;
Error('Option --username needed!') unless $Username;
Error('Option --password needed!') unless $Password;

my (@warn_msg, @ok_msg, $conn_msg, @list);

my $s = new NaServer( $Hostname, 1, 110 );
$s->set_transport_type('HTTPS');
$s->set_style('LOGIN');
$s->set_admin_user($Username, $Password);

# Check all vservers for enabled vscan status
my $enabled_iterator = new NaElement('vscan-status-get-iter');
my $tag_elem = NaElement->new("tag");
$enabled_iterator->child_add($tag_elem);

my $xi = new NaElement('query');
$enabled_iterator->child_add($xi);
my $xi2 = new NaElement('vscan-status-info');
$xi->child_add($xi2);
if($Vserver){
	$xi2->child_add_string('vserver',$Vserver);
}
my $enabled_next = '';

while(defined($enabled_next)){
	unless($enabled_next eq ""){
		$tag_elem->set_content($enabled_next);
	}

	$enabled_iterator->child_add_string('max-records',100);
	my $output = $s->invoke_elem($enabled_iterator);
	if ($output->results_errno != 0) {
	    my $r = $output->results_reason();
	    print "UNKNOWN: $r\n";
	    exit 3;
	}

	my $vserver_all = $output->child_get("attributes-list");

	unless($output->child_get_int('num-records') != 0) {
        last;
	}

	my @result = $vserver_all->children_get();

	foreach my $vscan_info (@result){

		my $vscan_enabled = $vscan_info->child_get_string("is-vscan-enabled");
		my $vserver = $vscan_info->child_get_string("vserver");

		if(@excludevserverlistarray){
			if ($vserver =~ m/$excludevserverliststr/) {
				next;
			}
		}
		if ( $vserver =~ m/-mc/ ) { next; }

		my $status_msg = "vscan enabled for $vserver: $vscan_enabled";

		if($vscan_enabled eq "true"){
			push (@list, $vserver);
		}
	}
	
	$enabled_next = $output->child_get_string("next-tag");
}

# Check all enabled vscan vservers for connection status
my $connection_iterator = new NaElement('vscan-connection-status-all-get-iter');
my $connection_tag_elem = NaElement->new("tag");
$connection_iterator->child_add($connection_tag_elem);

my $xi3 = new NaElement('query');
$connection_iterator->child_add($xi3);
my $xi4 = new NaElement('vscan-connection-status-all-info');
$xi3->child_add($xi4);
if($Vserver){
	$xi4->child_add_string('vserver',$Vserver);
}
my $connection_next = '';

while(defined($connection_next)){
	unless($connection_next eq ""){
		$connection_tag_elem->set_content($connection_next);
	}

	$connection_iterator->child_add_string('max-records',100);
	my $connection_output = $s->invoke_elem($connection_iterator);
	if ($connection_output->results_errno != 0) {
	    my $r = $connection_output->results_reason();
	    print "UNKNOWN: $r\n";
	    exit 3;
	}
	
	my $connection_all = $connection_output->child_get("attributes-list");

	unless($connection_output->child_get_int('num-records') != 0) {
        last;
	}

	my @conn_result = $connection_all->children_get();

	foreach my $vscan_conn_info (@conn_result){

		my $server_status = $vscan_conn_info->child_get_string("server-status");
		my $server_name = $vscan_conn_info->child_get_string("server");
		my $vserver_name = $vscan_conn_info->child_get_string("vserver");
		my $disconnect_reason = $vscan_conn_info->child_get_string("disconnect-reason");
		my $disconnected_since = $vscan_conn_info->child_get_string("disconnected-since");
		my $connected_since = $vscan_conn_info->child_get_string("connected-since");

		if(@excludevserverlistarray){
			if ($vserver_name =~ m/$excludevserverliststr/) {
				next;
			}
		}

		unless ( grep( /^$server_name$/, @list )) {
			next;
		}

		$conn_msg="";

		if($server_status =~ m/^dis$/ && ($disconnect_reason) && ($disconnected_since)) {
			$conn_msg = "vscan $server_name is $server_status ($disconnected_since). Reason: $disconnect_reason";
			push (@warn_msg, "$conn_msg\n");
		} elsif ($server_status =~ m/^ing$/){
			$conn_msg = "vscan $server_name is $server_status";
			push (@warn_msg, "$conn_msg\n");
		} else {
			$conn_msg = "vscan $server_name is $server_status since $connected_since.";
			push (@ok_msg, "$conn_msg\n")
		}
	}
	
	$connection_next = $connection_output->child_get_string("next-tag");
}

# Version output
print "Script version: $version\n";

my $size;

if(scalar(@warn_msg) ){
    $size = @warn_msg;
    print "WARNING: $size vserver(s) are currently not connected\n";
    print join ("", @warn_msg);
	exit 1;
} if(scalar(@ok_msg) ){
    print "OK:\n";
    print join ("", @ok_msg);
    exit 0;
} else {
	if ($Vserver) {
		print "WARNING: no vserver with this name found\n";
		exit 1;
	} else {
		print "OK: no vserver(s) with vscan enabled found\n";
		exit 0;
	}

}

__END__

=encoding utf8

=head1 NAME

check_cdot_vscan - Check vscan connection status

=head1 SYNOPSIS

check_cdot_vscan.pl --hostname HOSTNAME --username USERNAME \
           --password PASSWORD [--vserver VSERVER-NAME] 
           [--excludevserver VSERVER-NAME]

=head1 DESCRIPTION

Checks the lUN Space usage of the NetApp System and warns
if warning or critical Thresholds are reached

=head1 OPTIONS

=over 4

=item --hostname FQDN

The Hostname of the NetApp to monitor (Cluster or Node MGMT)

=item --username USERNAME

The Login Username of the NetApp to monitor

=item --password PASSWORD

The Login Password of the NetApp to monitor

=item --vserver VSERVER

Optional: The name of the Vserver where the Luns that need to be checked are located

=item --excludevserver
Optional: The name of a vserver that has to be excluded from the checks (multiple exclude item for multiple volumes)

=item --perf

Flag for performance data output

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

Giorgio Maggiolo <giorgio at maggiolo dot net>
Therese Ho <thereseh at netapp dot com>