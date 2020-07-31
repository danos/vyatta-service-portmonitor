# Module: PortMonitor.pm
# Functions to get Portmonitor info needed by other modules
#
# Copyright (c) 2020 AT&T Intellectual Property.
#    All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::PortMonitor;
use Readonly;
use strict;
use warnings;
use Vyatta::Configd;
require Exporter;

our @ISA       = qw (Exporter);
our @EXPORT_OK = qw (get_portmonitor_destination_intflist);

#
# Get all the interfaces that are configured as destination for
# all portmonitor sessions
#
sub get_portmonitor_destination_intflist {
    my $config   = new Vyatta::Config("service portmonitor session");
    my @sessions = $config->listNodes();
    my @destintfs;
    my @session_dest;

    foreach my $session (@sessions) {
        my @session_dest = $config->returnValues("$session destination");
        push( @destintfs, @session_dest );
    }
    return @destintfs;
}
