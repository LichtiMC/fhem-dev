##############################################
# $Id: 32_WifiLight.pm 68 2013-12-08 08:00:00Z herrmannj $

# TODO
# color picker
# color adjustments / attrib
# doku
# adjust gamma defaults milight
# implement get 
# * get rgb / RGB
# * get state: return usefull data about actuals, also trigger c1:.*

# versions
# 51 new milight color converter
# 52 timing for transitions: drop frames if required
# 53 transition names and events
# 54 drop frames ll add-on / lock ll queue
# 55 add ll queue lock count
# 56 RGB in
# 57 bridge v2
# 58 gamma correction 
# 59 fix "off" with ramp
# 60 add dimup/dimdown
# 61 introduce dimSteps
# 62 introduce defaultColor
# 63 LW12 define if lw12 is unavailable at startup
# 64 transition with ramp 0 fixed
# 65 some typos with impact to RGBW1 and RGBW2
# 66 readings: lower camelCase and limited trigger
# 67 restore state after startup
# 68 LW12 reconnect after timeout


# verbose level
# 0: quit
# 1: error
# 2: warning
# 3: user command
# 4: 1st technical level (detailed internal reporting)
# 5: 2nd technical level (full internal reporting)

package main;

use strict;
use warnings;

use IO::Handle;
use IO::Socket;
use IO::Select;
use Time::HiRes;



sub
WifiLight_Initialize(@)
{

  my ($hash) = @_;

  $hash->{DefFn}   = "WifiLight_Define";
  $hash->{UndefFn} = "WifiLight_Undef";
  $hash->{ShutdownFn} = "WifiLight_Undef";
  $hash->{SetFn} = "WifiLight_Set";
  $hash->{GetFn} = "WifiLight_Get";
  $hash->{AttrFn} = "WifiLight_Attr";
  $hash->{NotifyFn}  = "WifiLight_Notify";
  $hash->{FW_summaryFn} = "WifiLight_FW_summary";
  $hash->{AttrList}     = "widget:0,1 gamma dimStep defaultColor";

  return undef;
}

sub
WifiLight_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def); 
  my $name = $a[0];
  my $key;

  return "wrong syntax: define <name> WifiLight <type> <connection>" if(@a != 4);
  return "unknown LED type ($a[2]): choose one of RGB, RGBW1, RGBW2, White" if !($a[2] ~~ ['RGB', 'RGBW1', 'RGBW2', 'White']); 
  
  $hash->{LEDTYPE} = $a[2];
  my $otherLights;

  if ($a[3] =~ m/(bridge-V2):([^:]+):*(\d+)*/g)
  {
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:50000;
    my @hlCmdQueue = [];
    $hash->{helper}->{hlCmdQueue} = \@hlCmdQueue;
    # $hash->{SERVICE} = 48899; unkown for v2
    # search if this bridge is already defined 
    # if so, we need a shared buffer (llCmdQueue), shared socket and we need to check if the requied slot is free
    foreach $key (keys %defs) 
    {
      if (($defs{$key}{TYPE} eq 'WifiLight') && ($defs{$key}{IP} eq $hash->{IP}) && ($key ne $name))
      {
        #bridge is in use
        Log3 (undef, 3, "WifiLight: requested bridge $hash->{CONNECTION} at $hash->{IP} already in use by $key, copy llCmdQueue");
        $hash->{helper}->{llCmdQueue} = $defs{$key}{helper}{llCmdQueue};
        $hash->{helper}->{llLock} = 0;
        $hash->{helper}->{SOCKET} = $defs{$key}{helper}{SOCKET};
        $hash->{helper}->{SELECT} = $defs{$key}{helper}{SELECT};
        my $slotInUse = $defs{$key}{SLOT};
        $otherLights->{$slotInUse} = $defs{$key};
      }
    } 
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => 48899,
        Blocking => 0,
        Proto => 'udp',
        Broadcast => 1) or return "can't bind: $@";
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      my @llCmdQueue = ();
      $hash->{helper}->{llCmdQueue} = \@llCmdQueue;
      $hash->{helper}->{llLock} = 0;
    }
  }

  if ($a[3] =~ m/(bridge-V3):([^:]+):*(\d+)*/g)
  {
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:8899;
    my @hlCmdQueue = [];
    $hash->{helper}->{hlCmdQueue} = \@hlCmdQueue;
    # $hash->{SERVICE} = 48899;
    # search if this bridge is already defined 
    # if so, we need a shared buffer (llCmdQueue), shared socket and we need to check if the requied slot is free
    foreach $key (keys %defs) 
    {
      if (($defs{$key}{TYPE} eq 'WifiLight') && ($defs{$key}{IP} eq $hash->{IP}) && ($key ne $name))
      {
        #bridge is in use
        Log3 (undef, 3, "WifiLight: requested bridge $hash->{CONNECTION} at $hash->{IP} already in use by $key, copy llCmdQueue");
        $hash->{helper}->{llCmdQueue} = $defs{$key}{helper}{llCmdQueue};
        $hash->{helper}->{llLock} = 0;
        $hash->{helper}->{SOCKET} = $defs{$key}{helper}{SOCKET};
        $hash->{helper}->{SELECT} = $defs{$key}{helper}{SELECT};
        my $slotInUse = $defs{$key}{SLOT};
        $otherLights->{$slotInUse} = $defs{$key};
      }
    } 
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => 48899,
        Blocking => 0,
        Proto => 'udp',
        Broadcast => 1) or return "can't bind: $@";
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      my @llCmdQueue = ();
      $hash->{helper}->{llCmdQueue} = \@llCmdQueue;
      $hash->{helper}->{llLock} = 0;
    }
  }
  
  if ($a[3] =~ m/(LW12):([^:]+):*(\d+)*/g)
  {
    return "only RGB supported by LW12" if ($a[2] ne "RGB"); 
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:5577;
    #$hash->{SERVICE} = 48899;
    $hash->{SLOT} = 0;
    my @hlCmdQueue = [];
    $hash->{helper}->{hlCmdQueue} = \@hlCmdQueue;
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      my @llCmdQueue = ();
      $hash->{helper}->{llCmdQueue} = \@llCmdQueue;
      $hash->{helper}->{llLock} = 0;
    }
  }
  return "unknown connection type: choose one of bridge-V3:<ip> LW12:<ip>" if !(defined($hash->{CONNECTION})); 

  Log3 ($hash, 4, "define $a[0] $a[1] $a[2] $a[3]");

  if (($hash->{LEDTYPE} eq 'RGB') && ($hash->{CONNECTION} =~ 'LW12'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB";
    return undef;
  }

  if ((($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW1')) && ($hash->{CONNECTION} =~ 'bridge-V[2|3]'))
  {
    return "no free slot at $hash->{CONNECTION} ($hash->{IP}) for $hash->{LEDTYPE}" if (defined($otherLights->{0}));
    $hash->{SLOT} = 0;
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 1);
    $hash->{helper}->{COLORMAP} = WifiLight_Milight_ColorConverter($hash);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB sync pair unpair";
    #if we are allready paired: sync to get a defined state
    return WifiLight_RGB_Sync($hash) if ($hash->{LEDTYPE} eq 'RGB');
    return WifiLight_RGBW1_Sync($hash) if ($hash->{LEDTYPE} eq 'RGBW1');
  }
  elsif (($hash->{LEDTYPE} eq 'RGBW2')  && ($hash->{CONNECTION} =~ 'bridge-V3'))
  {
    # find a free slot
    my $i = 5;
    while (defined($otherLights->{$i}))
    {
      $i++;
    }
    if ( grep { $i == $_ } 5..8 )
    { 
      $hash->{SLOT} = $i;
      $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.73);
      $hash->{helper}->{COLORMAP} = WifiLight_Milight_ColorConverter($hash);
      $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB sync pair unpair";
      return WifiLight_RGBW2_Sync($hash);
    }
    else
    {
      return "no free slot at $hash->{CONNECTION} ($hash->{IP}) for $hash->{LEDTYPE}";
    }
  }
  elsif (($hash->{LEDTYPE} eq 'White')  && ($hash->{CONNECTION} =~ 'bridge-V[2|3]'))
  {
    # find a free slot
    my $i = 1;
    while (defined($otherLights->{$i}))
    {
      $i++;
    }
    if ( grep { $i == $_ } 1..4 )
    { 
      $hash->{SLOT} = $i;
      $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.8);
      $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown sync pair unpair";
      return WifiLight_White_Sync($hash);
    }
    else
    {
      return "no free slot at $hash->{CONNECTION} ($hash->{IP}) for $hash->{LEDTYPE}";
    }
  }
  return "$hash->{LEDTYPE} is not supported at $hash->{CONNECTION} ($hash->{IP})";
}

sub
WifiLight_Undef(@)
{
  return undef;
}

