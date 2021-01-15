#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_disk - Check NetApp System Disk State
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
use Getopt::Long qw(:config no_ignore_case);
use List::Util qw(max);
use Data::Dumper;

GetOptions(
    'H|hostname=s'  => \my $Hostname,
    'u|username=s'  => \my $Username,
    'p|password=s'  => \my $Password,
    'w|warning=i'   => \my $warning,
    'c|critical=i'  => \my $critical,
    'd|diskcount=i' => \my $Diskcount,
	'exclude=s'	 =>	\my @excludelistarray,
    'regexp'            => \my $regexp,
    'P|perf' => \my $perf,
    'h|help'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

my $version = "1.0.1";

# Filter through full names or regex
my %Excludelist;
@Excludelist{@excludelistarray}=();
my $excludeliststr = join "|", @excludelistarray;

sub Error {
    print "$0: ".$_[0]."\n";
    exit 2;
}
Error( 'Option --hostname needed!' ) unless $Hostname;
Error( 'Option --username needed!' ) unless $Username;
Error( 'Option --password needed!' ) unless $Password;

$critical = 2 unless $critical;
$warning = 1 unless $warning;

my $s = NaServer->new( $Hostname, 1, 110 );
$s->set_transport_type( "HTTPS" );
$s->set_style( "LOGIN" );
$s->set_admin_user( $Username, $Password );

my $iterator = NaElement->new( "storage-disk-get-iter" );
my $tag_elem = NaElement->new( "tag" );
$iterator->child_add( $tag_elem );

my $next = "";
my $disk_count = 0;
my @failed_disks;
my @not_zeroed_disks;
my @unassigned_disks;
my @maintenance_disks;
my @spare_disks;
my @shared_spare_disks;
my @ret;
my %inventory = ( 'Spare', 0, 'Rebuilding', 0, 'Aggregate', 0, 'Failed', 0, 'Not_zeroed', 0, 'Unassigned', 0, 'Maintenance', 0);

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

        my $disks = $output->child_get( "attributes-list" );
        my @result = $disks->children_get();

        foreach my $disk (@result) {
            my $raid_type = $disk->child_get( "disk-raid-info" );
            my $container = $raid_type->child_get_string( "container-type" );
			my $disk_name = $disk->child_get_string('disk-name');

			next if exists $Excludelist{$disk_name};
		
			if ($regexp and $excludeliststr) {
				next if ($disk_name =~ m/$excludeliststr/);
			}
		
            $disk_count++;

            if ( $container eq 'shared' ) {
                # Dig deeper
                my $shared_info = $raid_type->child_get( "disk-shared-info" );
                my $temp = $shared_info->child_get_string( "is-reconstructing" );
                if ($temp eq 'true') {
                    $inventory{'Rebuilding'}++;
                } else {
                    $temp = $shared_info->child_get_string( "is-replacing" );
                    if ($temp eq 'true') {
                        # Also count as Rebuilding
                        $inventory{'Rebuilding'}++;
                    } else {
                        $inventory{'Aggregate'}++;
                        # count shared disks as spare
                        $inventory{'Spare'}++;
                        push @shared_spare_disks, $disk_name;
                    }
                }
            } elsif ( $container eq 'spare' ) {
                $inventory{'Spare'}++;
                push @spare_disks, $disk_name;
				my $spare_info = $raid_type->child_get("disk-spare-info");
				my $zeroed = $spare_info->child_get_string('is-zeroed');

				if($zeroed eq 'false'){
					push @not_zeroed_disks, $disk_name;
					$inventory{'Not_zeroed'}++;
				}
			} elsif( $container eq 'unassigned' ){
				push @unassigned_disks, $disk_name;
				$inventory{'Unassigned'}++;
			} elsif( $container eq 'maintenance' ){
				push @maintenance_disks, $disk_name;
				$inventory{'Maintenance'}++;
            } elsif ( $container eq 'aggregate' ) {
                # Dig deeper
                my $aggr_info = $raid_type->child_get( "disk-aggregate-info" );
                my $temp = $aggr_info->child_get_string( "is-reconstructing" );
                if ($temp eq 'true') {
                    $inventory{'Rebuilding'}++;
                } else {
                    $temp = $aggr_info->child_get_string( "is-replacing" );
                    if ($temp eq 'true') {
                        # Also count as Rebuilding
                        $inventory{'Rebuilding'}++;
                    } else {
                        $inventory{'Aggregate'}++;
                    }
                }
            } else {
                my $owner = $disk->child_get( "disk-ownership-info" );
                my $owner_node = $owner->child_get_string("owner-node-name");

                my $diskstate = $owner->child_get_string( "is-failed" );
                if (( $diskstate eq 'true' ) && ($container ne 'maintenance')) {
                    push @failed_disks, "$owner_node:" . $disk->child_get_string( "disk-name" );
                    $inventory{'Failed'}++;
                } else {
                    $inventory{'Aggregate'}++;
                }
            }
        }
    }
    $next = $output->child_get_string( "next-tag" );

}

