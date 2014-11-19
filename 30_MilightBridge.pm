# $Id$
##############################################
#
#     30_MilightBridge.pm (Use with 31_MilightDevice.pm)
#     FHEM module for Milight Wifi bridges which control Milight lightbulbs.
#     
#     Author: Matthew Wire (mattwire)
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################

package main;

use strict;
use warnings;

use IO::Handle;
use IO::Socket;
use IO::Select;
use Time::HiRes;
use Net::Ping;

sub MilightBridge_Initialize($)
{
  my ($hash) = @_;

  # Provider
  # $hash->{ReadFn}  = "MilightBridge_Read";
  $hash->{WriteFn}  = "MilightBridge_Write";
  $hash->{Clients} = ":Milight:";

  #Consumer
  $hash->{DefFn}    = "MilightBridge_Define";
  $hash->{UndefFn}  = "MilightBridge_Undefine";
  $hash->{NotifyFn} = "MilightBridge_Notify";
  $hash->{AttrFn}   = "MilightBridge_Attr";
  $hash->{AttrList} = "sendInterval ".$readingFnAttributes;

  return undef;
}

#####################################
# Define bridge device
sub MilightBridge_Define($$)
{
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def); 

  return "Usage: define <name> MilightBridge <host/ip>"  if(@args < 3);

  my ($name, $type, $host) = @args;

  # Parameters
  $hash->{HOST} = $host;
  $hash->{PORT} = 8899;

  # Create local socket    
  my $sock = IO::Socket::INET-> new (
      PeerPort => 48899,
      Blocking => 0,
      Proto => 'udp',
      Broadcast => 1) or return "can't bind: $@";
  my $select = IO::Select->new($sock);
  $hash->{SOCKET} = $sock;
  $hash->{SELECT} = $select;

  # Note: Milight API specifies 100ms bridge delay for sending commands
  # Define sendInterval
  $attr{$name}{"sendInterval"} = 100 if (!defined($attr{$name}{"sendInterval"}));
  $hash->{INTERVAL} = $attr{$name}{"sendInterval"};
  
  # Create command queue to hold commands
  my @cmdQueue = ();
  $hash->{cmdQueue} = \@cmdQueue;
  $hash->{cmdQueueLock} = 0;
  $hash->{cmdLastSent} = gettimeofday();

  # Set Attributes
  $attr{$name}{"event-on-change-reading"} = "state" if (!defined($attr{$name}{"event-on-change-reading"}));

  # Set state
  $hash->{SENDFAIL} = 0;
  MilightBridge_State($hash);

  return undef;
}

#####################################
# Undefine Bridge device
sub MilightBridge_Undefine($$)
{
  my ($hash,$arg) = @_;
  RemoveInternalTimer($hash);
  
  return undef;
}

#####################################
# Manage attribute changes
sub MilightBridge_Attr($$$$) {
  my ($command,$name,$attribute,$value) = @_;
  my $hash = $defs{$name};
  
  Log3 ($hash, 5, "$hash->{NAME}_Attr: Attr $attribute; Value $value");
  
  # Handle "sendInterval" attribute which defaults to 100(ms)
  if ($attribute eq "sendInterval")
  {
    if (($value !~ /^\d*$/) || ($value < 1))
    {
      $attr{$name}{"sendInterval"} = 100;
      $hash->{INTERVAL} = $attr{$name}{"sendInterval"};
      return "sendInterval is required in ms (default: 100)";
    }
    else
    {
      $hash->{INTERVAL} = $attr{$name}{"sendInterval"};
    }
  }

  return undef;  
}

#####################################
# Update slot information when a global notify event is fired
sub MilightBridge_Notify($$)
{
  my ($hash,$dev) = @_;
  Log3 ($hash, 5, "$hash->{NAME}_Notify: Triggered by $dev->{NAME}");
  
  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG|DEFINED$/, @{$dev->{CHANGED}}));

  MilightBridge_SlotUpdate($hash);
  
  return undef;
}

#####################################
# Update readings to show status of bridge
sub MilightBridge_State(@)
{
  # Update Bridge state
  my ($hash) = @_;
  
  Log3 ( $hash, 5, "$hash->{NAME}_State: Checking Bridge Status");
  
  # Do a ping check to see if bridge is reachable
  # check via ping
  my $pingstatus = "on";
  my $p = Net::Ping->new('udp');
  if( $p->ping($hash->{HOST}, 2)) {
      $pingstatus = "on";
  } else {
      $pingstatus = "off";
  }
  $p->close();
  # And update state
  readingsSingleUpdate($hash, "state", $pingstatus, 1);
  
  # Update send fail flag
  readingsSingleUpdate( $hash, "sendFail", $hash->{SENDFAIL}, 1 );

  # Check state every 10 seconds  
  InternalTimer(gettimeofday() + 10, "MilightBridge_State", $hash, 0);
  
  return undef;
}

