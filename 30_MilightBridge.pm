# $Id$
##############################################
#
#     30_MilightBridge.pm
#     FHEM module for Milight Wifi bridges which control Milight lightbulbs.
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
  $hash->{AttrList} = $readingFnAttributes;

  return undef;
}

sub
MilightBridge_Define($$)
{
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def); 

  return "Usage: define <name> MilightBridge <host/ip> [interval(100ms)]"  if(@args < 3);

  my ($name, $type, $host, $interval) = @args;

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

  # Milight API specifies 100ms delay for sending commands
  $interval = 100 unless defined($interval);
  if( $interval < 100 ) { $interval = 100; }
  $hash->{INTERVAL} = $interval;
  
  
  # Create command queue to hold commands
  my @cmdQueue = ();
  $hash->{cmdQueue} = \@cmdQueue;
  $hash->{cmdQueueLock} = 0;
  $hash->{cmdLastSent} = gettimeofday();

  # Set Attributes
  $attr{$name}{"event-on-change-reading"} = "state";

  # Set state
  MilightBridge_State($hash);
  readingsSingleUpdate( $hash, "sendFail", "0", 1 );

  return undef;
}

sub MilightBridge_Undefine($$)
{
  my ($hash,$arg) = @_;
  RemoveInternalTimer($hash);
  
  return undef;
}

sub
MilightBridge_Notify($$)
{
  my ($hash,$dev) = @_;
  Log3 ($hash, 5, "$hash->{NAME}_Notify: Entered with $dev");
  
  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG|DEFINED$/, @{$dev->{CHANGED}}));

  MilightBridge_SlotUpdate($hash);
  
  return undef;
}

sub
MilightBridge_Write(@)
{
  # Client sent a new command
  my ($hash, $cmd) = @_;
  
  Log3 ($hash, 3, "$hash->{NAME}_Write: Command not defined") if (!defined($cmd));
  my $hexStr = unpack("H*", $cmd || '');
  Log3 ($hash, 4, "$hash->{NAME}_Write: Command: $hexStr");
  
  # Add command to queue
  push @{$hash->{cmdQueue}}, $cmd;

  MilightBridge_cmdQueue_Send($hash);
}

sub MilightBridge_State(@)
{
  # Update Bridge state
  my ($hash) = @_;
  
  Log3 ( $hash, 5, "$hash->{NAME}_State: Checking state");
  
  # Do a ping check to see if bridge is reachable
    # check via ping
  my $pingstatus = "on";
  my $p = Net::Ping->new( 'udp' );
  if( $p->ping( $hash->{HOST}, 2 ) ) {
      $pingstatus = "on";
  } else {
      $pingstatus = "off";
  }
  # close our ping mechanism again
  $p->close( );
  readingsSingleUpdate($hash, "state", $pingstatus, 1);

  readingsSingleUpdate($hash, "Slot0", $hash->{0}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot1", $hash->{1}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot2", $hash->{2}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot3", $hash->{3}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot4", $hash->{4}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot5", $hash->{5}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot6", $hash->{6}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot7", $hash->{7}->{NAME}, 1);
  readingsSingleUpdate($hash, "Slot8", $hash->{8}->{NAME}, 1);


  # Check state every 10 seconds  
  InternalTimer(gettimeofday() + 10, "MilightBridge_State", $hash, 0);
  
  return undef;
}

sub MilightBridge_SlotUpdate(@)
{
  # Update Bridge state
  my ($hash) = @_;
  
  Log3 ( $hash, 5, "$hash->{NAME}_State: Updating Slot readings");

  readingsSingleUpdate($hash, "slot0", $hash->{0}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot1", $hash->{1}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot2", $hash->{2}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot3", $hash->{3}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot4", $hash->{4}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot5", $hash->{5}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot6", $hash->{6}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot7", $hash->{7}->{NAME}, 1);
  readingsSingleUpdate($hash, "slot8", $hash->{8}->{NAME}, 1);
  
  return undef;
}

sub MilightBridge_cmdQueue_Timer(@)
{
  # Set timer to trigger next send
  my ($hash) = @_;
  
  # INTERVAL is in msec, need to add seconds to gettimeofday (eg 100/1000 = 0.1 seconds)
  InternalTimer(gettimeofday()+($hash->{INTERVAL}/1000), "MilightBridge_cmdQueue_Send", $hash, 0);
  
  return undef;
}

sub
MilightBridge_cmdQueue_Send(@)
{
  my ($hash) = @_;
  
  # Check that queue is not locked. If it is we should just return because another instance of this function has locked it.
  if ($hash->{cmdQueueLock} != 0)
  {
    Log3 ($hash, 5, "$hash->{NAME}_cmdQueue_Send: Called but cmdQueueLock = $hash->{cmdQueueLock}. Return.");
    return undef;    
  }
  
  # Check if we are called again before send interval has elapsed
  if ($hash->{cmdLastSent} > (gettimeofday() + ($hash->{INTERVAL} / 1000)))
  {
    Log3 ($hash, 5, "$hash->{NAME}_cmdQueue_Send: Called before send interval elapsed. cmdLastSent: $hash->{cmdLastSent}. Now: ".gettimeofday());
    return MilightBridge_cmdQueue_Timer($hash);
  }
  
  # Extract current command
  my $command = @{$hash->{cmdQueue}}[0];
  
  # Check if we have any commands in queue
  if (!defined($command))
  {
    Log3 ($hash, 5, "$hash->{NAME}_cmdQueue_Send: No commands in queue");
    return undef;
  }
  
  # Lock cmdQueue
  $hash->{cmdQueueLock} = 1;
  
  # Send command
  my $hexStr = unpack("H*", $command || '');
  Log3 ($hash, 5, "$hash->{NAME} send: ".gettimeofday().":$hexStr. Queue Length: ".@{$hash->{cmdQueue}});

  my $portaddr = sockaddr_in($hash->{PORT}, inet_aton($hash->{HOST}));
  if (!send($hash->{SOCKET}, $command, 0, $portaddr))
  {
    # Send failed
    Log3 ($hash, 3, "$hash->{NAME} Send FAILED! ".gettimeofday().":$hexStr. Queue Length: ".@{$hash->{cmdQueue}});
    $hash->{SENDFAIL} = 1;
  }
  else
  {
    # Send success
    # transmission complete, remove
    shift @{$hash->{cmdQueue}};
  }
  
  # Unlock cmdQueue
  $hash->{cmdQueueLock} = 0;
  
  # Set next cycle
  return MilightBridge_cmdQueue_Timer($hash);

}

1;
