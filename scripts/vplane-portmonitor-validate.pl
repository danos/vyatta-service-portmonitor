#!/usr/bin/perl
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2014-2015 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

#
# Validations to be done:
# * Allowed interfaces
# 	1. Type - span
# 		source - physical and vif
#	 	destination - physical
# 	2. Type - rspan-source
# 		source - physical and vif
# 		destination - vif
# 	3. Type - rspan-destination
#		source - vif
#		destination - physical
#	4. Type - erspan-source
#		source - physical and vif
#		destination - erspan tunnel
#	5. Type - erspan-destination
#		source - erspan tunnel
#		destination - physical
# * Destination interface is not disabled
# * Destination interface cannot have address, ip and ipv6 attributes.
# * Physical destination interface cannot have QoS
# * Allow total distinct 8 source interfaces
# * Source interface != Destination interface
# * Allowed number of destination interfaces = 1 (done in YANG),
#	and cannot be shared between sessions
# * Source interfaces cannot be shared between sessions
# * Source vif for 'rspan-destination' needs to be part of bridge group
# * Destination interface cannot be part of bridge group
# * Limit number of source interfaces of 'rspan-destination' and
#	'erspan-destination' to one
# * Do NOT allow to set direction for source interface of 'rspan-destination'
#	and 'erspan-destination'
# * Do NOT allow configuration where source and/or destination interfaces
#	will be both physical and vif from same physical interface
#	(like 'dp0s7' and 'dp0s7.700' both together should not be allowed)
# * Do NOT allow to delete vif interface which has been configured for
#	portmonitor session. Because vif interface has higher priority than
#	portmonitor session, and when vif interface and portmonitor source
#	interface are deleted, vif is deleted first. We require 'ifp' (which is
#	already deleted) to delete source interface from portmonitor session.
# * Do NOT allow to change the type of the session
# * Do NOT allow to change the 'erspan-identifier' and 'erspan-header' of
#	session having type ERSPAN
#   Source interface is allowed to be a Hardware switched interface for SPAN
#   sessions based on limits defined per platform. The following limits
#   are required to be specified by platforms
# hw_rx_sess_count < Max num of sessions with hardware-switched rx src >
# hw_tx_sess_count < Max num of sessions with hardware-switched tx src >
# hw_sess_count    < Max num of sessions with hardware-switched src >
# hw_rx_src_count  < Max num of hardware-switched rx source across all sessions >
# hw_tx_src_count  < Max num of hardware-switched tx source across all sessions >
#

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Vyatta::Interface;
use Vyatta::SwitchConfig qw(is_hw_interface);
use Vyatta::Platform qw(get_platform_feature_limits);

my $pmconfig = new Vyatta::Config("service portmonitor");
my $dpconfig = new Vyatta::Config("interfaces dataplane");
my $vhconfig = new Vyatta::Config("interfaces vhost");
my $erspanconfig = new Vyatta::Config("interfaces erspan");

my %physrcs = ();
my %vifsrcs = ();
my %phydests = ();
my %vifdests = ();
my %vifwithoutvid = ();
my %erspan_src_tunnels = ();
my %erspan_dest_tunnels = ();
my %src_rx_hw_sessions  = ();
my %src_tx_hw_sessions  = ();
my %plat_init_limits    = (
    'hw_rx_sess_count' => 0,
    'hw_tx_sess_count' => 0,
    'hw_sess_count' => 0,
    'hw_rx_src_count' => 0,
    'hw_tx_src_count' => 0
);
my %plat_limits   = ();
my $src_tx_hw_count = 0;
my $src_rx_hw_count = 0;

sub check_phyintf_already_configured {
    my ( $session, $interface ) = @_;
    die "Interface $interface for session $session is already configured as source interface\n"
      if exists $physrcs{ $interface };
    die "Interface $interface for session $session is already configured as destination interface\n"
      if exists $phydests{ $interface };
}

sub check_vif_already_configured {
    my ( $session, $interface ) = @_;
    die "vif $interface for session $session is already configured as source interface\n"
      if exists $vifsrcs{ $interface };
    die "vif $interface for session $session is already configured as destination interface\n"
      if exists $vifdests{ $interface };
}