sub
WifiLight_Set(@)
{
  my ($ledDevice, $name, $cmd, @args) = @_;
  my $cnt = @args;
  my $ramp = 0;
  my $flags = "";
  my $event = undef;

  return "unknown command ($cmd): choose one of ".join(", ", $ledDevice->{helper}->{COMMANDSET}) if ($cmd eq "?"); 
  return "unknown command ($cmd): choose one of ".$ledDevice->{helper}->{COMMANDSET} if not ( grep { $cmd eq $_ } split(" ", $ledDevice->{helper}->{COMMANDSET} ));

  if ($cmd eq 'pair')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name pair [seconds]" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGB_Pair($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Pair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_Pair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Pair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'unpair')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name unpair [seconds]" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGB_UnPair($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_UnPair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_UnPair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_UnPair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'sync')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    return WifiLight_RGB_Sync($ledDevice) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Sync($ledDevice) if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_Sync($ledDevice) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Sync($ledDevice) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'on')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name on [seconds]" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGBLW12_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGB_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_On($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_On($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_On($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'off')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name off [seconds]" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGBLW12_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGB_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Off($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_Off($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Off($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'dimup')
  {
    return "usage: set $name dimup" if (defined($args[1]));
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    my $v = ReadingsVal($ledDevice->{NAME}, "brightness", 0) + AttrVal($ledDevice->{NAME}, "dimStep", 7);
    $v = 100 if $v > 100;
    return WifiLight_RGBLW12_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGB_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Dim($ledDevice, $v, 0, '') if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_Dim($ledDevice, $v, 0, '') if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Dim($ledDevice, $v, 0, '') if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'dimdown')
  {
    return "usage: set $name dimdown" if (defined($args[1]));
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    my $v = ReadingsVal($ledDevice->{NAME}, "brightness", 0) - AttrVal($ledDevice->{NAME}, "dimStep", 7);
    $v = 0 if $v < 0;
    return WifiLight_RGBLW12_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGB_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Dim($ledDevice, $v, 0, '') if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_Dim($ledDevice, $v, 0, '') if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Dim($ledDevice, $v, 0, '') if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'dim')
  {
    return "usage: set $name dim level [seconds]" if ($args[0] !~ /^\d+$/);
    return "usage: set $name dim level [seconds]" if !($args[0] ~~ [0..100]);
    if (defined($args[1]))
    {
      return "usage: set $name dim level [seconds] [q]" if ($args[1] !~ /^\d+$/);
      $ramp = $args[1];
    }
    if (defined($args[2]))
    {   
      return "usage: set $name dim level seconds [q]" if ($args[2] !~ m/.*[qQ].*/);
      $flags = $args[2];
    }
    WifiLight_HighLevelCmdQueue_Clear($ledDevice) if ($flags !~ m/.*[qQ].*/);
    return WifiLight_RGBLW12_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGB_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Dim($ledDevice, $args[0], $ramp, $flags) if ($ledDevice->{LEDTYPE} eq 'RGBW1');
    return WifiLight_RGBW2_Dim($ledDevice, $args[0], $ramp, $flags) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Dim($ledDevice, $args[0], $ramp, $flags) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if (($cmd eq 'HSV') || ($cmd eq 'RGB'))
  {
    my ($hue, $sat, $val);
    
    if ($cmd eq 'HSV')
    {
      return "HSV is required as h,s,v" if ($args[0] !~ /^\d{1,3},\d{1,3},\d{1,3}$/);
      ($hue, $sat, $val) = split(',', $args[0]);
      return "wrong hue ($hue): valid range 0..360" if !(($hue >= 0) && ($hue <= 360));
      return "wrong saturation ($sat): valid range 0..100" if !(($sat >= 0) && ($sat <= 100));
      return "wrong brightness ($val): valid range 0..100" if !(($val >= 0) && ($val <= 100));
    }
    elsif ($cmd eq 'RGB')
    {
      return "RGB is required hex RRGGBB" if ($args[0] !~ /^[0-9A-Fa-f]{6}$/);
      ($hue, $sat, $val) = WifiLight_RGB2HSV($ledDevice, $args[0]);
    }
    
    if (defined($args[1]))
    {
      return "usage: set $name HSV H,S,V seconds flags programm" if ($args[1] !~ /^\d+$/);
      $ramp = $args[1];
    }
    if (defined($args[2]))
    {   
      return "usage: set $name HSV H,S,V seconds [slq] programm" if ($args[2] !~ m/.*[sSlLqQ].*/);
      $flags = $args[2];
    }
    if (defined($args[3]))
    {   
      return "usage: set $name HSV H,S,V seconds flags programm=[A-Za-z_0-9]" if ($args[3] !~ m/[A-Za-z_0-9]*/);
      $event = $args[3];
    }
    WifiLight_HighLevelCmdQueue_Clear($ledDevice) if ($flags !~ m/.*[qQ].*/);
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 50, $event) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 500, $event) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 500, $event) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ramp > 30));
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 1000, $event) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ramp <= 30));
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 200, $event) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_SetHSV_Target($ledDevice, $hue, $sat, $val);
  }
}

sub
WifiLight_Get(@)
{
  my ($ledDevice, $name, $cmd, @args) = @_;
  my $cnt = @args;
  
  return undef;
}

sub
WifiLight_Attr(@)
{
  my ($cmd, $device, $attribName, $attribVal) = @_;
  my $ledDevice = $defs{$device};

  if ($cmd eq 'set' && $attribName eq 'gamma')
  {
    return "gamma is required as numerical value (eg. 0.5 or 2.2)" if ($attribVal !~ /^\d*\.\d*$/);
    $ledDevice->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($ledDevice, $attribVal);
  }
  if ($cmd eq 'set' && $attribName eq 'dimStep')
  {
    return "dimStep is required as numerical value [1..100]" if ($attribVal !~ /^\d*$/) || (($attribVal < 1) || ($attribVal > 100));
  }
  if ($cmd eq 'set' && $attribName eq 'defaultColor')
  {
    return "defaultColor is required as HSV" if ($attribVal !~ /^\d{1,3},\d{1,3},\d{1,3}$/);
    my ($hue, $sat, $val) = split(',', $attribVal);
    return "defaultColor: wrong hue ($hue): valid range 0..360" if !(($hue >= 0) && ($hue <= 360));
    return "defaultColor: wrong saturation ($sat): valid range 0..100" if !(($sat >= 0) && ($sat <= 100));
    return "defaultColor: wrong brightness ($val): valid range 0..100" if !(($val >= 0) && ($val <= 100));
  }
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} attrib $attribName $cmd $attribVal"); 
  return undef;
}

# restore previous settings (as set statefile)
sub
WifiLight_Notify(@)
{
  my ($ledDevice, $eventSrc) = @_;
  my $events = deviceEvents($eventSrc, 1);
  my ($hue, $sat, $val);

  # wait for global: INITIALIZED after start up
  if ($eventSrc->{NAME} eq 'global' && @{$events}[0] eq 'INITIALIZED')
  {
    #######################################################
    # TODO remove in a few weeks. its here for convenience
    delete($ledDevice->{READINGS}->{HUE});
    delete($ledDevice->{READINGS}->{SATURATION});
    delete($ledDevice->{READINGS}->{BRIGHTNESS});
    #######################################################
    if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12')) 
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBLW12_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:60;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:100;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:100;
      return WifiLight_RGB_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:50;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:100;
      return WifiLight_RGBW1_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBW2_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'White')&& ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:100;
      return WifiLight_White_setHSV($ledDevice, $hue, $sat, $val);
    }   
    else
    {
    }
    return 
  }
}

###############################################################################
#
# device specific controller functions RGB LW12
# LED Stripe controller LW12
#
#
###############################################################################

sub
WifiLight_RGBLW12_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c", 0xCC, 0x23, 0x33);
  my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  my $receiver;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  # WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12 set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 50, undef);
}

#TODO set physical off: my $off = sprintf("%c%c%c", 0xCC, 0x24, 0x33);
sub
WifiLight_RGBLW12_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12 set off $ramp");
  return WifiLight_RGBLW12_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBLW12_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12 dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 50, undef);
}

sub
WifiLight_RGBLW12_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 15;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB LW12 set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];
  # convert to device specs
  my ($r, $g, $b) = WifiLight_HSV2RGB($hue, $sat, $gammaVal);
  my $msg = sprintf("%c%c%c%c%c", 0x56, $r, $g, $b, 0xAA);
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions RGB
# LED Stripe or bulb, no white, controller V2
#
###############################################################################

sub
WifiLight_RGB_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LED slot $ledDevice->{SLOT} pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGB_UnPair(@)
{
  my ($ledDevice) = @_;
  my $numSeconds = 8;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 LED slot $ledDevice->{SLOT} unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGB_Sync(@)
{
  my ($ledDevice) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;

  $ledDevice->{helper}->{whiteLevel} =9; 
  $ledDevice->{helper}->{colorLevel} =9;
  $ledDevice->{helper}->{colorValue} =127; 
  $ledDevice->{helper}->{mode} =2; # mode 0: off, 1: mixed "white", 2: color
 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, 500); # on
  for (my $i = 0; $i < 22; $i++) {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode up (to "pure white" ;-) 
  }
  for (my $i = 0; $i < 10; $i++) {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up (to "pure white" ;-) 
  }
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20\x7F\x55", $receiver, $delay); # color yellow (auto jump to mode 2)
  for (my $i = 0; $i < 10; $i++) {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up (yellow max brightness) 
  }

  return undef;
}

