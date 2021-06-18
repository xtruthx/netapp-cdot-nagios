#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_fcp.pl - Check FCP interfaces and adapter_list
# Copyright (C) 2021 operational services GmbH & Co. KG
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
use List::Util qw(max);

use Data::Dumper;

GetOptions(
    'H|hostname=s' => \my $Hostname,
    'u|username=s' => \my $Username,
    'p|password=s' => \my $Password,
    'a|adapter=s'  => \my $fcp_adapter,
    'n|node=s'     => \my $fcp_node,
    'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'help|?'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my $version = "1.0.3";

# separate exclude strings into arrays
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

my (@crit_msg, $crit_msg);
my (@warn_msg, $warn_msg);
my (@ok_msg, $ok_msg);
my @return;

my $s = NaServer->new( $Hostname, 1, 130 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

# Check (specific) adapter for errors
my $iterator = new NaElement('fcp-adapter-get-iter');
my $tag_elem = NaElement->new("tag");
$iterator->child_add($tag_elem);

my $desired_attributes = NaElement->new("desired-attributes");
$iterator->child_add($desired_attributes);

# specify which attributes should be returned
my $fcp_adapter_info = new NaElement('fcp-config-adapter-info');
$desired_attributes->child_add($fcp_adapter_info);
$fcp_adapter_info->child_add_string('adapter','adapter');
$fcp_adapter_info->child_add_string('node','node');
$fcp_adapter_info->child_add_string('state','state');
$fcp_adapter_info->child_add_string('physical-link-state','physical-link-state');
$fcp_adapter_info->child_add_string('status-admin','status-admin');

# specify adapter
my $xi1 = new NaElement('query');
$iterator->child_add($xi1);
my $xi2 = new NaElement('fcp-config-adapter-info');
$xi1->child_add($xi2);
if($fcp_adapter && $fcp_node){
    $xi2->child_add_string('adapter',$fcp_adapter);
    $xi2->child_add_string('node',$fcp_node);
}

my $next = "";

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

    my $adapter_list = $output->child_get("attributes-list");

    unless($adapter_list){
	    print "CRITICAL: no adapter matching this name\n";
	    exit 2;
	}

    my @result = $adapter_list->children_get();

    my @down_adapters;

    foreach my $adapt (@result){

        # get all acquired information
        my $adapt_name = $adapt->child_get_string("adapter");
        my $node_name = $adapt->child_get_string("node");
        my $physical_link_status = $adapt->child_get_string("physical-link-state");
        my $state = $adapt->child_get_string("state");
        my $admin_state = $adapt->child_get_string("status-admin");

        if($admin_state) { next if($admin_state eq "down") } else { next };

        # Check CNA adapters for physical link state
        if($physical_link_status) {
            if($physical_link_status eq "link down") {
                $warn_msg = "CNA adapter $adapt_name (node $node_name) $physical_link_status";
                push (@warn_msg, "$warn_msg\n");
            } else {
                my $ok_msg = "CNA adapter $adapt_name (node $node_name) $physical_link_status";
                push (@ok_msg, "$ok_msg\n");
            }
        } else {
            if($state ne "online") {
                $warn_msg = "$adapt_name (node $node_name) $state";
                push (@warn_msg, "$warn_msg\n");
            } else {
                my $ok_msg = "$adapt_name (node $node_name) is $state";
                push (@ok_msg, "$ok_msg\n");
            }
        }
    }
    $next = $output->child_get_string("next-tag");
}

# Check interfaces for errors
my $stats_output = $s->invoke("fcp-adapter-stats-get-iter");

if ($stats_output->results_errno != 0) {
    my $r = $stats_output->results_reason();
    print "UNKNOWN: $r\n";
    exit 3;
}

my $lifs = $stats_output->child_get("attributes-list");

if($lifs){

    my @adapters = $lifs->children_get("fcp-adapter-stats-info");

    foreach my $adapter (@adapters){

        my $adapter_name = $adapter->child_get_string("adapter");
        my $node = $adapter->child_get_string("node");

        my $adapter_reset = $adapter->child_get_string("adapter-resets");
        my $crc_errors = $adapter->child_get_string("crc-errors");
        my $discarded_frames = $adapter->child_get_string("discarded-frames");
        my $invalid_xmit_words = $adapter->child_get_string("invalid-xmit-words");
        my $link_breaks = $adapter->child_get_string("link-breaks");
        my $lip_resets = $adapter->child_get_string("lip-resets");
        my $protocol_errors = $adapter->child_get_string("protocol-errors");
        my $scsi_requests_dropped = $adapter->child_get_string("scsi-requests-dropped");

        my $total_errors = $adapter_reset+$crc_errors+$discarded_frames+$invalid_xmit_words+$link_breaks+$lip_resets+$protocol_errors+$scsi_requests_dropped;

        if($total_errors > 0){

            $crit_msg .= "$node: $adapter_name has errors\n";
            $crit_msg .= "adapter_reset: $adapter_reset\n";
            $crit_msg .= "crc_errors: $crc_errors\n";
            $crit_msg .= "discarded_frames: $discarded_frames\n";
            $crit_msg .= "invalid_xmit_words: $invalid_xmit_words\n";
            $crit_msg .= "link_breaks: $link_breaks\n";
            $crit_msg .= "lip_resets: $lip_resets\n";
            $crit_msg .= "protocol_errors: $protocol_errors\n";
            $crit_msg .= "scsi_requests_dropped: $scsi_requests_dropped\n\n";

            push (@crit_msg, $crit_msg);
        } else {
            my @line = grep(/^No FC interface errors/i, @ok_msg);
            if(!@line) {
                push (@ok_msg, "No FC interface errors\n");
            }
        }
    }
}

my $size;

# Version output
print "Script version: $version\n";

if(scalar(@crit_msg) ){
    $size = @crit_msg;
    print "CRITICAL: $size adapters have interface errors\n";
    print join ("", @crit_msg)."\n";
	push @return, 2;
} if(scalar(@warn_msg) ){
    $size = @warn_msg;
    print "WARNING: $size adapters are down\n";
    print join ("", @warn_msg)."\n";
	push @return, 1;
} if(scalar(@ok_msg) ){
    print "OK:\n";
    print join ("", @ok_msg);
    push @return, 0;
} else {
    print "WARNING: no adapter with this name found\n";
    push @return, 1;
}

exit max( @return );

__END__

=encoding utf8

=head1 NAME

check_cdot_fcp - Check fcp adapters

=head1 SYNOPSIS

check_cdot_fcp.pl --hostname HOSTNAME --username USERNAME \
           --password PASSWORD

=head1 DESCRIPTION

Checks if all fcp interface have CRC errors and links are up

=head1 OPTIONS

=over 4

=item --hostname FQDN

The Hostname of the NetApp to monitor (Cluster or Node MGMT)

=item --username USERNAME

The Login Username of the NetApp to monitor

=item --password PASSWORD

The Login Password of the NetApp to monitor

=item --adapter ADAPTER

The Name of the specific port to be checked

=item --exclude

Optional: The name of a port that has to be excluded from the checks (multiple exclude item for multiple volumes)

=item --regexp

Optional: Uses the input in "exclude" parameter as a regex filter for port names. A value must not be set.


=item -help

=item -?

to see this Documentation

=back

=head1 EXIT CODE

3 on Unknown Error
2 if any link is down
0 if everything is ok

=head1 AUTHORS

 Alexander Krogloth <git at krogloth.de>