sub check_platform_allowed_hw_source {
    my ( $session, $source, $direction, $type ) = @_;
    my $ret = 0;
    my @allmsg;

    return unless is_hw_interface($source);

    if ( $type ne 'span' ) {
        push( @allmsg,
"Session $session with hardware-switched $source can only be of type span\n"
        );
        $ret = 1;
    }
    if ( ( $direction eq 'both' ) || ( $direction eq 'rx' ) ) {
        push @{ $src_rx_hw_sessions{$session} }, $source;
        $src_rx_hw_count++;
    }
    if ( ( $direction eq 'both' ) || ( $direction eq 'tx' ) ) {
        push @{ $src_tx_hw_sessions{$session} }, $source;
        $src_tx_hw_count++;
    }
    if ( keys %src_rx_hw_sessions gt $plat_limits{hw_rx_sess_count} ) {
        push( @allmsg,
"Hardware-switched $source not allowed in session $session, max hw-rx session limit $plat_limits{hw_rx_sess_count}\n"
        );
        $ret = 1;
    }
    if ( keys %src_tx_hw_sessions gt $plat_limits{hw_tx_sess_count} ) {
        push( @allmsg,
"Hardware-switched $source not allowed in session $session, max hw-tx session limit $plat_limits{hw_tx_sess_count}\n"
        );
        $ret = 1;
    }

    my $total_hw_sess =
      ( keys %src_rx_hw_sessions ) + ( keys %src_tx_hw_sessions );

    if ( $total_hw_sess gt $plat_limits{hw_sess_count} ) {
        push( @allmsg,
"Hardware-switched $source not allowed in session $session, max hw session limit $plat_limits{hw_sess_count}\n"
        );
        $ret = 1;
    }
    if ( $src_rx_hw_count gt $plat_limits{hw_rx_src_count} ) {
        push( @allmsg,
"Hardware-switched $source not allowed in session $session, max hw-rx interface limit $plat_limits{hw_rx_src_count}\n"
        );
        $ret = 1;

    }
    if ( $src_tx_hw_count gt $plat_limits{hw_tx_src_count} ) {
        push( @allmsg,
"Hardware-switched $source not allowed in session $session, max hw-tx interface limit $plat_limits{hw_tx_src_count}\n"
        );
        $ret = 1;
    }
    die "@allmsg" if ( $ret eq 1 );
}

sub check_valid_dp_intf {
    my ( $session, $interface, $type ) = @_;
    die "Interface $interface is not a valid interface configured on the system\n"
      unless ( Vyatta::Interface::is_valid_intf_cfg( $interface ) );
    my $intf = new Vyatta::Interface( $interface );
    die "Unknown interface name/type: $interface, needs to be valid dataplane interface\n"
      unless defined($intf);
    die "Interface $interface of session $session is not a valid dataplane interface\n"
      unless ( $intf->type() eq 'dataplane' || $intf->type() eq 'vhost' );
    die "Interface $interface of session $session is not a valid destination interface\n"
      if ( $type eq 'dst' && $intf->type() ne 'dataplane' && $intf->type() ne 'vhost' );
    my $config = new Vyatta::Config( $intf->path() );
    my $bond = $config->returnValue("bond-group");
    die "Invalid dataplane interface: $interface of session $session is a slave of a bonding interface\n"
      if ( $intf->type() eq 'dataplane' && defined($bond) );
}
sub get_intf_config {
    my ( $intf ) = @_;
    my $if = new Vyatta::Interface( $intf );
    my $cfg = $dpconfig;

    if ( $if->type() eq 'vhost' ) {
        $cfg = $vhconfig;
    }
    return $cfg;
}

sub check_valid_vif {
    my ( $config, $session, $intf, $vif ) = @_;
    die "Invalid vif $vif for interface $intf of session $session\n"
      unless ( $config->exists("$intf vif $vif") );

    my $int = new Vyatta::Interface( $intf.$vif );
    die "Unknown interface name/type: $intf.$vif\n"
      unless defined($int);
}

sub check_mandatory_unchanging_nodes {
    my ( $session, $type ) = @_;

    die "Portmonitor session $session does not have type\n"
      unless defined($type);

    my $origtype = $pmconfig->returnOrigValue("session $session type");
    die "Changing the type of the portmonitor session $session is not allowed\n"
      if ( defined($origtype) && $type ne $origtype );

    if ( $type eq 'erspan-source' || $type eq 'erspan-destination' ) {
        my $erspanid = $pmconfig->returnValue("session $session erspan identifier");
        my $erspanhdr = $pmconfig->returnValue("session $session erspan header");

        die "For erspan portmonitor sessions, erspan identifier is mandatory\n"
          unless defined($erspanid);

        my $origerspanid = $pmconfig->returnOrigValue("session $session erspan identifier");
        die "Changing the identifier of the portmonitor session of type erspan is not allowed\n"
          if ( defined($origerspanid) && $erspanid ne $origerspanid );
        my $origerspanhdr = $pmconfig->returnOrigValue("session $session erspan header");
        die "Changing the header-type of the portmonitor session of type erspan is not allowed\n"
          if ( defined($origerspanhdr) && $erspanhdr ne $origerspanhdr );
    }
}