sub
WifiLight_RGB_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "40,100,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 500, undef);
}

sub
WifiLight_RGB_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set off $ramp");
  return WifiLight_RGB_Dim($ledDevice, 0, $ramp, '');
  #TODO remove if tested
  #return WifiLight_HSV_Transition($ledDevice, 0, 100, 0, $ramp, undef, 500, undef);
}

sub
WifiLight_RGB_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 500, undef);
}

sub
WifiLight_RGB_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set h:$hue, s:$sat, v:$val"); 
  $sat = 100;
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # convert to device specs
  my ($cv, $cl, $wl) = WifiLight_RGBW1_ColorConverter($ledDevice, $hue, $sat, $val);
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set levels: $cv, $cl, $wl");
  return WifiLight_RGB_setLevels($ledDevice, $cv, $cl, $wl);
}

sub
WifiLight_RGB_setLevels(@)
{
  my ($ledDevice, $cv, $cl, $wl) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;
  my $lock = 0;

  # mode 0: off, 1: mixed "white", 2: color
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || ($ledDevice->{helper}->{colorLevel} != $cl) || ($ledDevice->{helper}->{whiteLevel} != $wl))
  {
    $ledDevice->{helper}->{llLock} += 1;
    $lock = 1;
  }
  # need to touch color value (only if visible) or color level ?
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || $ledDevice->{helper}->{colorLevel} != $cl)
  {
    # if color all off switch on
    if ($ledDevice->{helper}->{mode} == 0)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # switch on
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{colorLevel} = 1;
      $ledDevice->{helper}->{mode} = 2;
    }
    elsif ($ledDevice->{helper}->{mode} == 1)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{mode} = 2;
    }
    else
    {
      $ledDevice->{helper}->{colorValue} = $cv;
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
    }
    # cl decrease
    if ($ledDevice->{helper}->{colorLevel} > $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i > $cl; $i--) 
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x24\x00\x55", $receiver, $delay); # brightness down
        $ledDevice->{helper}->{colorLevel} = $i - 1;
      }
      if ($cl == 0)
      {
        # need to switch off color
        # if no white is required and no white is active we can must entirely switch off
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x21\x00\x55", $receiver, $delay); # switch off
        $ledDevice->{helper}->{colorLevel} = 0;
        $ledDevice->{helper}->{mode} = 0;
      }
    }
    # cl inrease
    if ($ledDevice->{helper}->{colorLevel} < $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i < $cl; $i++)
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # brightness up
        $ledDevice->{helper}->{colorLevel} = $i + 1;
      }
    }
  }
  # unlock ll queue
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1) if $lock;
  return undef;
}

###############################################################################
#
# device specific controller functions RGBW1 
# LED Stripe with extra white led, controller V2, bridge V2|bridge V3
#
#
###############################################################################

sub
WifiLight_RGBW1_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 LED slot $ledDevice->{SLOT} pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW1_UnPair(@)
{
  my ($ledDevice) = @_;
  my $numSeconds = 8;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 LED slot $ledDevice->{SLOT} unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW1_Sync(@)
{
  my ($ledDevice) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;

  $ledDevice->{helper}->{whiteLevel} =9; 
  $ledDevice->{helper}->{colorLevel} =9;
  $ledDevice->{helper}->{colorValue} =170; 
  $ledDevice->{helper}->{mode} =3; # mode 0: c:off, w:off; 1: c:on, w:off; 2: c:off, w:on; 3: c:on, w:on
 
  #WifiLight_setHSV_Readings($ledDevice, 0, 50, 100);

  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, 500); # on
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # on
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20\xAA\x55", $receiver, $delay); # color red (auto jump to mode 1 except we are mode 3)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (now we are for sure in mode 1)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #1
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #2
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #3
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #4
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #5
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #6
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #7
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #8 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #9 (highest dim-level color red)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (pure white) 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #1
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #2
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #3
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #4
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #5
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #6
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #7
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #8
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #9 (highest dim-level white)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (white and red at highest level: bright warm light) 

  return undef;
}

sub
WifiLight_RGBW1_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 500, undef);
}

sub
WifiLight_RGBW1_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set off $ramp");
  return WifiLight_RGBW1_Dim($ledDevice, 0, $ramp, '');
  #TODO remove if tested
  #return WifiLight_HSV_Transition($ledDevice, 0, 80, 0, $ramp, undef, 500, undef);
}

sub
WifiLight_RGBW1_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 500, undef);
}

sub
WifiLight_RGBW1_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # convert to device specs
  my ($cv, $cl, $wl) = WifiLight_RGBW1_ColorConverter($ledDevice, $hue, $sat, $val);
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set levels: $cv, $cl, $wl");
  return WifiLight_RGBW1_setLevels($ledDevice, $cv, $cl, $wl);
}

sub
WifiLight_RGBW1_setLevels(@)
{
  my ($ledDevice, $cv, $cl, $wl) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;
  my $lock = 0;

  # need to touch color value or color level?
  # yes
  # is color visible ? (we are in mode 1 or 3)
  #   yes: adjust color!, requ level = 1 if cl = 0; new level 0 ? yes: mode 0 if wl == 0 else Mode = 1 (if coming from 0 or 1 then wl =1)
  #   no:
  #     will we need color ?
  #       yes: go into mode #1, (cl jumps to 1)

  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || ($ledDevice->{helper}->{colorLevel} != $cl) || ($ledDevice->{helper}->{whiteLevel} != $wl))
  {
    $ledDevice->{helper}->{llLock} += 1;
    $lock = 1;
  }

  # need to touch color value (only if visible) or color level ?
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || $ledDevice->{helper}->{colorLevel} != $cl)
  {
    # if color all off switch on
    if ($ledDevice->{helper}->{mode} == 0)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # switch on
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down: 3 > 2 || 2 > 1
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down: 2 > 1 || 1 > 1
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{colorLevel} = 1;
      $ledDevice->{helper}->{mode} = 1;
    }
    elsif ($ledDevice->{helper}->{mode} == 2)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up: 2 > 3
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{colorLevel} = 1;
      $ledDevice->{helper}->{mode} = 3;
    }
    else
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
    }

    # color level decrease
    if ($ledDevice->{helper}->{colorLevel} > $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i > $cl; $i--) 
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x24\x00\x55", $receiver, $delay); # brightness down
        $ledDevice->{helper}->{colorLevel} = $i - 1;
      }
      if ($cl == 0)
      {
        # need to switch off color
        # if no white is required and no white is active switch off
        if (($wl == 0) && ($ledDevice->{helper}->{mode} == 1))
        {
          WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x21\x00\x55", $receiver, $delay); # switch off
          $ledDevice->{helper}->{colorLevel} = 0;
          $ledDevice->{helper}->{mode} = 0;
        }
        # if white is required, goto mode 2: pure white
        if (($wl > 0) || ($ledDevice->{helper}->{mode} == 2) ||  ($ledDevice->{helper}->{mode} == 3))
        {
          WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay) if ($ledDevice->{helper}->{mode} == 1) ; # mode up
          WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay) if ($ledDevice->{helper}->{mode} == 3) ; # mode down
          $ledDevice->{helper}->{colorLevel} = 0;
          $ledDevice->{helper}->{whiteLevel} = 1 if ($ledDevice->{helper}->{mode} == 1);
          $ledDevice->{helper}->{mode} = 2;
        }
      }
    }
    if ($ledDevice->{helper}->{colorLevel} < $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i < $cl; $i++)
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # brightness up
        $ledDevice->{helper}->{colorLevel} = $i + 1;
      }
    }
  }
  # need to adjust white level ?
  if ($ledDevice->{helper}->{whiteLevel} != $wl)
  {
    # white off but need adjustment ? set it on..
    # color processing is finished, so if we are in mode 0, no color required. go to mode 2: pure white
    if ($ledDevice->{helper}->{mode} == 0)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # switch on
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (3 -> 2 || 2 -> 1)
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (2 -> 1 || 1 -> 1)
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (1 -> 2)
      $ledDevice->{helper}->{whiteLevel} = 1;
      $ledDevice->{helper}->{mode} = 2;
    }
    # color processing is finished, so if we are at mode 1 color is required. go to mode 2
    if ($ledDevice->{helper}->{mode} == 1)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (1 -> 2)
      $ledDevice->{helper}->{whiteLevel} = 1;
      $ledDevice->{helper}->{mode} = 2; 
    }
    # temporary go to mode 2 while maintain white level
    if ($ledDevice->{helper}->{mode} == 3)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (3 -> 2)
      $ledDevice->{helper}->{mode} = 2; 
    }
    # white level inrease
    for (my $i=$ledDevice->{helper}->{whiteLevel}; $i < $wl; $i++)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # brightness up
      $ledDevice->{helper}->{whiteLevel} = $i + 1;
    }
    # white level decrease
    if ($ledDevice->{helper}->{whiteLevel} > $wl)
    {
      for (my $i=$ledDevice->{helper}->{whiteLevel}; $i > $wl; $i--) 
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x24\x00\x55", $receiver, $delay); # brightness down
        $ledDevice->{helper}->{whiteLevel} = $i - 1;
      }
    }

    # assume we are at mode 2, finishing to correct mode
    if (($wl == 0) && ($cl == 0))
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x21\x00\x55", $receiver, $delay); # switch off
      $ledDevice->{helper}->{whiteLevel} = 0;
      $ledDevice->{helper}->{mode} = 0;
    }
    if (($wl == 0) && ($cl > 0))
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (2 -> 1)
      $ledDevice->{helper}->{whiteLevel} = 0;
      $ledDevice->{helper}->{mode} = 1; 
    }
    if (($wl > 0) && ($cl > 0))
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (2 -> 3)
      $ledDevice->{helper}->{mode} = 3; 
    }
  }
  # unlock ll queue
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1) if $lock;
  return undef;
}

