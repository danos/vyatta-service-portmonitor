#! /usr/bin/perl
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2014-2017 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use lib '/opt/vyatta/share/perl5';
use warnings;
use Getopt::Long;
use Vyatta::Config;
use Vyatta::VPlaned;
use Vyatta::Misc;

my %session_type = (
    'span'               => '1',
    'rspan-source'       => '2',
    'rspan-destination'  => '3',
    'erspan-source'      => '4',
    'erspan-destination' => '5',
);

my %direction_type = (
    'both' => '0',
    'rx'   => '1',
    'tx'   => '2',
);

my %header_type = (
    'type-II'  => '1',
    'type-III' => '2',
);

my $ctrl           = new Vyatta::VPlaned;
my $config         = new Vyatta::Config("service portmonitor session");
my $filter_updated = 0;

# Prepare command in the following format
#     "portmonitor set session $session $key $value $param1 $param2"
#         - key is node. e.g. 'srcif', 'type'
#         - cskey is end of key for use in the config store, based on CLI
#         - value is node's value. e.g. 'dp0s3', 'span'
#         - param1 is vif id. '300'
#         - param2 is direction of physical/ vif interface. e.g. 'rx'
# Validations are already done, just perform actions
sub send_cmd_to_controller {
    my ( $action, $cskey, $sessionid, $key, $value, $param1, $param2 ) = @_;
    my $cs_action = 'SET';
    $cs_action = 'DELETE'
      if ( $action eq 'del' );

    $ctrl->store(
        "service portmonitor session $sessionid $cskey",
        "portmonitor $action session $sessionid $key $value $param1 $param2",
        undef, $cs_action
    );
}

# disable is empty leaf, so it is either set or not present
sub modify_disable {
    my ( $sessionid, $action ) = @_;
    if ( $action eq "del" ) {
        send_cmd_to_controller( "del", "disable", $sessionid, "disable", 0, 0,
            0 );
    } elsif ( $action eq "set" ) {
        send_cmd_to_controller( "set", "disable", $sessionid, "disable", 0, 0,
            0 );
    }
}

sub modify_filters {
    my ( $action, $sessionid, $filters_ref, $type ) = @_;
    my @filters = @{$filters_ref};
    return if ( !defined($type) );
    my $key;
    if ( $type eq "in" ) {
        $key = "filter-in";
    } elsif ( $type eq "out" ) {
        $key = "filter-out";
    }
    return if ( !defined($key) );
    foreach my $filter (@filters) {
        send_cmd_to_controller( $action, "filter $type $filter",
            $sessionid, $key, $filter, 0, 0 );
    }
}

sub set_filters {
    my ($sessionid) = @_;
    my @filters_in  = $config->returnValues("$sessionid filter in");
    my @filters_out = $config->returnValues("$sessionid filter out");
    modify_filters( "set", $sessionid, \@filters_in,  "in" )  if (@filters_in);
    modify_filters( "set", $sessionid, \@filters_out, "out" ) if (@filters_out);
}

sub detach_filters_on_intf {
    my ( $sessionid, $intf, $filters_ref, $type ) = @_;
    my @filters = @{$filters_ref};
    foreach my $filter (@filters) {
        $filter_updated++ if ( $filter_updated == 0 );
        $ctrl->store(
"service portmonitor session $sessionid __pmf_attach $intf $type $filter",
            "npf-cfg detach interface:$intf portmonitor-$type fw:$filter",
            undef,
            "DELETE"
        );
    }
}

sub attach_filters_on_intf {
    my ( $sessionid, $intf, $filters_ref, $type ) = @_;
    my @filters = @{$filters_ref};
    foreach my $filter (@filters) {
        $filter_updated++ if ( $filter_updated == 0 );
        $ctrl->store(
"service portmonitor session $sessionid __pmf_attach $intf $type $filter",
            "npf-cfg attach interface:$intf portmonitor-$type fw:$filter",
            undef,
            "SET"
        );
    }
}

sub commit_filter_changes {
    $ctrl->store( "npf-cfg commit", "npf-cfg commit", undef, "SET" );
}

sub modify_source_intf {
    my ( $action, $sessionid, $source ) = @_;

    my ( $srcif, $vif ) = split /\./, $source;
    $vif = 0 unless defined($vif);

    my $direction = 0;
    if ( $action eq "set" ) {
        $direction =
          $config->returnValue("$sessionid source $source direction");
        $direction = $direction_type{$direction} if ( defined($direction) );
    }

    send_cmd_to_controller( $action, "source $source",
        $sessionid, "srcif", $srcif, $vif, $direction );
}