# my $perfdatastr='';
# $perfdatastr = sprintf(" | Aggregate=%d Spare=%d Rebuilding=%d Failed=%d",
#     $inventory{'Aggregate'}, $inventory{'Spare'}, $inventory{'Rebuilding'}, $inventory{'Failed'}
# ) if ($perf);

# if ( scalar @disk_list >= $critical ) {
#     print "CRITICAL: " . @disk_list . ' failed disk(s): ' . join( ', ', @disk_list ) . $perfdatastr ."\n";
#     exit 2;
# } elsif ( scalar @disk_list >= $warning ) {
#     print "WARNING: " . @disk_list .' failed disk(s): ' .join( ', ', @disk_list ) . $perfdatastr ."\n";
#     exit 1;
# } elsif(($Diskcount) && ($Diskcount ne $disk_count)) {
#     $iterator->child_add_string("max-records", 100);
#     my $output = $s->invoke_elem($iterator);

# Version output
print "Script version: $version\n";

# Critical nur bei 0 Spares (Shared mitgezählt)
if ( (scalar @failed_disks ge $critical) || ($inventory{'Spare'} == 0 )) {
	print "CRITICAL: \n";
	if ( scalar @failed_disks >= $critical ) {
		print @failed_disks . " failed disk(s):\n" . join( "\n", @failed_disks );
	}

	if ( $inventory{'Spare'} < 1 ) {
		print "\nNo spare disks found.";
	}
	#print "\n\n$perfdatastr" ;
    push @ret, 2;
}
if ( scalar @failed_disks >= $warning || scalar @not_zeroed_disks >= $warning || scalar @maintenance_disks >= $warning ) {
	print "\nWARNING: ";
	if ( scalar @failed_disks >= $warning && scalar @failed_disks < $critical) {
		print "\n" . @failed_disks . " failed disk(s):\n" . join( "\n", @failed_disks );
	}
	if ( scalar @not_zeroed_disks >= $warning ) {
		print "\n" . @not_zeroed_disks . " not zeroed disk(s):\n" . join( "\n", @not_zeroed_disks );
	}
	if ( scalar @maintenance_disks >= $warning ) {
		print "\n" . @maintenance_disks . " disk(s) in maintenance:\n" . join( "\n", @maintenance_disks );
	}

	#print $perfdatastr ."\n";
    push @ret, 1;
}

if(($Diskcount) && ($Diskcount ne $disk_count)){
    my $diff = $Diskcount-$disk_count;
    print "\nCRITICAL: $diff disk(s) missing"."\n";
    push @ret, 2;
} else {
    my $ok_count = $disk_count - (scalar @failed_disks) - (scalar @not_zeroed_disks) - (scalar @maintenance_disks);
    print "\nOK: $ok_count disk(s) OK"."\n";
    push @ret, 0;
}

# immer mit Output für unassigned und spare disks
if ( scalar @unassigned_disks > 0 ) {
    print "\n" . @unassigned_disks . " unassigned disk(s):\n" . join( "\n", @unassigned_disks );
}   
if ( $inventory{'Spare'} > 0 ) {
    print "\n" . scalar @spare_disks . " spare disk(s):\n" . join("\n", @spare_disks );
    print "\n" . scalar @shared_spare_disks ." shared spare disk(s):\n" . join("\n", @shared_spare_disks) ;
}   

exit max( @ret );


__END__

=encoding utf8

=head1 NAME

check_cdot_disk - Checks Disk Healthness

=head1 SYNOPSIS

check_cdot_disk.pl -H HOSTNAME -u USERNAME -p PASSWORD [-d COUNT]

=head1 DESCRIPTION

Checks if there are some damaged disks.

=head1 OPTIONS

=over 4

=item -H | --hostname FQDN

The Hostname of the NetApp to monitor (Cluster or Node MGMT)

=item -u | --username USERNAME

The Login Username of the NetApp to monitor

=item -p | --password PASSWORD

The Login Password of the NetApp to monitor

=item -d | --disks COUNT

Expected number of disks to find

=item -help

=item -h

to see this Documentation

=back

=head1 EXIT CODE

3 if timeout occured
2 if there are some damaged disks
0 if everything is ok

=head1 AUTHORS

 Alexander Krogloth <git at krogloth.de>
 Stelios Gikas <sgikas at demokrit.de>