sub
WifiLight_RGBW1_ColorConverter(@)
{
  my ($ledDevice, $h, $s, $v) = @_;
  my $color = $ledDevice->{helper}->{COLORMAP}[$h % 360];
  
  # there are 0..9 dim level, setup correction
  my $valueSpread = 100/9;
  my $totalVal = int(($v / $valueSpread) +0.5);
  # saturation 100..50: color full, white increase. 50..0 white full, color decrease
  my $colorVal = ($s >= 50) ? $totalVal : int(($s / 50 * $totalVal) +0.5);
  my $whiteVal = ($s >= 50) ? int(((100-$s) / 50 * $totalVal) +0.5) : $totalVal;
  return ($color, $colorVal, $whiteVal);
}

###############################################################################
#
# device specific functions RGBW2 bulb 
# RGB white, only bridge V3
#
#
###############################################################################

sub
WifiLight_RGBW2_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW2_UnPair(@)
{
  my ($ledDevice, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW2_Sync(@)
{
  my ($ledDevice) = @_;
  # force new settings
  $ledDevice->{helper}->{mode} = -1; 
  $ledDevice->{helper}->{colorValue} = -1; 
  $ledDevice->{helper}->{colorLevel} = -1;
  $ledDevice->{helper}->{whiteLevel} = -1;
  return undef;
}

sub
WifiLight_RGBW2_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 200, undef);
}

sub
WifiLight_RGBW2_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} set off $ramp");
  return WifiLight_RGBW2_Dim($ledDevice, 0, $ramp, '');
  #TODO remove if tested
  #return WifiLight_HSV_Transition($ledDevice, 0, 0, 0, $ramp, undef, 500, undef);
}

sub
WifiLight_RGBW2_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} dim $level $ramp ". $flags || ''); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 200, undef);
}

sub
WifiLight_RGBW2_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my ($cl, $wl);

  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  my @bulbCmdsOff = ("\x46", "\x48", "\x4A", "\x4C");
  my @bulbCmdsWT = ("\xC5", "\xC7", "\xC9", "\xCB");

  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;
  my $cv = $ledDevice->{helper}->{COLORMAP}[$hue % 360];

  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];

  # mode 0 = off, 1 = color, 2 = white
  # brightness 2..27 (x02..x1b) | 25 
  my $cf = 100 / 25;
  my $cb = int(($gammaVal / $cf) + 0.5);
  $cb += ($cb > 0)?2:0;

  if ($sat < 20) 
  {
    $wl = $cb;
    $cl = 0;
    WifiLight_setHSV_Readings($ledDevice, $hue, 0, $val);
  }
  else
  {
    $cl = $cb;
    $wl = 0;
    WifiLight_setHSV_Readings($ledDevice, $hue, 100, $val);
  }

  return if (($ledDevice->{helper}->{colorValue} == $cv) && ($ledDevice->{helper}->{colorLevel} == $cl) && ($ledDevice->{helper}->{whiteLevel} == $wl));

  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} lock queue ".$ledDevice->{helper}->{llLock});

  if (($wl == 0) && ($cl ==0) && ($ledDevice->{helper}->{mode} != 0))
  {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOff[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay);
    $ledDevice->{helper}->{whiteLevel} = 0;
    $ledDevice->{helper}->{colorLevel} = 0;
    $ledDevice->{helper}->{mode} = 0; # group off
  }
  else
  {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay) if (($wl > 0) || ($cl > 0)); # group on
    if (($wl > 0) && ($ledDevice->{helper}->{mode} != 2)) # not white
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsWT[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay); # white
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($wl)."\x55", $receiver, $delay); # brightness
      $ledDevice->{helper}->{mode} = 2; # white
    }
    elsif (($wl > 0) && ($ledDevice->{helper}->{mode} == 2)) # already white
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($wl)."\x55", $receiver, $delay) if ($ledDevice->{helper}->{whiteLevel} != $wl); # brightness
    }
    elsif (($cl > 0) && ($ledDevice->{helper}->{mode} != 1)) # not color
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x40".chr($cv)."\x55", $receiver, $delay); # color
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($cl)."\x55", $receiver, $delay); # brightness
      $ledDevice->{helper}->{mode} = 1; # color
    }
    elsif (($cl > 0) && ($ledDevice->{helper}->{mode} == 1)) # already color
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($cl)."\x55", $receiver, $delay) if ($ledDevice->{helper}->{colorLevel} != $cl); # brightness
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x40".chr($cv)."\x55", $receiver, $delay) if ($ledDevice->{helper}->{colorValue} != $cv); # color
    }
    $ledDevice->{helper}->{colorValue} = $cv;
    $ledDevice->{helper}->{colorLevel} = $cl;
    $ledDevice->{helper}->{whiteLevel} = $wl;
  }
  # unlock ll queue after complete cmd is send
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
  return undef;
}

###############################################################################
#
# device specific functions white bulb 
# warm white / cold white with dim, bridge V2|bridge V3
#
#
###############################################################################

sub
WifiLight_White_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 1 if !(defined($numSeconds));
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: pair $numSeconds");
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_White_UnPair(@)
{
  my ($ledDevice, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
  }
  return undef;
}

sub
WifiLight_White_Sync(@)
{
  my ($ledDevice) = @_;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsFB = ("\xB8", "\xBD", "\xB7", "\xB2");
  
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;

  $ledDevice->{helper}->{whiteLevel} =11; 

  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: sync"); 

  WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
  WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsFB[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # full brightness

  return undef;
}

sub
WifiLight_White_On(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} white slot $ledDevice->{SLOT} set on $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, 0, 0, 100, $ramp, '', 500, undef);
}

sub
WifiLight_White_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} white slot $ledDevice->{SLOT} set off $ramp"); 
  return WifiLight_RGBW2_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_White_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} white slot $ledDevice->{SLOT} dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 300, undef);
}

# only val supported, 
# TODO hue will become colortemp
sub
WifiLight_White_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $wlStep = (100 / 11);
  WifiLight_setHSV_Readings($ledDevice, 0, 0, $val);
  $val = int(($val / $wlStep) +0.5);
  WifiLight_White_setLevels($ledDevice, undef, $val);
  
  return undef;
}

sub
WifiLight_White_setLevels(@)
{
  my ($ledDevice, $cv, $wl) = @_;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsOff = ("\x3B", "\x33", "\x3A", "\x36");
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;

  if ($ledDevice->{helper}->{whiteLevel} > $wl)
  {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
    for (my $i=$ledDevice->{helper}->{whiteLevel}; $i > $wl; $i--) 
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x34\x00\x55", $receiver, $delay); # brightness down
      $ledDevice->{helper}->{whiteLevel} = $i - 1;
    }
    if ($wl == 0)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOff[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group off
    }
  }
   
  if ($ledDevice->{helper}->{whiteLevel} < $wl)
  {
    $ledDevice->{helper}->{whiteLevel} = 1 if ($ledDevice->{helper}->{whiteLevel} == 0);
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
    for (my $i=$ledDevice->{helper}->{whiteLevel}; $i < $wl; $i++) 
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x3C\x00\x55", $receiver, $delay); # brightness up
      $ledDevice->{helper}->{whiteLevel} = $i + 1;
    }
  }
  return undef;
}

###############################################################################
#
# device indepenent routines
#
###############################################################################

# dispatcher
sub
WifiLight_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  WifiLight_RGBLW12_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
  WifiLight_RGB_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
  WifiLight_RGBW1_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{LEDTYPE} eq "RGBW1");
  WifiLight_RGBW2_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{LEDTYPE} eq "RGBW2");
  WifiLight_White_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{LEDTYPE} eq "White");
  return undef;
}