sub is_source_session {
    my ($sessionid) = @_;
    my $type = $config->returnValue("$sessionid type");
    return (
        defined($type) && ( $type eq "span"
            || $type eq "rspan-source"
            || $type eq "erspan-source" )
    );
}

sub set_sources {
    my ($sessionid) = @_;
    my @sources = $config->listNodes("$sessionid source");
    my @filters_in;
    my @filters_out;
    if ( is_source_session($sessionid) ) {
        @filters_in  = $config->returnValues("$sessionid filter in");
        @filters_out = $config->returnValues("$sessionid filter out");
    }
    foreach my $source (@sources) {
        modify_source_intf( "set", $sessionid, $source );
        attach_filters_on_intf( $sessionid, $source, \@filters_in, "in" )
          if (@filters_in);
        attach_filters_on_intf( $sessionid, $source, \@filters_out, "out" )
          if (@filters_out);
    }
}

sub modify_destination {
    my ( $action, $sessionid, $destination ) = @_;
    my ( $dstif, $vif ) = split /\./, $destination;
    $vif = 0 unless defined($vif);
    send_cmd_to_controller( $action, "destination", $sessionid, "dstif", $dstif,
        $vif, 0 );
}

sub set_destinations {
    my ($sessionid) = @_;
    my @destinations = $config->returnValues("$sessionid destination");
    foreach my $destination (@destinations) {
        modify_destination( "set", $sessionid, $destination );
    }
}

sub set_session {
    my ($sessionid) = @_;

    # Type is mandatory, and cannot be changed. So only set, no delete or change
    my $type = $config->returnValue("$sessionid type");
    send_cmd_to_controller( "set", "type", $sessionid, "type",
        $session_type{$type}, 0, 0 );

    # erspan header-type and identifier are mandatory for erspan session types,
    # and cannot be changed. So only set, no delete or change.
    if ( $type eq 'erspan-source' || $type eq 'erspan-destination' ) {
        my $identifier = $config->returnValue("$sessionid erspan identifier");
        my $header_type =
          $header_type{ $config->returnValue("$sessionid erspan header") };
        send_cmd_to_controller( "set", "erspan identifier",
            $sessionid, "erspanid", $identifier, 0, 0 );
        send_cmd_to_controller( "set", "erspan header",
            $sessionid, "erspanhdr", $header_type, 0, 0 );
    }

    if ( $config->exists("$sessionid disable") ) {
        modify_disable( $sessionid, "set" );
    }

    set_filters($sessionid) if ( is_source_session($sessionid) );
    set_sources($sessionid);
    set_destinations($sessionid);
}

sub change_sources {
    my ($sessionid) = @_;
    my @delsources = $config->listDeleted("$sessionid source");
    my @filters_in;
    my @filters_out;
    if ( is_source_session($sessionid) ) {
        @filters_in  = $config->returnOrigValues("$sessionid filter in");
        @filters_out = $config->returnOrigValues("$sessionid filter out");
    }
    foreach my $delsource (@delsources) {
        modify_source_intf( "del", $sessionid, $delsource );
        detach_filters_on_intf( $sessionid, $delsource, \@filters_in, "in" )
          if (@filters_in);
        detach_filters_on_intf( $sessionid, $delsource, \@filters_out, "out" )
          if (@filters_out);
    }

    my @sources = $config->listNodes("$sessionid source");
    foreach my $source (@sources) {
        if ( $config->isAdded("$sessionid source $source") ) {
            modify_source_intf( "set", $sessionid, $source );
            attach_filters_on_intf( $sessionid, $source, \@filters_in, "in" )
              if (@filters_in);
            attach_filters_on_intf( $sessionid, $source, \@filters_out, "out" )
              if (@filters_out);
        } elsif ( $config->isChanged("$sessionid source $source") ) {
            modify_source_intf( "set", $sessionid, $source );
        }
    }
}

sub change_destinations {
    my ($sessionid) = @_;
    my @deldestinations = $config->listDeleted("$sessionid destination");
    foreach my $deldestination (@deldestinations) {
        modify_destination( "del", $sessionid, $deldestination );
    }

    my @destinations = $config->returnValues("$sessionid destination");
    foreach my $destination (@destinations) {
        if (   $config->isAdded("$sessionid destination $destination")
            || $config->isChanged("$sessionid destination $destination") )
        {
            modify_destination( "set", $sessionid, $destination );
        }
    }
}