sub check_valid_source_interface {
    my ( $session, $type, $srcinput, $direction ) = @_;
    my ($source, $vif) = split /\./, $srcinput;
    check_valid_dp_intf( $session, $source, 'src' );

    my $existssrc = $pmconfig->exists("session $session source $source");
    die "Delete $source to configure it as vif interface for portmonitor\n"
      if ( defined($vif) && defined($existssrc) );

    my @sourceintfs = $pmconfig->listNodes("session $session source");

    check_phyintf_already_configured( $session, $source );

    if ( $type eq 'rspan-destination' ) {
        die "Only one source interface is allowed for session $session of type 'rspan-destination'\n"
          if ( 1 < @sourceintfs );

        die "Setting the direction for source interface of session $session having type 'rspan-destination' is not allowed\n"
          if ( defined( $pmconfig->exists("session $session source $srcinput direction" ) ) && !defined($pmconfig->isDefault("session $session source $srcinput direction") ) );
    }

    if ( defined($vif) ) {
        my $config = get_intf_config($source);

        check_valid_vif( $config, $session, $source, $vif );
        check_vif_already_configured( $session, $srcinput );

        my $bridge = $config->returnValue("$source vif $vif bridge-group bridge");
        die "Interface $srcinput for portmonitor of type 'rspan-destination' needs to be part of bridge-group\n"
          if ( !defined($bridge) && $type eq 'rspan-destination');

        $vifsrcs{ $srcinput } = undef;
    }

    if ( defined($vif) ) {
        $vifwithoutvid{ $source } = undef;
    } else {
        $physrcs{ $source } = undef;
        die "Interface $source for session $session is already configured as vif interface for same or another session\n"
          if exists $vifwithoutvid{ $source };
    }

    check_platform_allowed_hw_source( $session, $source, $direction, $type );
}

sub check_valid_destination_interface {
    my ( $session, $type, $destinput ) = @_;
    my ($destination, $vif) = split /\./, $destinput;
    my $config = get_intf_config($destination);

    check_valid_dp_intf( $session, $destination, 'dst' );

    die "vif for interface $destination of type rspan-source for session $session is not defined\n"
      if ( !defined($vif) && $type eq 'rspan-source' );
    die "Invalid destination interface $destinput for session $session, needs to be physical\n"
      if ( defined($vif) && ( $type eq 'span' || $type eq 'rspan-destination' || $type eq 'erspan-destination' ) );

    check_phyintf_already_configured( $session, $destination );

    if (defined($vif)) {
        check_valid_vif( $config, $session, $destination, $vif );
        my $keyintf = $destination.'.'.$vif;

        die "Destination interface $destinput for portmonitor is disabled\n"
          if ( defined( $config->exists("$destination vif $vif disable") ) );
        die "Destination interface $destinput for portmonitor cannot be part of bridge-group\n"
          if ( defined( $config->exists("$destination vif $vif bridge-group bridge") ) );
        die "Destination interface $destinput for portmonitor cannot have address configured\n"
          if ( defined( $config->exists("$destination vif $vif address") ) );

        my @ip_properties = $config->listNodes("$destination vif $vif ip");
        foreach my $property (@ip_properties) {
            die "Destination interface $keyintf for portmonitor cannot have any ip attributes\n"
              unless $config->isDefault("$destination vif $vif ip $property");
        }
        my @ipv6_properties = $config->listNodes("$destination vif $vif ipv6");
        foreach my $property (@ipv6_properties) {
            die "Destination interface $keyintf for portmonitor cannot have any ipv6 attributes\n"
              unless $config->isDefault("$destination vif $vif ipv6 $property");
        }

        check_vif_already_configured( $session, $keyintf );
        $vifdests{ $keyintf } = undef;
        $vifwithoutvid{ $destination } = undef;
    } else {
        die "Destination interface $destination for portmonitor is disabled\n"
          if ( defined( $config->exists("$destination disable") ) );
        die "Destination interface $destination for portmonitor cannot be part of bridge-group\n"
          if ( defined( $config->exists("$destination bridge-group bridge") ) );
        die "Destination interface $destination for portmonitor cannot be part of switch-group\n"
          if ( defined( $config->exists("$destination switch-group switch") ) );
        die "Destination interface $destination for portmonitor cannot have address or qos-policy configured\n"
          if ( defined( $config->exists("$destination address") ) || defined( $config->exists("$destination qos-policy") ) );

        my @ip_properties = $config->listNodes("$destination ip");
        foreach my $property (@ip_properties) {
            die "Destination interface $destination for portmonitor cannot have any ip attributes\n"
              unless $config->isDefault("$destination ip $property");
        }
        my @ipv6_properties = $config->listNodes("$destination ipv6");
        foreach my $property (@ipv6_properties) {
            die "Destination interface $destination for portmonitor cannot have any ipv6 attributes\n"
              unless $config->isDefault("$destination ipv6 $property");
        }

        die "Interface $destination for session $session is already configured as vif interface for same or another session\n"
          if exists $vifwithoutvid{ $destination };

        $phydests{ $destination } = undef;
    }

    die "Hardware-switched destination interface $destination not supported for session\n"
	if ( is_hw_interface($destination) )
}