# dispatcher
sub
WifiLight_processEvent(@)
{
  my ($ledDevice, $event, $progress) = @_;
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} processEvent: $event, progress: $progress") if defined($event);
  DoTrigger($ledDevice->{NAME}, "programm: $event $progress",0) if defined($event);
  #WifiLight_RGBLW12_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
  #WifiLight_RGB_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
  #WifiLight_RGBW1_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{LEDTYPE} eq "RGBW1");
  #WifiLight_RGBW2_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{LEDTYPE} eq "RGBW2");
  #WifiLight_White_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{LEDTYPE} eq "White");
  return undef;
}

sub
WifiLight_HSV_Transition(@)
{
  my ($ledDevice, $hue, $sat, $val, $ramp, $flags, $delay, $event) = @_;
  my ($hueFrom, $satFrom, $valFrom, $timeFrom);
  
  # minimum stepwide
  my $defaultDelay = $delay;

  #TODO remove if tested
  #if (($ramp || 0) == 0)
  #{
  #  Log3 ($ledDevice, 4, "$ledDevice->{NAME} hsv transition without ramp routed to direct settings, hsv $hue, $sat, $val");
  #  $ledDevice->{helper}->{targetTime} = gettimeofday();
  #  return WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $delay, undef, undef, $ledDevice->{helper}->{targetTime});
  #}

  # if queue in progess set start vals to last cached hsv target, else set start to actual hsv
  if (@{$ledDevice->{helper}->{hlCmdQueue}} > 0)
  {
    $hueFrom = $ledDevice->{helper}->{targetHue};
    $satFrom = $ledDevice->{helper}->{targetSat};
    $valFrom = $ledDevice->{helper}->{targetVal};
    $timeFrom = $ledDevice->{helper}->{targetTime};
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} prepare start hsv transition (is cached) hsv $hueFrom, $satFrom, $valFrom, $timeFrom");
  }
  else
  {
    $hueFrom = $ledDevice->{READINGS}->{hue}->{VAL};
    $satFrom = $ledDevice->{READINGS}->{saturation}->{VAL};
    $valFrom = $ledDevice->{READINGS}->{brightness}->{VAL};
    $timeFrom = gettimeofday();
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} prepare start hsv transition (is actual) hsv $hueFrom, $satFrom, $valFrom, $timeFrom");
  }

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} current HSV $hueFrom, $satFrom, $valFrom");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} set HSV $hue, $sat, $val with ramp: $ramp, flags: ". $flags);

  # if there is no ramp we dont need transition
  if (($ramp || 0) == 0)
  {
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} hsv transition without ramp routed to direct settings, hsv $hue, $sat, $val");
    $ledDevice->{helper}->{targetTime} = $timeFrom;
    return WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $delay, 100, $event, $timeFrom);
  }

  # calculate the left and right turn length based
  # startAngle +360 -endAngle % 360 = counter clock
  # endAngle +360 -startAngle % 360 = clockwise
  my $fadeLeft = ($hueFrom + 360 - $hue) % 360;
  my $fadeRight = ($hue + 360 - $hueFrom) % 360;
  my $direction = ($fadeLeft <=> $fadeRight); # -1 = counterclock, +1 = clockwise
  $direction = ($direction == 0)?1:$direction; # in dupt cw
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} color rotation dev cc:$fadeLeft, cw:$fadeRight, shortest:$direction"); 
  $direction *= -1 if ($flags =~ m/.*[lL].*/); # reverse if long path desired (flag l or L is set)

  my $rotation = ($direction == 1)?$fadeRight:$fadeLeft; # angle of hue rotation in based on flags
  my $sFade = abs($sat - $satFrom);
  my $vFade = abs($val - $valFrom);
        
  my ($stepWide, $steps, $hueToSet, $hueStep, $satToSet, $satStep, $valToSet, $valStep);
  
  # fix if there is in fact no transition, blocks queue for given ramp time with actual hsv values
  if ($rotation == 0 && $sFade == 0 && $vFade == 0)
  {
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} hsv transition with unchaned settings, hsv $hue, $sat, $val, ramp $ramp"); 
    #TODO remove if tested 
    #WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $ramp * 1000, 0, $event, $timeFrom);
    
    $ledDevice->{helper}->{targetTime} = $timeFrom + $ramp;
    return WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $delay, 100, $event, $timeFrom + $ramp);
  }

  if ($rotation >= ($sFade || $vFade))
  {
    $stepWide = ($ramp * 1000 / $rotation); # how long is one step (set hsv) in ms based on hue
    $stepWide = $defaultDelay if ($stepWide < $defaultDelay);
    $steps = int($ramp * 1000 / $stepWide); # how many steps will we need ?
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} transit (H>S||V) steps: $steps stepwide: $stepWide");  
  }
  elsif ($sFade  >= ($rotation || $vFade))
  {
    $stepWide = ($ramp * 1000 / $sFade); # how long is one step (set hsv) in ms based on sat
    $stepWide = $defaultDelay if ($stepWide < $defaultDelay);
    $steps = int($ramp * 1000 / $stepWide); # how many steps will we need ?
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} transit (S>H||V) steps: $steps stepwide: $stepWide");  
  }
  else
  {
    $stepWide = ($ramp * 1000 / $vFade); # how long is one step (set hsv) in ms based on val
    $stepWide = $defaultDelay if ($stepWide < $defaultDelay);
    $steps = int($ramp * 1000 / $stepWide); # how many steps will we need ?
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} transit (V>H||S) steps: $steps stepwide: $stepWide");  
  }
        
  $hueToSet = $hueFrom; # prepare tmp working hue
  $hueStep = $rotation / $steps * $direction; # how big is one hue step base on timing choosen
          
  $satToSet = $satFrom; # prepare workin sat
  $satStep = ($sat - $satFrom) / $steps;
          
  $valToSet = $valFrom;
  $valStep = ($val - $valFrom) / $steps;

  #TODO do something more flexible
  #TODO remove if tested
  # $timeFrom += 1;

  for (my $i=1; $i <= $steps; $i++)
  {
    $hueToSet += $hueStep;
    $hueToSet -= 360 if ($hueToSet > 360); #handle turn over zero
    $hueToSet += 360 if ($hueToSet < 0);
    $satToSet += $satStep;
    $valToSet += $valStep;
    my $progress = 100 / $steps * $i;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} add to hl queue h:".($hueToSet).", s:".($satToSet).", v:".($valToSet)." ($i/$steps)");  
    WifiLight_HighLevelCmdQueue_Add($ledDevice, int($hueToSet +0.5), int($satToSet +0.5), int($valToSet +0.5), undef, $stepWide, int($progress +0.5), $event, $timeFrom + (($i-1) * $stepWide / 1000) );
  }
  $ledDevice->{helper}->{targetTime} = $timeFrom + $ramp;
  return undef;
}

sub
WifiLight_SetHSV_Target(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  $ledDevice->{helper}->{targetHue} = $hue;
  $ledDevice->{helper}->{targetSat} = $sat;
  $ledDevice->{helper}->{targetVal} = $val;
  return undef;
}

sub
WifiLight_setHSV_Readings(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my ($r, $g, $b) = WifiLight_HSV2RGB($hue, $sat, $val);
  readingsBeginUpdate($ledDevice);
  readingsBulkUpdate($ledDevice, "hue", $hue % 360);
  readingsBulkUpdate($ledDevice, "saturation", $sat);
  readingsBulkUpdate($ledDevice, "brightness", $val);
  readingsBulkUpdate($ledDevice, "RGB", sprintf("%02X%02X%02X",$r,$g,$b));
  readingsBulkUpdate($ledDevice, "state", "on") if ($val > 0);
  readingsBulkUpdate($ledDevice, "state", "off") if ($val == 0);
  readingsEndUpdate($ledDevice, 0);
  DoTrigger($ledDevice->{NAME}, "c1:$hue,$sat,$val,$r,$g,$b",1);
}

sub
WifiLight_HSV2RGB(@)
{
  my ($hue, $sat, $val) = @_;

  $val = int(($val * 2.55) +0.5);
  if ($sat == 0) 
  {
    return int($val), int($val), int($val);
  }
  $hue %= 360;
  $hue /= 60;

  my $i = int($hue);

  my $f = $hue - $i;
  my $p = $val * (1 - $sat / 100);
  my $q = $val * (1 - $sat / 100 * $f);
  my $t = $val * (1 - $sat / 100 * (1 - $f));

  if ( $i == 0 )
  {
    return int($val), int($t), int($p);
  }
  elsif ( $i == 1 )
  {
    return int($q), int($val), int($p);
  }
  elsif ( $i == 2 ) 
  {
    return int($p), int($val), int($t);
  }
  elsif ( $i == 3 ) 
  {
    return int($p), int($q), int($val);
  }
  elsif ( $i == 4 )
  {
    return int($t), int($p), int($val);
  }
  else
  {
    return int($val), int($p), int($q);
  }
}