sub change_disable {
    my ($sessionid) = @_;
    if ( $config->isAdded("$sessionid disable") ) {
        modify_disable( $sessionid, "set" );
    } elsif ( $config->isDeleted("$sessionid disable") ) {
        modify_disable( $sessionid, "del" );
    }
}

sub change_filters {
    my ( $sessionid, $filter, $type ) = @_;

    my @filters_in  = $config->returnValues("$sessionid filter in");
    my @filters_out = $config->returnValues("$sessionid filter out");
    my @newfilters_in;
    foreach my $filter (@filters_in) {
        if ( $config->isAdded("$sessionid filter in $filter") ) {
            push( @newfilters_in, $filter );
        }
    }
    my @newfilters_out;
    foreach my $filter (@filters_out) {
        if ( $config->isAdded("$sessionid filter out $filter") ) {
            push( @newfilters_out, $filter );
        }
    }

    my @delfilters_in  = $config->listDeleted("$sessionid filter in");
    my @delfilters_out = $config->listDeleted("$sessionid filter out");

    my @sources = $config->listNodes("$sessionid source");
    foreach my $source (@sources) {
        detach_filters_on_intf( $sessionid, $source, \@delfilters_in, "in" )
          if (@delfilters_in);
        detach_filters_on_intf( $sessionid, $source, \@delfilters_out, "out" )
          if (@delfilters_out);
        attach_filters_on_intf( $sessionid, $source, \@newfilters_in, "in" )
          if (@newfilters_in);
        attach_filters_on_intf( $sessionid, $source, \@newfilters_out, "out" )
          if (@newfilters_out);
    }
    modify_filters( "del", $sessionid, \@delfilters_in, "in" )
      if (@delfilters_in);
    modify_filters( "del", $sessionid, \@delfilters_out, "out" )
      if (@delfilters_out);
    modify_filters( "set", $sessionid, \@newfilters_in, "in" )
      if (@newfilters_in);
    modify_filters( "set", $sessionid, \@newfilters_out, "out" )
      if (@newfilters_out);
}

sub detach_all_filters {
    my ($sessionid) = @_;
    my $commit      = 0;
    my @filters_in  = $config->listDeleted("$sessionid filter in");
    my @filters_out = $config->listDeleted("$sessionid filter out");
    my @sources     = $config->listDeleted("$sessionid source");
    foreach my $source (@sources) {
        detach_filters_on_intf( $sessionid, $source, \@filters_in, "in" )
          if (@filters_in);
        detach_filters_on_intf( $sessionid, $source, \@filters_out, "out" )
          if (@filters_out);
    }
}

sub change_session {
    my ($sessionid) = @_;
    change_disable($sessionid);
    change_sources($sessionid);
    change_destinations($sessionid);
    change_filters($sessionid) if ( is_source_session($sessionid) );
}

sub update_portmonitor {
    my @sessions    = $config->listNodes();
    my @delsessions = $config->listDeleted();

    # Delete session - dataplane code only needs session id to delete session
    foreach my $delsession (@delsessions) {
        detach_all_filters($delsession);
        send_cmd_to_controller( "del", "", $delsession, 0, 0, 0, 0 );
    }

    foreach my $session (@sessions) {
        if ( $config->isAdded($session) ) {
            set_session($session);
        } elsif ( $config->isChanged($session) ) {
            change_session($session);
        }
    }
    commit_filter_changes() if ( $filter_updated > 0 );
}

sub show_allowed_portmonitor_intf {
    return unless eval 'use Vyatta::SwitchConfig qw(is_hw_interface); 1';

    my @interfaces = Vyatta::Misc::getInterfaces();
    my @match;

    foreach my $name (@interfaces) {
        my $intf = new Vyatta::Interface($name);
        next unless $intf;
        next
          unless ( $intf->type() eq 'dataplane'
            || $intf->type() eq 'erspan'
            || $intf->type() eq 'bonding'
            || $intf->type() eq 'vhost' );
        next unless ( !is_hw_interface($name) );
        push @match, $name;
    }
    print join( ' ', @match ), "\n";
}

#
# main
#

my ($action);

GetOptions( "action=s" => \$action, );

die "Undefined action\n" unless defined($action);

update_portmonitor()            if $action eq 'update';
show_allowed_portmonitor_intf() if $action eq 'show_allowed_intf';