#####################################
# Update readings to show which slots have devices defined
sub MilightBridge_SlotUpdate(@)
{
  # Update readings to show what is connected to which slot
  my ($hash) = @_;
  
  Log3 ( $hash, 5, "$hash->{NAME}_State: Updating Slot readings");

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "slot0", $hash->{0}->{NAME});
  readingsBulkUpdate($hash, "slot1", $hash->{1}->{NAME});
  readingsBulkUpdate($hash, "slot2", $hash->{2}->{NAME});
  readingsBulkUpdate($hash, "slot3", $hash->{3}->{NAME});
  readingsBulkUpdate($hash, "slot4", $hash->{4}->{NAME});
  readingsBulkUpdate($hash, "slot5", $hash->{5}->{NAME});
  readingsBulkUpdate($hash, "slot6", $hash->{6}->{NAME});
  readingsBulkUpdate($hash, "slot7", $hash->{7}->{NAME});
  readingsBulkUpdate($hash, "slot8", $hash->{8}->{NAME});
  readingsEndUpdate($hash, 1);
  
  return undef;
}

#####################################
# Device write function.  Receives a command and triggers the send queue
sub MilightBridge_Write(@)
{
  # Client sent a new command
  my ($hash, $cmd) = @_;
  
  Log3 ($hash, 3, "$hash->{NAME}_Write: Command not defined") if (!defined($cmd));
  my $hexStr = unpack("H*", $cmd || '');
  Log3 ($hash, 4, "$hash->{NAME}_Write: Command: $hexStr");
  
  # Add command to queue
  push @{$hash->{cmdQueue}}, $cmd;


  MilightBridge_CmdQueue_Send($hash);
}

#####################################
# Send a queued command to the bridge hardware
sub MilightBridge_CmdQueue_Send(@)
{
  my ($hash) = @_;
  
  # Check that queue is not locked. If it is we should just return because another instance of this function has locked it.
  if ($hash->{cmdQueueLock} != 0)
  {
    Log3 ($hash, 5, "$hash->{NAME}_cmdQueue_Send: Send Queue Locked: cmdQueueLock = $hash->{cmdQueueLock}. Return.");
    return undef;    
  }
  
  # Check if we are called again before send interval has elapsed
  my $now = gettimeofday();
  if (($hash->{cmdLastSent} + ($hash->{INTERVAL} / 1000)) < $now)
  {
    # Lock cmdQueue
    $hash->{cmdQueueLock} = 1;

    # Extract current command
    my $command = @{$hash->{cmdQueue}}[0];

    # Check if we have any commands in queue
    if (!defined($command))
    {
      Log3 ($hash, 5, "$hash->{NAME}_cmdQueue_Send: No commands in queue");
    }
    else
    {
      # Send the command
      my $hexStr = unpack("H*", $command || '');
      Log3 ($hash, 5, "$hash->{NAME} send: $hexStr@".gettimeofday()."; Queue Length: ".@{$hash->{cmdQueue}});

      my $portaddr = sockaddr_in($hash->{PORT}, inet_aton($hash->{HOST}));
      if (!send($hash->{SOCKET}, $command, 0, $portaddr))
      {
        # Send failed
        Log3 ($hash, 3, "$hash->{NAME} Send FAILED! ".gettimeofday().":$hexStr. Queue Length: ".@{$hash->{cmdQueue}});
        $hash->{SENDFAIL} = 1;
      }
      else
      {
        # Send successful
        $hash->{cmdLastSent} = gettimeofday(); # Update time last sent
        shift @{$hash->{cmdQueue}}; # transmission complete, remove command from queue
      }
    }  
  }
  else
  {
    # We were called again before send interval elapsed
    Log3 ($hash, 5, "$hash->{NAME}_cmdQueue_Send: Waiting for send interval. cmdLastSent: $hash->{cmdLastSent}. Now: $now");
  }
  
  # Unlock cmdQueue
  $hash->{cmdQueueLock} = 0;

  # Set next cycle if there are commands in the queue
  if (@{$hash->{cmdQueue}} > 0)
  {
    # INTERVAL is in msec, need to add seconds to gettimeofday (eg 100/1000 = 0.1 seconds)
    #Log3 ($hash, 5, "$hash->{NAME}_cmdQueue_Send: cmdLastSent: $hash->{cmdLastSent}; Next: ".(gettimeofday()+($hash->{INTERVAL}/1000)));

    # Remove any existing timers and trigger a new one
    foreach my $args (keys %intAt) 
    {
      if (($intAt{$args}{ARG} eq $hash) && ($intAt{$args}{FN} eq 'MilightBridge_CmdQueue_Send'))
      {
        Log3 ($hash, 5, "$hash->{NAME}_CmdQueue_Send: Remove timer at: ".$intAt{$args}{TRIGGERTIME});
        delete($intAt{$args});
      }
    }
    InternalTimer(gettimeofday()+($hash->{INTERVAL}/1000), "MilightBridge_CmdQueue_Send", $hash, 0);
  }
  
  return undef;

}

1;