sub check_valid_erspan_tunnel {
    my ( $session, $source ) = @_;

    my $erspantunnel = $erspanconfig->exists("$source");
    die "Interface $source configured for session $session needs to be valid erspan tunnel\n"
      unless defined($erspantunnel);
}

#
# Main section
#

%plat_limits = get_platform_feature_limits('portmonitor', \%plat_init_limits);

foreach my $session ($pmconfig->listNodes("session")) {
    my $type = $pmconfig->returnValue("session $session type");

    check_mandatory_unchanging_nodes( $session, $type );

    my @sources = $pmconfig->listNodes("session $session source");
    die "Only one source interface is allowed for session $session of type $type'\n"
      if ( ( $type eq 'rspan-destination' || $type eq 'erspan-destination' ) && 1 < @sources );

    foreach my $source (@sources) {
        if ( $type eq 'erspan-destination' ) {
            check_valid_erspan_tunnel( $session, $source );

            my ($srcif, $vif) = split /\./, $source;
            die "Setting the vif for tunnel interface of session $session is an invalid configuration\n"
              if ( defined( $vif ) );
            my @tunnels = $pmconfig->listNodes("session $session source $source");
            die "Only one source tunnel interface is allowed for session $session of type 'erspan-destination'\n"
              if ( 1 < @tunnels );
            die "Setting the direction for tunnel interface of session $session having type 'erspan-destination' is not allowed\n"
              if ( defined( $pmconfig->exists( "session $session source $source direction" ) ) && !$pmconfig->isDefault("session $session source $source direction") );
            warn "Warning: Setting ttl on $source of session $session is not recommended\n"
              if ( $erspanconfig->exists("$source ip ttl") && ( !$erspanconfig->isDefault("$source ip ttl") ) );
            warn "Warning: Setting tos on $source of session $session is not recommended\n"
              if ( $erspanconfig->exists("$source ip tos") && ( !$erspanconfig->isDefault("$source ip tos") ) );

            $erspan_src_tunnels { $source } = undef;
        }
        else {
            my $direction = $pmconfig->returnValue(
                "session $session source $source direction");

            if ( !defined($direction) ) {
                $direction = 'both';
            }
            check_valid_source_interface( $session, $type, $source,
                $direction );
        }
        die "Only 8 distinct source interfaces are allowed to configure\n"
          unless ( ( (keys%physrcs) + (keys%vifsrcs) + (keys%erspan_src_tunnels) ) < 9 );
    }

    my @destinations = $pmconfig->returnValues("session $session destination");
    foreach my $destination (@destinations) {
        if ( $type eq 'erspan-source' ) {
            check_valid_erspan_tunnel( $session, $destination );
            die "Destination interface $destination of portmonitor session $session is disabled\n"
              if ( defined( $erspanconfig->exists("$destination disable") ) );
            $erspan_dest_tunnels { $destination } = undef;
        } else {
            check_valid_destination_interface( $session, $type, $destination );
        }
    }

    my @delsources = $pmconfig->listDeleted("session $session source");
    foreach my $delsource (@delsources) {
        my $config = get_intf_config($delsource);

        my ($srcif, $vif) = split /\./, $delsource;
        die "Cannot delete vif interface $delsource configured for portmonitor session $session\n"
          if ( defined($vif) && !$config->exists("$srcif vif $vif") );
    }

    my @filters_in = $pmconfig->returnValues("session $session filter in");
    my @filters_out = $pmconfig->returnValues("session $session filter out");
    die "Filters are not allowed for session $session of type $type'\n"
      if ( ( $type eq 'rspan-destination' || $type eq 'erspan-destination' ) && ( @filters_in || @filters_out ) );

}

exit 0;