sub
WifiLight_RGB2HSV(@)
{
  my ($ledDevice, $in) = @_;
  my $r = hex substr($in, 0, 2);
  my $g = hex substr($in, 2, 2);
  my $b = hex substr($in, 4, 2);
  my ($max, $min, $delta);
  my ($h, $s, $v);

  $max = $r if ($r >= ($g||$b));
  $max = $g if ($g >= ($r||$b));
  $max = $b if ($b >= ($r||$g));
  $min = $r if (($r <= $g) && ($r <= $b));
  $min = $g if (($g <= $r) && ($g <= $b));
  $min = $b if (($b <= $r) && ($b <= $g));

  $v = int(($max / 2.55) + 0.5);  
  $delta = $max - $min;

  my $currentHue = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  return ($currentHue, 0, $v) if (($max == 0) || ($delta == 0));

  $s = int((($delta / $max) *100) + 0.5);
  $h = ($g - $b) / $delta if ($r == $max);
  $h = 2 + ($b - $r) / $delta if ($g == $max);
  $h = 4 + ($r - $g) / $delta if ($b == $max);
  $h = int(($h * 60) + 0.5);
  $h += 360 if ($h < 0);
  return $h, $s, $v;
}

sub
WifiLight_Milight_ColorConverter(@)
{
  my ($ledDevice) = @_;

  my @colorMap;
  
  my $hueRed = 0;
  my $adjRed = $hueRed;

  my $hueYellow = 60;
  my $adjYellow = $hueYellow;

  my $hueGreen = 120;
  my $adjGreen = $hueGreen;

  my $hueCyan = 180;
  my $adjCyan = $hueCyan;

  my $hueBlue = 240;
  my $adjBlue = $hueBlue;

  my $hueLilac = 300;
  my $adjLilac = $hueLilac;

  my $devRed = 176;
  #my $devYellow = 128;
  my $devYellow = 144;
  my $devGreen = 96;
  #my $devCyan = 48;
  my $devCyan = 56;
  my $devBlue = 16;
  my $devLilac = 224;

  my $i= 360;

  # red to yellow
  $adjRed += 360 if ($adjRed < 0); # in case of negative adjustment
  $devRed += 256 if ($devRed < $devYellow);
  $adjYellow += 360 if ($adjYellow < $adjRed);
  for ($i = $adjRed; $i <= $adjYellow; $i++)
  {
    $colorMap[$i % 360] = ($devRed - int((($devRed - $devYellow) / ($adjYellow - $adjRed)  * ($i - $adjRed)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #yellow to green
  $devYellow += 256 if ($devYellow < $devGreen);
  $adjGreen += 360 if ($adjGreen < $adjYellow);
  for ($i = $adjYellow; $i <= $adjGreen; $i++)
  {
    $colorMap[$i % 360] = ($devYellow - int((($devYellow - $devGreen) / ($adjGreen - $adjYellow)  * ($i - $adjYellow)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #green to cyan
  $devGreen += 256 if ($devGreen < $devCyan);
  $adjCyan += 360 if ($adjCyan < $adjGreen);
  for ($i = $adjGreen; $i <= $adjCyan; $i++)
  {
    $colorMap[$i % 360] = ($devGreen - int((($devGreen - $devCyan) / ($adjCyan - $adjGreen)  * ($i - $adjGreen)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #cyan to blue
  $devCyan += 256 if ($devCyan < $devCyan);
  $adjBlue += 360 if ($adjBlue < $adjCyan);
  for ($i = $adjCyan; $i <= $adjBlue; $i++)
  {
    $colorMap[$i % 360] = ($devCyan - int((($devCyan - $devBlue) / ($adjBlue - $adjCyan)  * ($i - $adjCyan)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #blue to lilac
  $devBlue += 256 if ($devBlue < $devLilac);
  $adjLilac += 360 if ($adjLilac < $adjBlue);
  for ($i = $adjBlue; $i <= $adjLilac; $i++)
  {
    $colorMap[$i % 360] = ($devBlue - int((($devBlue - $devLilac) / ($adjLilac - $adjBlue)  * ($i- $adjBlue)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #lilac to red
  $devLilac += 256 if ($devLilac < $devRed);
  $adjRed += 360 if ($adjRed < $adjLilac);
  for ($i = $adjLilac; $i <= $adjRed; $i++)
  {
    $colorMap[$i % 360] = ($devLilac - int((($devLilac - $devRed) / ($adjRed - $adjLilac)  * ($i - $adjLilac)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }

  return \@colorMap;
}

sub
WifiLight_CreateGammaMapping(@)
{
  my ($ledDevice, $gamma) = @_;

  my @gammaMap;

  for (my $i = 0; $i <= 100; $i += 1)
  {
    my $correction = ($i / 100) ** (1 / $gamma); 
    $gammaMap[$i] = $correction * 100;
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} create gammamap v-in: ".$i.", v-out: $gammaMap[$i]");
  } 

  return \@gammaMap;
}

###############################################################################
#
# high level queue, long running color transitions
#
###############################################################################

sub
WifiLight_HighLevelCmdQueue_Add(@)
{
  my ($ledDevice, $hue, $sat, $val, $ctrl, $delay, $progress, $event, $targetTime) = @_;
  my $cmd;

  $cmd->{hue} = $hue;
  $cmd->{sat} = $sat;
  $cmd->{val} = $val;
  $cmd->{ctrl} = $ctrl;
  $cmd->{delay} = $delay;
  $cmd->{progress} = $progress;
  $cmd->{event} = $event;
  $cmd->{targetTime} = $targetTime;
  $cmd->{inProgess} = 0;

  push @{$ledDevice->{helper}->{hlCmdQueue}}, $cmd;

  my $dbgStr = unpack("H*", $cmd->{ctrl} || '');
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue add hsv/ctrl $cmd->{hue}, $cmd->{sat}, $cmd->{val}, ctrl $dbgStr, targetTime $cmd->{targetTime}, qlen ".@{$ledDevice->{helper}->{hlCmdQueue}});

  my $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];

  # sender busy ?
  return undef if (($actualCmd->{inProgess} || 0) == 1);
  return WifiLight_HighLevelCmdQueue_Exec($ledDevice);
}

sub
WifiLight_HighLevelCmdQueue_Exec(@)
{
  my ($ledDevice) = @_; 
  my $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];

  # transmission complete, remove
  shift @{$ledDevice->{helper}->{hlCmdQueue}} if ($actualCmd->{inProgess});

  # next in queue
  $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];
  my $nextCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[1];

  # return if no more elements in queue
  return undef if (!defined($actualCmd->{inProgess}));

  # drop frames if next frame is already sceduled for given time. do not drop if it is the last frame or if it is a command  
  while (defined($nextCmd->{targetTime}) && ($nextCmd->{targetTime} < gettimeofday()) && !$actualCmd->{ctrl})
  {
    shift @{$ledDevice->{helper}->{hlCmdQueue}};
    $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];
    $nextCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[1];
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue exec drop frame at hlQueue level. hl qlen: ".@{$ledDevice->{helper}->{hlCmdQueue}});
  }
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} high level cmd queue exec dropper delay: ".($actualCmd->{targetTime} - gettimeofday()) );

  # set hsv or if a device ctrl command is sceduled: send it and ignore hsv
  if ($actualCmd->{ctrl})
  {
    my $dbgStr = unpack("H*", $actualCmd->{ctrl});
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue exec ctrl $dbgStr, qlen ".@{$ledDevice->{helper}->{hlCmdQueue}}); 
    WifiLight_sendCtrl($ledDevice, $actualCmd->{ctrl});
  }
  else
  {
    if (($ledDevice->{helper}->{llLock} == 0) || (@{$ledDevice->{helper}->{hlCmdQueue}} == 1))
    {
      Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue exec hsv $actualCmd->{hue}, $actualCmd->{sat}, $actualCmd->{val}, delay $actualCmd->{delay}, hl qlen ".@{$ledDevice->{helper}->{hlCmdQueue}}.", ll qlen ".@{$ledDevice->{helper}->{llCmdQueue}}.", lock ".$ledDevice->{helper}->{llLock});
      WifiLight_setHSV($ledDevice, $actualCmd->{hue}, $actualCmd->{sat}, $actualCmd->{val});
    }
    else
    {
      Log3 ($ledDevice, 5, "$ledDevice->{NAME} high level cmd queue exec drop frame at llQueue level. ll qlen: ".@{$ledDevice->{helper}->{llCmdQueue}}.", lock ".$ledDevice->{helper}->{llLock});
    }
  }
  $actualCmd->{inProgess} = 1;
  my $next = defined($nextCmd->{targetTime})?$nextCmd->{targetTime}:gettimeofday() + ($actualCmd->{delay} / 1000);
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue ask next $next");
  InternalTimer($next, "WifiLight_HighLevelCmdQueue_Exec", $ledDevice, 0);
  WifiLight_processEvent($ledDevice, $actualCmd->{event}, $actualCmd->{progress});
  return undef;
}

sub
WifiLight_HighLevelCmdQueue_Clear(@)
{
  my ($ledDevice) = @_;
  foreach my $a (keys %intAt) 
  {
    if (($intAt{$a}{ARG} eq $ledDevice) && ($intAt{$a}{FN} eq 'WifiLight_HighLevelCmdQueue_Exec'))
    {

      Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue clear, remove timer at ".$intAt{$a}{TRIGGERTIME} );
      delete($intAt{$a}) ;
    }
  }
  $ledDevice->{helper}->{hlCmdQueue} = [];
}

# dispatcher for ctrl cmd
sub
WifiLight_sendCtrl(@)
{
  my ($ledDevice, $ctrl) = @_;
  # TODO adjust for all bridge types
  if  (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 100;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
  if ($ledDevice->{LEDTYPE} eq 'RGBW1')
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 100;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
  if ($ledDevice->{LEDTYPE} eq 'RGBW2')
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 100;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
  if ($ledDevice->{LEDTYPE} eq 'White')
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 10;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
}

###############################################################################
#
# atomic low level udp communication to device
# required because there are timing requirements, mostly limitaions in processing speed of the bridge
# the commands should never be interrupted or canceled because some fhem readings are set in advance
#
###############################################################################

sub
WifiLight_LowLevelCmdQueue_Add(@)
{
  my ($ledDevice, $command, $receiver, $delay, $unlock) = @_;
  my $cmd;

  $cmd->{command} = $command;
  $cmd->{sender} = $ledDevice;
  $cmd->{receiver} = $receiver;
  $cmd->{delay} = $delay;
  $cmd->{unlock} = $unlock;
  $cmd->{inProgess} = 0;

  # push cmd into queue
  push @{$ledDevice->{helper}->{llCmdQueue}}, $cmd;

  my $dbgStr = unpack("H*", $cmd->{command});
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} low level cmd queue add $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}}); 

  my $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];
 
  # sender busy ?
  return undef if ($actualCmd->{inProgess});
  return WifiLight_LowLevelCmdQueue_Send($ledDevice);
}

sub
WifiLight_LowLevelCmdQueue_Send(@)
{
  my ($ledDevice) = @_; 
  my $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];

  # transmission complete, remove
  shift @{$ledDevice->{helper}->{llCmdQueue}} if ($actualCmd->{inProgess});

  # next in queue
  $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];
  
  # remove a low level queue lock if present and get next 
  while (($actualCmd->{unlock} || 0) == 1) 
  { 
    $actualCmd->{sender}->{helper}->{llLock} -= 1;
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} | $actualCmd->{sender}->{NAME} unlock queue ".$actualCmd->{sender}->{helper}->{llLock});
    shift @{$ledDevice->{helper}->{llCmdQueue}}; 
    $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];
  }

  # return if no more elements in queue
  return undef if (!defined($actualCmd->{command}));

  my $dbgStr = unpack("H*", $actualCmd->{command});
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} low level cmd queue qlen ".@{$ledDevice->{helper}->{llCmdQueue}}.", send $dbgStr");

  # TCP LW12
  if ($ledDevice->{CONNECTION} eq 'LW12')
  {
    if (!$ledDevice->{helper}->{SOCKET} || ($ledDevice->{helper}->{SELECT}->can_read(0.0001) && !$ledDevice->{helper}->{SOCKET}->recv(my $data, 512)))
    {
      Log3 ($ledDevice, 3, "$ledDevice->{NAME} low level cmd queue send ERROR $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}}." (trying to reconnect)");

      $ledDevice->{helper}->{SOCKET} = IO::Socket::INET-> new (
        PeerPort => $ledDevice->{PORT},
        PeerAddr => $ledDevice->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($ledDevice, 1, "$ledDevice->{NAME} low level cmd queue send ERROR $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}}." (reconnect giving up)");
      $ledDevice->{helper}->{SELECT} = IO::Select->new($ledDevice->{helper}->{SOCKET}) if $ledDevice->{helper}->{SOCKET};
    }
    $ledDevice->{helper}->{SOCKET}->send($actualCmd->{command}) if $ledDevice->{helper}->{SOCKET}; 
  }
  else
  {
    send($ledDevice->{helper}->{SOCKET}, $actualCmd->{command}, 0, $actualCmd->{receiver}) or Log3 ($ledDevice, 1, "$ledDevice->{NAME} low level cmd queue send ERROR $@ $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}});
  }

  $actualCmd->{inProgess} = 1;
  my $msec = $actualCmd->{delay} / 1000;
  InternalTimer(gettimeofday()+$msec, "WifiLight_LowLevelCmdQueue_Send", $ledDevice, 0);
  return undef;
}

###############################################################################
#
# FHEM web section
# 
#
###############################################################################

sub
WifiLight_FW_summary(@)
{
  my ($FW_wname, $d, $FW_room, $pageData) = @_;
  Log3 (undef, 5, "fw summary $FW_wname, $d, $FW_room"); 

  my $h = ReadingsVal($d, "hue", 0);
  my $s = ReadingsVal($d, "saturation", 0);
  my $v = ReadingsVal($d, "brightness", 0);
  my ($r, $g, $b) = WifiLight_HSV2RGB($h, $s, $v);

  my $result = <<"END";
  \n
  <script language="JavaScript">
    window.addEventListener("load", $d\_widgetInit(), false);
 
    function $d\_widgetInit()
    {
      if (typeof window.rawDataSrc=="undefined") 
      {
        window.rawDataSrcDispatcher = [];
        window.rawDataSrcDispatcherFn = function()
        {
          for (var i=0; i < window.rawDataSrcDispatcher.length; i++)
          {
            window.rawDataSrcDispatcher[i]();
          }
        }
        window.rawDataSrc = new XMLHttpRequest();
        window.rawDataSrc.addEventListener("progress", window.rawDataSrcDispatcherFn, true);
        window.rawDataSrc.open("GET", "$FW_ME?XHR=1&inform=type=raw;filter=room=all&timestamp="+new Date().getTime());
        setTimeout(function() {window.rawDataSrc.send();}, 350);
      }
      //document.getElementById("$d\_state").parsedLines = -1;
      //document.getElementById("$d\_state_icon").setState($h, $s, $v, $r, $g, $b);
      window.addEventListener("mousedown", $d\_widgetCtrl, false);
      window.addEventListener("touchstart", $d\_widgetCtrl, false);
    }
    
    function $d\_widgetCtrl(e)
    {
      e = e ? e : window.event;
      if (String(e.target.id).substring(0, String("$d").length) != "$d") {
        if (document.getElementById("$d\_state").showState != "icon") {
          document.getElementById("$d\_state").showState = "icon";
          document.getElementById("$d\_state").style.display = "inline";
          document.getElementById("$d\_state_pane").style.display = "none";
          document.getElementById("$d\_color_button").style.display = "none";
          if(document.removeEventListener) {
            document.getElementById("$d\_state_slider_handle").removeEventListener("mousedown", document.getElementById("$d\_state_slider_handle").startSlide, false);
            document.getElementById("$d\_state_slider_handle").removeEventListener("touchstart", document.getElementById("$d\_state_slider_handle").startSlide, false);
          }
          else if(document.detachEvent) {
            document.detachEvent("mousedown", document.getElementById("$d\_state_slider_handle").startSlide);
          }
        }
      }
      return e;
    }

    function $d\_widgetSetState()
    {
      if (window.rawDataSrc.readyState == 3 && window.rawDataSrc.status == 200)
      {
        var lines = rawDataSrc.responseText.split("\\n");
        var pattern = /^[0-9-]+\\s[0-9:]+\\s*[0-9]*\\sWifiLight\\s$d\\s(c1:)([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+)<br>\$/;
        var parsedLines = document.getElementById("$d\_state").parsedLines;
        parsedLines = parsedLines ? parsedLines : 0;
        //for (var i = document.getElementById("$d\_state").parsedLines; i < lines.length; i++) {
        for (var i = parsedLines; i < lines.length; i++) {
          var c1match = pattern.exec(lines[i]);
          document.getElementById("$d\_state").parsedLines = i;
          if (c1match) {
            console.warn("$d c1 match: " + c1match[0]);
            
            var leftStop = 0;
            var rightStop = parseInt(document.getElementById("$d\_state_slider").style.width) + leftStop - parseInt(document.getElementById("$d\_state_slider_handle").style.width) -4;
            var newSliderPos = parseInt((rightStop - leftStop) / 100 * c1match[4]);
            document.getElementById("$d\_state_slider_handle").style.left = newSliderPos + "px";
            document.getElementById("$d\_state_icon").setState(c1match[2], c1match[3], c1match[4], c1match[5], c1match[6], c1match[7]);
          }
        }
        //console.warn("$d in set state: " + rawDataSrc.responseText);
      }
    }

    function $d\_doCmd(cmd)
    {
      var sendCmd = new XMLHttpRequest();
      sendCmd.open("GET", "$FW_ME?XHR=1&"+cmd+"&timestamp="+new Date().getTime());
      sendCmd.send();
      //var sliderPos = $d\_getPosition(document.getElementById("$d\_state_slider"));
      //console.warn("in cmd state slider: " + sliderPos);
      //var handlePos = $d\_getPosition(document.getElementById("$d\_state_slider_handle"));
      //console.warn("in cmd state handle: " + handlePos);
    }

    function $d\_getPosition(obj)
    {
      var cleft = ctop = 0;
      while (obj.offsetParent)
      { 
        cleft += obj.offsetLeft;
        ctop += obj.offsetTop; 
        obj = obj.offsetParent;
      }
      cleft += obj.offsetLeft;
      ctop += obj.offsetTop;
      return [cleft, ctop];
    }
  </script>

  <div id="$d\_state" style="display:inline;">
    <canvas id="$d\_state_icon" onclick="$d\_showPane()" width="48" height="48" style="display:inline; float:center;"></canvas>
    <script language="JavaScript">
      var $d\_state_icon = document.getElementById("$d\_state_icon");
      $d\_state_icon.setState = function(h,s,v,r,g,b) {
        this.width = this.width;

        var context = this.getContext("2d");
        var x = this.width /2;
        var y = this.height /2;
        var rad = 18;
        var start = 1.1 * Math.PI;
        var end = 1.9 * Math.PI;
        context.beginPath();
        context.arc(x,y -2,rad, start,end,false);
        context.lineWidth = 3;
        context.lineCap = "round";
        context.strokeStyle = "grey";
        context.stroke();

        rad = 12;
        start = 0 * Math.PI;
        end = 2 * Math.PI;
        context.beginPath();
        context.arc(x,y -4,rad, start,end,false);
        context.lineWidth = 1;
        context.strokeStyle = "grey";
        context.stroke();
        context.fillStyle = "rgba("+ r +"," + g +"," + b + ",0.5)";
        context.fill();

        for (var i = 10; i <= v; i = i +10) {
          y = parseInt(this.height * 0.85);
          context.beginPath();
          context.moveTo((i/10)*4, 46);
          context.lineTo((i/10)*4, 36);
          context.lineWidth = 2;
          context.lineCap = "round";
          context.strokeStyle = "grey";
          context.stroke();
        }
      }
    </script>
  </div>
  <div id="$d\_color_button" style="display:none; position:relative; height:42px; margin:4px; padding:0px;">
END
  for (my $i = 0; $i < 8; $i++)
  {
    my @colors;
    $colors[0] = [0,100,100];
    $colors[1] = [60,100,100];
    $colors[2] = [120,100,100];
    $colors[3] = [180,100,100];
    $colors[4] = [240,100,100];
    $colors[5] = [300,100,100];
    $colors[6] = [0,0,100];
    $colors[7] = [0,0,0];
    ($r, $g, $b) = WifiLight_HSV2RGB($colors[$i][0], $colors[$i][1], $colors[$i][2]);
    my $o = 0.5; #0.3 + ($colors[$i][2] / 200);
    $result .= <<"END";
    <div id="$d\_$i" onclick="$d\_doCmd('cmd.$d=set $d HSV $colors[$i][0],$colors[$i][1],$colors[$i][2]')"
      style="
        position:relative;
        margin:4px;
        float:left;
        width:24px;
        height:24px;
        background-color:rgba($r, $g, $b, $o);
        border-width:1px;
        border-color:grey;
        border-style:solid;
        border-radius:8px;
        -moz-box-shadow: 4px 4px 2px 0px #ccc;
        -webkit-box-shadow: 4px 4px 2px 0px #ccc;
        box-shadow: 4px 4px 2px 0px #ccc;
        z-index:100;">
    </div>   
END
  }
  my $spos = int($v * 2.34);
  ($r, $g, $b) = WifiLight_HSV2RGB($h, $s, $v);
  $result .= <<"END";
  </div>
  <div id="$d\_state_pane" style="display:none; position:relative; height:42px; margin:4px; padding:0px;">
    <div 
      id="$d\_state_slider" style="
        position:relative;
        top:0px;
        width:262px; 
        height:24px;
        margin:4px;
        background-image:-webkit-linear-gradient(to right, lightgrey, white); 
        background-image:-o-linear-gradient(to right, lightgrey, white);
        background-image:-moz-linear-gradient(to right, lightgrey, white);
        background-image:linear-gradient(to right, lightgrey, white);
        border-width:1px; 
        border-color:grey; 
        border-style:solid; 
        border-radius:8px;
        z-index:100;">
    </div>
    <div 
      id="$d\_state_slider_handle" style="
        position:relative;
        top:-35px;
        left:$spos\px;
        width:24px;
        height:30px;
        margin:4px;
        border-width:3px;
        border-color:grey;
        border-style:solid;
        border-radius:8px;
        -moz-box-shadow: 4px 4px 2px 0px #ccc;
        -webkit-box-shadow: 4px 4px 2px 0px #ccc;
        box-shadow: 4px 4px 2px 0px #ccc;
        z-index:100;">
    </div>
    <script language="JavaScript">
      var $d\_sliderPos = $d\_getPosition(document.getElementById("$d\_state_slider"));
      document.getElementById("$d\_state").parentNode.setAttribute("informId", "$d\_dont_touch_please");
      window.rawDataSrcDispatcher.push($d\_widgetSetState);
      document.getElementById("$d\_state_icon").setState($h, $s, $v, $r, $g, $b);
      document.getElementById("$d\_state").showState = "icon";

      var sh = document.getElementById("$d\_state_slider_handle");

      sh.startSlide = function(e) {
        me = document.getElementById("$d\_state_slider_handle");
        e = e ? e : window.event;
        if (e.changedTouches) e = e.changedTouches[0];
        me.startPosX = e.clientX;
        me.startPosY = e.clientY;
        me.sliderPosX = parseInt(me.style.left);
        if(document.addEventListener) {
          document.addEventListener("mousemove", me.goSlide, false);
          document.addEventListener("touchmove", me.goSlide, false);
        }
        else if(document.attachEvent) {
          document.attachEvent("onmousemove", me.goSlide);
        }
        if(document.addEventListener) {
          document.addEventListener("mouseup", me.endSlide, false);
          document.addEventListener("touchend", me.endSlide, false);
        }
        else if(document.attachEvent) {
          document.attachEvent("onmouseup", e.endSlide);
        }
        if(e.stopPropagation) e.stopPropagation();
        if(e.preventDefault) e.preventDefault();
        e.cancelBubble = true;
        e.cancel = true;
        e.returnValue = false;
        return false;
      }
      sh.goSlide = function(e) {
        me = document.getElementById("$d\_state_slider_handle");
        e = e ? e : window.event;
        if(e.stopPropagation) e.stopPropagation();
        if(e.preventDefault) e.preventDefault();
        e.cancelBubble = true;
        e.cancel = true;
        e.returnValue = false;
        if (e.changedTouches) e = e.changedTouches[0];
        var x = e.clientX;
        var y = e.clientX;
        var leftStop = 0;
        var rightStop = parseInt(document.getElementById("$d\_state_slider").style.width) + leftStop - parseInt(me.style.width) -4;
        var newSliderPos = me.sliderPosX + (x - me.startPosX);
        newSliderPos = (newSliderPos < leftStop) ? leftStop : newSliderPos;
        newSliderPos = (newSliderPos > rightStop) ? rightStop : newSliderPos;
        me.style.left = newSliderPos + "px"; 
        return false;
      }
      sh.endSlide = function(e) {
        me = document.getElementById("$d\_state_slider_handle");
        var leftStop = 0;
        var rightStop = parseInt(document.getElementById("$d\_state_slider").style.width) + leftStop - parseInt(me.style.width) -4;
        var newSetting = 100 / (rightStop - leftStop) * parseInt(me.style.left);
        $d\_doCmd("cmd.$d=set $d dim "+parseInt(newSetting));
        if(document.removeEventListener) {
          document.removeEventListener("mousemove", me.goSlide, false);
          document.removeEventListener("touchmove", me.goSlide, false);
        }
        else if(document.detachEvent) {
          document.detachEvent("onmousemove", me.goSlide);
        }
        if(document.removeEventListener) {
          document.removeEventListener("mouseup", me.endSlide, false);
          document.removeEventListener("touchend", me.endSlide, false);
        }
        else if(document.detachEvent) {
          document.detachEvent("onmouseup", me.endSlide);
        }
        if(e.stopPropagation) e.stopPropagation();
        if(e.preventDefault) e.preventDefault();
        e.cancelBubble = true;
        e.cancel = true;
        e.returnValue = false;
        return false;
      }
    </script>
  </div>
  <script language="JavaScript">
    function $d\_showPane() 
    {
      document.getElementById("$d\_state").style.display = "none";
      document.getElementById("$d\_state").showState = "pane";
      document.getElementById("$d\_state_pane").style.display = "block";
      document.getElementById("$d\_color_button").style.display = "block";
      if(document.addEventListener) {
        document.getElementById("$d\_state_slider_handle").addEventListener("mousedown", document.getElementById("$d\_state_slider_handle").startSlide, false);
        document.getElementById("$d\_state_slider_handle").addEventListener("touchstart", document.getElementById("$d\_state_slider_handle").startSlide, false);
      }
      else if(document.attachEvent) {
        document.attachEvent("onmousemove", me.goSlide);
      }
    }
  </script>
END
  return $result;
}



1;
