#!/usr/bin/perl
#
# Copyright (c) 2019 AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2014-2015 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5/";

use Getopt::Long;
use Vyatta::Dataplane;
use Vyatta::Config;
use JSON qw( decode_json );

my %erspanhdrs = (
    '1' => 'type-II',
    '2' => 'type-III',
);

my $show_rules_cmd = "/opt/vyatta/sbin/vyatta-dp-npf-show-rules";

my ( $allowed_sessions, $fabric, $session, $show_sessions, $allowed_srcifs,
     $show_filter_info, $allowed_pmsess_srcifs, $show_srcif_filter_info,
     $srcif);
GetOptions(
    'allowed'                   => \$allowed_sessions,
    'fabric=s'                  => \$fabric,
    'session=s'                 => \$session,
    'show'                      => \$show_sessions,
    'allowed-srcifs'            => \$allowed_srcifs,
    'show-filter-info'          => \$show_filter_info,
    'allowed-pmsess-srcifs'     => \$allowed_pmsess_srcifs,
    'show-srcif-filter-info'    => \$show_srcif_filter_info,
    'srcif=s'                   => \$srcif,
);

my $pmconfig = Vyatta::Config->new('service portmonitor');

allowed_portmonitor_sessions() if ($allowed_sessions);
show_portmonitor($session) if ($show_sessions);
allowed_srcifs() if ($allowed_srcifs);
show_pmsess_filter_info($session) if ($show_filter_info);
allowed_pmsess_srcifs($session) if ($allowed_pmsess_srcifs);
show_pmsess_srcif_filter_info($session, $srcif) if ($show_srcif_filter_info);

sub allowed_srcifs {
    foreach my $sessionid ( $pmconfig->listOrigNodes("session") ) {
        foreach my $srcif ( $pmconfig->listOrigNodes("session $sessionid source") ) {
            print "$srcif\n";
        }
    }
}

sub allowed_pmsess_srcifs {
    my ($sessionid) = @_;
    foreach my $srcif ( $pmconfig->listOrigNodes("session $sessionid source") ) {
        print "$srcif\n";
    }
}

sub print_sessionid {
    my ($sid) = @_;
    print "----------------------\n";
    print "Portmonitor Session: $sid\n";
    print "----------------------\n";
}

sub show_pmsess_filter_info {
    my ($sessionid) = @_;
    my $filter_type = "portmonitor-in portmonitor-out";
    print_sessionid($sessionid);
    foreach my $srcif ( $pmconfig->listOrigNodes("session $sessionid source") ) {
        print qx($show_rules_cmd interface:$srcif $filter_type);
    }
}

sub show_pmsess_srcif_filter_info {
    my ($sessionid, $srcif) = @_;
    my $filter_type = "portmonitor-in portmonitor-out";
    if ( $pmconfig->existsOrig("session $sessionid source $srcif") ) {
        print_sessionid($sessionid);
        print qx($show_rules_cmd interface:$srcif $filter_type);
    } else {
        print "Invalid source interface\n";
    }
}

sub show_portmonitor {
    my ($sessionid) = @_;
    my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns($fabric);
    die "Dataplane $fabric is not connected or does not exist\n"
      unless ( !defined($fabric) || scalar(@$dpids) > 0 );

    for my $fid (@$dpids) {
        my $sock = ${$dpsocks}[$fid];
        die "Can not connect to dataplane $fid\n"
          unless defined($sock);

        my $response = "";
        if ( defined($sessionid) ) {
            $response = $sock->execute("portmonitor show session $sessionid");
        }
        else {
            $response = $sock->execute("portmonitor show session");
        }
        exit 1 unless defined($response);

        print "\nvplane $fid:\n\n"
          unless ( $fid == 0 );

        my $decoded       = decode_json($response);
        my $session_array = $decoded->{portmonitor_information};
        my $fmt           = "  %-28s %s\n";

        if ( scalar( @{$session_array} ) <= 0 ) {
            print "Portmonitor: No session is configured\n";
        }

        foreach my $entry ( @{$session_array} ) {
            my $sid = $entry->{session};
            die "Invalid portmonitor session $sessionid\n"
              unless defined($sid);

            my $stype = $entry->{type};
            printf $fmt, "Session: ", $sid;
            printf $fmt, "  Type: ",  $stype;
            printf $fmt, "  State: ", $entry->{state};
            if ( 'erspan-source' eq $stype || 'erspan-destination' eq $stype ) {
                printf $fmt, "  erspan Identifier: ", $entry->{erspanid};
                printf $fmt, "  erspan Header: ",
                  $erspanhdrs{ ( $entry->{erspanhdr} ) };
            }
            my $session_desc =
              $pmconfig->returnOrigValue("session $sid description");
            if ( defined($session_desc) ) {
                printf $fmt, "  Description: ", $session_desc;
            }
            my $source_interfaces = $entry->{source_interfaces};
            if ( defined($source_interfaces) ) {
                printf $fmt, "  Source interfaces: ", "";
                foreach my $intf ( @{$source_interfaces} ) {
                    printf $fmt, "    Name: ",        $intf->{name};
                    printf $fmt, "      Direction: ", $intf->{direction}
                      unless ( 'rspan-destination' eq $stype
                        || 'erspan-destination' eq $stype );
                }
            }
            printf $fmt, "  Destination interface: ",
              $entry->{destination_interface},
              if defined( $entry->{destination_interface} );
            if ( 'rspan-destination' ne $stype && 'erspan-destination' ne $stype ) {
                my $filters = $entry->{filters};
                if ( defined($filters) ) {
                    printf $fmt, "  Filters: ", "";
                    foreach my $filter ( @{$filters} ) {
                        printf $fmt, "    Name: ",        $filter->{name};
                        printf $fmt, "      Type: ",      $filter->{type}
                    }
                }
            }
        }
    }
    Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );
}

sub allowed_portmonitor_sessions {
    foreach my $session ( $pmconfig->listOrigNodes("session") ) {
        print "$session\n";
    }
}
