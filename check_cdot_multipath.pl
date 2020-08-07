#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_multipath - Check if all disks are multipathed (4 paths)
# Copyright (C) 2013 noris network AG, http://www.noris.net/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

use Data::Dumper;

use 5.10.0;
use strict;
use warnings;

use lib "/usr/lib/netapp-manageability-sdk/lib/perl/NetApp";

use NaServer;
use NaElement;
use Getopt::Long;

GetOptions(
    'hostname=s' => \my $Hostname,
    'username=s' => \my $Username,
    'password=s' => \my $Password,
    'onepath-config=s'=> \my $Exception,
    'help|?'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error( "$0: Error in command line arguments\n" );

my $version = "1.0.1";

sub Error {
    print "$0: ".$_[0]."\n";
    exit 2;
}
Error( 'Option --hostname needed!' ) unless $Hostname;
Error( 'Option --username needed!' ) unless $Username;
Error( 'Option --password needed!' ) unless $Password;

my $s = NaServer->new( $Hostname, 1, 3 );
$s->set_transport_type( "HTTPS" );
$s->set_style( "LOGIN" );
$s->set_admin_user( $Username, $Password );

# MCC check
my $mcc_iterator = NaElement->new("metrocluster-get");
my $desired_attributes = NaElement->new("desired-attributes");
my $metrocluster_info = NaElement->new("metrocluster-info");
$metrocluster_info->child_add('local-cluster-name','local-cluster-name');
$metrocluster_info->child_add('local-configuration-state','local-configuration-state');
$metrocluster_info->child_add('configuration-type','local-configuration-type');

my $mcc_response = $s->invoke_elem($mcc_iterator);

my $mcc = $mcc_response->child_get("attributes");
my $mcc_info = $mcc->child_get("metrocluster-info");
my $config_state = $mcc_info->child_get_string("local-configuration-state");
my $mcc_name = $mcc_info->child_get_string("local-cluster-name");


if($config_state eq "configured") {

    my $type = $mcc_info->child_get_string( "configuration-type" );

    if ($type eq "stretch") {
        $must_paths = 2;
    } elsif ($type eq "fabric") {
        $must_paths = 8;
    } elsif ($type eq "two_node_fabric") {
        $must_paths = 4;
    }
} else {
    # $Exception leer oder false!
    if(($Exception) && ($Exception ne "false")) {
        $must_paths = 1;
    } else {
        $must_paths = 4;        
    }
}

my $shelf_iterator = NaElement->new("storage-shelf-info-get-iter");
$shelf_iterator->child_add_string("max-records", "1000");
my $shelf_response = $s->invoke_elem( $shelf_iterator );
my $shelfs = $shelf_response->child_get("attributes-list");

my @result = $shelfs->children_get();

my %shelfs;

foreach my $shelf (@result) {

    my $type = $shelf->child_get_string("module-type");
    my $stack = $shelf->child_get_string("stack-id");
    my $shelf_id = $shelf->child_get_string("shelf-id");
    
    my $shelf_name = "$stack.$shelf_id";

    $shelfs{$shelf_name} = $type;

}

my $iterator = NaElement->new( "storage-disk-get-iter" );
my $tag_elem = NaElement->new( "tag" );
$iterator->child_add( $tag_elem );

my $next = "";
my @failed_disks;
my @info_disks;

while(defined( $next )){
    unless ($next eq "") {
        $tag_elem->set_content( $next );
    }

    $iterator->child_add_string( "max-records", 100 );
    my $output = $s->invoke_elem( $iterator );

    if ($output->results_errno != 0) {
        my $r = $output->results_reason();
        print "UNKNOWN: $r\n";
        exit 3;
    }

    unless($output->child_get_int( "num-records" ) eq "0") {

        my $heads = $output->child_get( "attributes-list" );
        my @result = $heads->children_get();

        foreach my $disk (@result) {

            my $inventory = $disk->child_get("disk-inventory-info");
            my $paths = $disk->child_get( "disk-paths" );
            my $path_count = $paths->children_get( "disk-path-info" );
            my $disk_name = $disk->child_get_string( "disk-name" );
            my $path_info = $paths->child_get( "disk-path-info" );

            my $shelf = $inventory->child_get_string("shelf");
            my $stack_id = $inventory->child_get_string("stack-id");

            my $iom_type = $shelfs{"$stack_id.$shelf"};

            my $new_must_paths;

            # Internal disks i.e. A700s have 8 paths
            if($iom_type eq "iom12f"){
                $new_must_paths = "8";
            } else {
                $new_must_paths = $must_paths;
            }

            unless($path_count eq $new_must_paths){
                push @failed_disks, $disk_name;
            }
        }
    }

    $iterator->child_add_string("max-records", 100);
    $output = $s->invoke_elem($iterator);

	if ($output->results_errno != 0) {
	    my $r = $output->results_reason();
	    print "UNKNOWN: $r\n";
	    exit 3;
	}
	
	my $heads = $output->child_get("attributes-list");
	my @result = $heads->children_get();

	foreach my $disk (@result){
	
	    my $paths = $disk->child_get("disk-paths");
	    my $path_count = $paths->children_get("disk-path-info");
	    my $disk_name = $disk->child_get_string("disk-name");
        my $path_info = $paths->child_get("disk-path-info");

        foreach my $path ($path_info){

            my $disk_path_name = $path->child_get_string("disk-name");
            my @split = split(/:/,$disk_path_name);

            if ($must_paths > 1) {
                if((@split eq 2) && ($path_count ne $must_paths)){
                    unless($path_count > $must_paths){
                        push @failed_disks, "$disk_name: $path_count instead of $must_paths paths\n";
                    }
                }      
            } else {
                if(($path_count ne $must_paths)){
                    unless($path_count > $must_paths){
                        push @failed_disks, "$disk_name: $path_count instead of $must_paths path\n";
                    }
                    push @info_disks, "$disk_name: $path_count instead of $must_paths path\n";
                }     
            }
        }
    }
    $next = $output->child_get_string( "next-tag" );
}

# Version output
print "Script version: $version\n";

if (@failed_disks) {
    print "\nWARNING: disk(s) not multipath:\n" . join( " ", @failed_disks );
    exit 2;
} else {
    if(@info_disks) {
        print "\nOK: disk(s) having more than 1 path:\n" . join( " ", @info_disks );
    } else {
        print "\nOK: All disks multipath or with $must_paths path(s) as configured.\n";
    }
    
    exit 0;
}

__END__

=encoding utf8

=head1 NAME

check_cdot_multipath - Check if all disks are multipathed (4 paths)

=head1 SYNOPSIS

check_cdot_multipath.pl --hostname HOSTNAME --username USERNAME \
    --password PASSWORD

=head1 DESCRIPTION

Checks if all Disks are multipathed (4 paths)

=head1 OPTIONS

=over 4

=item --hostname FQDN

The Hostname of the NetApp to monitor (Cluster or Node MGMT)

=item --username USERNAME

The Login Username of the NetApp to monitor

=item --password PASSWORD

The Login Password of the NetApp to monitor

=item --onepath-config EXCEPTION

Exception parameter for one-node Clusters with only 1 path configured. Values: true/false

=item -help

=item -?

to see this Documentation

=back

=head1 EXIT CODE

3 if timeout occured
2 if one or more disks doesn't have 4 Paths
0 if everything is ok

=head1 AUTHORS

 Alexander Krogloth <git at krogloth.de>
 Stelios Gikas <sgikas at demokrit.de>
