# $Id$
##############################################
#
#     31_MilightDevice.pm
#     FHEM module for MILIGHT lightbulbs.
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
use Math::Round;

use Color;
use SetExtensions;

my %dim_values = (
   0 => "dim_00",
   1 => "dim_10",
   2 => "dim_20",
   3 => "dim_30",
   4 => "dim_40",
   5 => "dim_50",
   6 => "dim_60",
   7 => "dim_70",
   8 => "dim_80",
   9 => "dim_90",
  10 => "dim_100",
);

sub
MilightDevice_Initialize(@)
{
  my ($hash) = @_;

  $hash->{DefFn} = "MilightDevice_Define";
  $hash->{UndefFn} = "MilightDevice_Undef";
  $hash->{ShutdownFn} = "MilightDevice_Undef";
  $hash->{SetFn} = "MilightDevice_Set";
  $hash->{GetFn} = "MilightDevice_Get";
  $hash->{AttrFn} = "MilightDevice_Attr";
  $hash->{NotifyFn} = "MilightDevice_Notify";
  $hash->{AttrList} = "IODev dimStep defaultRampOn defaultRampOff";

  FHEM_colorpickerInit();
    
  return undef;
}

sub
MilightDevice_devStateIcon($)
{
  my($hash) = @_;
  $hash = $defs{$hash} if( ref($hash) ne 'HASH' );

  return undef if( !$hash );
  return undef if( $hash->{helper}->{group} );

  my $name = $hash->{NAME};

  my $percent = ReadingsVal($name,"brightness","100");
  my $s = $dim_values{round($percent/10)};

  # Return SVG coloured icon with toggle as default action
  return ".*:light_light_$s@#".ReadingsVal($name, "RGB", "FFFFFF").":toggle"
            if (($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW'));
  # Return SVG icon with toggle as default action (for White bulbs)
  return ".*:light_light_$s:toggle";
}

sub
MilightDevice_Define($$)
{
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def); 
  my $name = $args[0];
  my $key;

  return "wrong syntax: define <name> MilightDevice <type> <slot> <IODev>" if(@args < 5);
  return "unknown LED type ($args[2]): choose one of RGB, RGBW, White" if !($args[2] ~~ ['RGB', 'RGBW', 'White']);
  
  $hash->{LEDTYPE} = $args[2];

  return "Invalid slot: Select one of 1..4 for White" if (($args[3] !~ /^\d*$/) || (($args[3] < 1) || ($args[3] > 4)) && ($hash->{LEDTYPE} eq 'White'));
  return "Invalid slot: Select one of 5..8 for RGBW" if (($args[3] !~ /^\d*$/) || (($args[3] < 5) || ($args[3] > 8)) && ($hash->{LEDTYPE} eq 'RGBW'));
  return "Invalid slot: Select 0 for RGB" if (($args[3] !~ /^\d*$/) || ($args[3] != 0) && ($hash->{LEDTYPE} eq 'RGB'));
  $hash->{SLOT} = $args[3];

  my $iodev = $args[4];

  Log3 ($hash, 4, "define $name $args[1] $hash->{LEDTYPE} $hash->{SLOT} $iodev");

  # Verify IODev is valid
  AssignIoPort($hash, $iodev);
  if(defined($hash->{IODev}->{NAME})) {
    Log3 $name, 3, "$name: I/O device is " . $hash->{IODev}->{NAME};
  } else {
    Log3 $name, 1, "$name: no I/O device";
  }

  # Look for already defined device on IODev
  return "Slot $hash->{SLOT} already defined as $hash->{IODev}->{$hash->{SLOT}}->{NAME}" if (defined($hash->{IODev}->{$hash->{SLOT}}->{NAME}));
  # Define device on IODev
  $hash->{IODev}->{$hash->{SLOT}}->{NAME} = $name;

  # Define High Level Command Queue
  my @hlCmdQueue = [];
  $hash->{helper}->{hlCmdQueue} = \@hlCmdQueue;
  
  # Colormap / Commandsets
  if (($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW'))
  {
    $hash->{helper}->{COLORMAP} = MilightDevice_ColorConverter($hash);
  }

  my $baseCmds = "on off toggle dim:slider,0,".round(100/MilightDevice_dimSteps($hash)).",100 dimup dimdown";
  my $sharedCmds = "pair:noArg unpair:noArg restorePreviousState:noArg saveState:noArg restoreState:noArg";
  $hash->{helper}->{COMMANDSET} = "$baseCmds hsv rgb:colorpicker,RGB discoModeUp:noArg discoSpeedUp:noArg discoSpeedDown:noArg $sharedCmds"
        if ($hash->{LEDTYPE} eq 'RGBW');
  $hash->{helper}->{COMMANDSET} = "$baseCmds hsv rgb:colorpicker,RGB discoModeUp discoModeDown discoSpeedUp discoSpeedDown $sharedCmds"
        if ($hash->{LEDTYPE} eq 'RGB');
        
  $hash->{helper}->{COMMANDSET} = "$baseCmds colourTemperature:slider,1,1,10 $sharedCmds"
        if ($hash->{LEDTYPE} eq 'White');
  
  # webCmds
  $attr{$name}{webCmd} = 'rgb:rgb ff2a00:rgb 00ff00:rgb 0000ff:rgb ffff00:on:off:dim' if ($hash->{LEDTYPE} eq 'RGB');
  $attr{$name}{webCmd} = 'rgb:rgb ffffff:rgb ff2a00:rgb 00ff00:rgb 0000ff:rgb ffff00:on:off:dim' if ($hash->{LEDTYPE} eq 'RGBW');
  $attr{$name}{webCmd} = 'on:off:dim:colourTemperature' if ($hash->{LEDTYPE} eq 'White');
  
  # Define devStateIcon
  $attr{$name}{devStateIcon} = '{(MilightDevice_devStateIcon($name),"toggle")}' if( !defined( $attr{$name}{devStateIcon} ) );
  
  return undef;
}

sub
MilightDevice_Undef(@)
{
  my ($hash,$args) = @_;

  RemoveInternalTimer($hash);

  return undef;
}

sub
MilightDevice_Set(@)
{
  my ($hash, $name, $cmd, @args) = @_;
  my $cnt = @args;
  my $ramp = 0;
  my $flags = "";
  my $event = undef;
  my $usage = "set $name ...";

  # Commands that map to other commands
  if( $cmd eq "toggle" )
  {
    $cmd = ReadingsVal($name,"state","on") eq "off" ? "on" :"off";
  }

  # Commands
  if ($cmd eq 'pair')
  {
    if (defined($args[0]))
    {
      return "Usage: set $name pair <seconds(0..X)>" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    MilightDevice_HighLevelCmdQueue_Clear($hash);
    return MilightDevice_RGB_Pair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_Pair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_Pair($hash, $ramp) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'unpair')
  {
    if (defined($args[0]))
    {
      return "Usage: set $name unpair <seconds(0..X)>" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    MilightDevice_HighLevelCmdQueue_Clear($hash);
    return MilightDevice_RGB_UnPair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_UnPair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_UnPair($hash, $ramp) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'on')
  {
    if (defined($args[0]))
    {
      return "Usage: set $name on <seconds(0..X)>" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    elsif (defined($attr{$name}{defaultRampOn}))
    {
      $ramp = $attr{$name}{defaultRampOn};
    }
    return MilightDevice_RGB_On($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_On($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_On($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'off')
  {
    if (defined($args[0]))
    {
      return "Usage: set $name off <seconds(0..X)>" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    elsif (defined($attr{$name}{defaultRampOff}))
    {
      $ramp = $attr{$name}{defaultRampOff};
    }
    return MilightDevice_RGB_Off($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_Off($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_Off($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'dimup')
  {
    return "Usage: set $name dimup" if (defined($args[1]));
    my $v = ReadingsVal($hash->{NAME}, "brightness", 0) + round(100 / MilightDevice_dimSteps($hash));
    $v = 100 if $v > 100;
    return MilightDevice_RGB_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'dimdown')
  {
    return "Usage: set $name dimdown" if (defined($args[1]));
    my $v = ReadingsVal($hash->{NAME}, "brightness", 0) - (100 / MilightDevice_dimSteps($hash));
    $v = 0 if $v < 0;
    return MilightDevice_RGB_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'dim')
  {
    $usage = "Usage: set $name dim <percent(0..100)> [seconds(0..x)] [flags(l=long path|q=don't clear queue)]";
    return $usage if (($args[0] !~ /^\d+$/) || (!($args[0] ~~ [0..100]))); # Decimal value for percent between 0..100
    if (defined($args[1]))
    {
      return $usage if (($args[1] !~ /^\d+$/) && ($args[1] > 0)); # Decimal value for ramp > 0
      $ramp = $args[1];
    }
    if (defined($args[2]))
    {   
      return $usage if ($args[2] !~ m/.*[lLqQ].*/); # Flags l=Long way round for transition, q=don't clear queue (add to end)
      $flags = $args[2];
    }
    return MilightDevice_RGB_Dim($hash, $args[0], $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_Dim($hash, $args[0], $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_Dim($hash, $args[0], $ramp, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif( $cmd eq "rgb")
  {
    $usage = "Usage: set $name rgb RRGGBB [seconds(0..x)] [flags(l=long path|q=don't clear queue)]";
    return $usage if ($args[0] !~ /^([0-9A-Fa-f]{1,2})([0-9A-Fa-f]{1,2})([0-9A-Fa-f]{1,2})$/);
    my( $r, $g, $b ) = (hex($1)/255.0, hex($2)/255.0, hex($3)/255.0);
    my( $h, $s, $v ) = Color::rgb2hsv($r,$g,$b);
    $h *= 360; $s *= 100; $v *= 100;
    if (defined($args[1]))
    {
      return $usage if (($args[1] !~ /^\d+$/) && ($args[1] > 0)); # Decimal value for ramp > 0
      $ramp = $args[1];
    }
    if (defined($args[2]))
    {   
      return $usage if ($args[2] !~ m/.*[lLqQ].*/); # Flags l=Long way round for transition, q=don't clear queue (add to end)
      $flags = $args[2];
    }
    return MilightDevice_HSV_Transition($hash, $h, $s, $v, $ramp, $flags);
  }

  elsif ($cmd eq 'hsv')
  {
    $usage = "Usage: set $name hsv <h(0..360)>,<s(0..100)>,<v(0..100)> [seconds(0..x)] [flags(l=long path|q=don't clear queue)]";
    return $usage if ($args[0] !~ /^(\d{1,3}),(\d{1,3}),(\d{1,3})$/);
    my ($h, $s, $v) = ($1, $2, $3);
    return "Invalid hue ($h): valid range 0..360" if !(($h >= 0) && ($h <= 360));
    return "Invalid saturation ($s): valid range 0..100" if !(($s >= 0) && ($s <= 100));
    return "Invalid brightness ($v): valid range 0..100" if !(($v >= 0) && ($v <= 100));
    if (defined($args[1]))
    {
      return $usage if (($args[1] !~ /^\d+$/) && ($args[1] > 0)); # Decimal value for ramp > 0
      $ramp = $args[1];
    }
    if (defined($args[2]))
    {   
      return $usage if ($args[2] !~ m/.*[lLqQ].*/); # Flags l=Long way round for transition, q=don't clear queue (add to end)
      $flags = $args[2];
    }
    return MilightDevice_HSV_Transition($hash, $h, $s, $v, $ramp, $flags);
  }
  
  elsif ($cmd eq 'discoModeUp')
  {
    return MilightDevice_RGBW_DiscoModeStep($hash, 1);
  }

  elsif ($cmd eq 'discoModeDown')
  {
    return MilightDevice_RGBW_DiscoModeStep($hash, 0);
  }
    
  elsif ($cmd eq 'discoSpeedUp')
  {
    return MilightDevice_RGBW_DiscoModeSpeed($hash, 1);
  }

  elsif ($cmd eq 'discoSpeedDown')
  {
    return MilightDevice_RGBW_DiscoModeSpeed($hash, 0);
  }
    
  elsif ($cmd eq 'colourTemperature')
  {
    if (defined($args[0]))
    {
      return "Usage: set $name colourTemperature <1=Cool..10=Warm>" if (($args[0] !~ /^\d+$/) || (!($args[0] ~~ [1..10])));
    }
    return MilightDevice_White_setColourTemp($hash, $args[0]);
  }
  
  elsif ($cmd eq 'restorePreviousState')
  {
    # Restore the previous state (as store in previous* readings)
    my ($h, $s, $v) = MilightDevice_HSVFromStr($hash, ReadingsVal($hash->{NAME}, "previousState", MilightDevice_HSVToStr($hash, 0, 0, 0)));
    MilightDevice_HSV_Transition($hash, $h, $s, $v, 0, '');
    return undef;
  }
  
  elsif ($cmd eq 'saveState')
  {
    # Save the hsv state as a string
    readingsSingleUpdate($hash, "savedState", MilightDevice_HSVToStr($hash, ReadingsVal($hash->{NAME}, "hue", 0), ReadingsVal($hash->{NAME}, "saturation", 0), ReadingsVal($hash->{NAME}, "brightness", 0)), 0);
    return undef;
  }
  elsif ($cmd eq 'restoreState')
  {
    my ($h, $s, $v) = MilightDevice_HSVFromStr($hash, ReadingsVal($hash->{NAME}, "savedState", MilightDevice_HSVToStr($hash, 0, 0, 0)));
    return MilightDevice_HSV_Transition($hash, $h, $s, $v, 0, '');
  }

  return SetExtensions($hash, $hash->{helper}->{COMMANDSET}, $name, $cmd, @args);
}

sub
MilightDevice_Get(@)
{
  my ($hash, @args) = @_;

  my $name = $args[0];
  return "$name: get needs at least one parameter" if(@args < 2);

  my $cmd= $args[1];

  if($cmd eq "rgb" || $cmd eq "RGB") {
    return ReadingsVal($name, "RGB", "FFFFFF");
  }
  elsif($cmd eq "hsv") {
    return MilightDevice_HSVToStr($hash, ReadingsVal($hash->{NAME}, "hue", 0), ReadingsVal($hash->{NAME}, "saturation", 0), ReadingsVal($hash->{NAME}, "brightness", 0));
  }
  
  return "Unknown argument $cmd, choose one of rgb:noArg RGB:noArg hsv:noArg";
}

sub
MilightDevice_Attr(@)
{
  my ($cmd, $device, $attribName, $attribVal) = @_;
  my $hash = $defs{$device};

  if ($cmd eq 'set' && $attribName eq 'dimStep')
  {
    return "dimStep is required as numerical value [1..100]" if ($attribVal !~ /^\d*$/) || (($attribVal < 1) || ($attribVal > 100));
  }
  if ($cmd eq 'set' && (($attribName eq 'defaultRampOn') || ($attribName eq 'defaultRampOff')))
  {
    return "defaultRampOn/Off is required as numerical value [0..100]" if ($attribVal !~ /^\d*$/) || (($attribVal < 0) || ($attribVal > 100));
  }
  Log3 ($hash, 4, "$hash->{NAME} attrib $attribName $cmd $attribVal"); 
  return undef;
}

# restore previous settings (as set statefile)
sub
MilightDevice_Notify(@)
{
  my ($hash, $eventSrc) = @_;
  my $events = deviceEvents($eventSrc, 1);
  my ($hue, $sat, $val);

  # wait for global: INITIALIZED after start up
  if ($eventSrc->{NAME} eq 'global' && @{$events}[0] eq 'INITIALIZED')
  {
    # Default to OFF if not defined
    $hue = ReadingsVal($hash->{NAME}, "hue", 0);
    $sat = ReadingsVal($hash->{NAME}, "saturation", 0);
    $val = ReadingsVal($hash->{NAME}, "brightness", 0);

    
    # Restore state
    return MilightDevice_RGB_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGB');
    return MilightDevice_RGBW_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGBW');
    return MilightDevice_White_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'White');
  }
  
  return undef;
}

###############################################################################
#
# device specific controller functions RGB
# LED Strip or bulb, no white, controller V2
#
###############################################################################

sub
MilightDevice_RGB_Pair(@)
{
  my ($hash, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  Log3 ($hash, 4, "$hash->{NAME} RGB LED slot $hash->{SLOT} pair $numSeconds s"); 
  # DISCO SPEED FASTER 0x25 (SYNC/PAIR RGB Bulb within 2 seconds of Wall Switch Power being turned ON)
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 1000, undef);
  }
  return undef;
}

sub
MilightDevice_RGB_UnPair(@)
{
  my ($hash) = @_;
  my $numSeconds = 8;
  Log3 ($hash, 4, "$hash->{NAME} RGB LED slot $hash->{SLOT} unpair $numSeconds s"); 
  # DISCO SPEED FASTER 0x25 (SYNC/PAIR RGB Bulb within 2 seconds of Wall Switch Power being turned ON)
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 200, undef);
  }
  return undef;
}

sub
MilightDevice_RGB_On(@)
{
  my ($hash, $ramp, $flags) = @_;
  my $v = 100;
  Log3 ($hash, 4, "$hash->{NAME} RGB slot $hash->{SLOT} set on $ramp");
  # Switch on with same brightness it was switched off with, or max if undefined.
  if (ReadingsVal($hash->{NAME}, "state", "off") eq "off")
  {
    $v = ReadingsVal($hash->{NAME}, "brightness_on", 100);
  }
  else
  {
    $v = ReadingsVal($hash->{NAME}, "brightness", 100);
  }

  # When turning on, make sure we request at least minimum dim step.
  if ($v < round(100/MilightDevice_dimSteps($hash)))
  {
    $v = 100;
  }

  return MilightDevice_RGB_Dim($hash, $v, $ramp, $flags); 
}

sub
MilightDevice_RGB_Off(@)
{
  my ($hash, $ramp, $flags) = @_;
  Log3 ($hash, 4, "$hash->{NAME} RGB slot $hash->{SLOT} set off $ramp");
  # Store value of brightness before turning off
  # "on" will be of the form "on 50" where 50 is current dimlevel
  if (ReadingsVal($hash->{NAME}, "state", "off") ne "off")
  {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "brightness_on", ReadingsVal($hash->{NAME}, "brightness", 100));
    readingsEndUpdate($hash, 0);
  }
  return MilightDevice_RGB_Dim($hash, 0, $ramp, $flags);
}

sub
MilightDevice_RGB_Dim(@)
{
  my ($hash, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($hash->{NAME}, "hue", 0);
  my $s = ReadingsVal($hash->{NAME}, "saturation", 0);
  Log3 ($hash, 4, "$hash->{NAME} RGB slot $hash->{SLOT} dim $level $ramp $flags"); 
  return MilightDevice_HSV_Transition($hash, $h, $s, $level, $ramp, $flags);
}

sub
MilightDevice_RGB_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  Log3 ($hash, 4, "$hash->{NAME} RGB slot $hash->{SLOT} set h:$hue, s:$sat, v:$val"); 
  $sat = 100;
  MilightDevice_setHSV_Readings($hash, $hue, $sat, $val);
  # convert to device specs
  my ($cv, $cl, $wl) = MilightDevice_RGB_ColorConverter($hash, $hue, $sat, $val);
  Log3 ($hash, 4, "$hash->{NAME} RGB slot $hash->{SLOT} set levels: $cv, $cl, $wl");
  return MilightDevice_RGB_setLevels($hash, $cv, $cl, $wl);
}

sub
MilightDevice_RGB_setLevels(@)
{
  my ($hash, $cv, $cl, $wl) = @_;

  # mode 0: off, 1: mixed "white", 2: color

  # need to touch color value (only if visible) or color level ?
  if ((($hash->{helper}->{colorValue} != $cv) && ($cl > 0)) || $hash->{helper}->{colorLevel} != $cl)
  {
    # if color all off switch on
    if ($hash->{helper}->{mode} == 0)
    {
      IOWrite($hash, "\x22\x00\x55"); # switch on
      IOWrite($hash, "\x20".chr($cv)."\x55"); # set color
      $hash->{helper}->{colorValue} = $cv;
      $hash->{helper}->{colorLevel} = 1;
      $hash->{helper}->{mode} = 2;
    }
    elsif ($hash->{helper}->{mode} == 1)
    {
      IOWrite($hash, "\x20".chr($cv)."\x55"); # set color
      $hash->{helper}->{colorValue} = $cv;
      $hash->{helper}->{mode} = 2;
    }
    else
    {
      $hash->{helper}->{colorValue} = $cv;
      IOWrite($hash, "\x20".chr($cv)."\x55"); # set color
    }
    # cl decrease
    if ($hash->{helper}->{colorLevel} > $cl)
    {
      for (my $i=$hash->{helper}->{colorLevel}; $i > $cl; $i--) 
      {
        IOWrite($hash, "\x24\x00\x55"); # brightness down
        $hash->{helper}->{colorLevel} = $i - 1;
      }
      if ($cl == 0)
      {
        # need to switch off color
        # if no white is required and no white is active we can must entirely switch off
        IOWrite($hash, "\x21\x00\x55"); # switch off
        $hash->{helper}->{colorLevel} = 0;
        $hash->{helper}->{mode} = 0;
      }
    }
    # cl inrease
    if ($hash->{helper}->{colorLevel} < $cl)
    {
      for (my $i=$hash->{helper}->{colorLevel}; $i < $cl; $i++)
      {
        IOWrite($hash, "\x23\x00\x55"); # brightness up
        $hash->{helper}->{colorLevel} = $i + 1;
      }
    }
  }

  return undef;
}

sub
MilightDevice_RGB_ColorConverter(@)
{
  my ($hash, $h, $s, $v) = @_;
  my $color = $hash->{helper}->{COLORMAP}[$h % 360];
  
  # there are 0..9 dim level, setup correction
  my $valueSpread = 100/MilightDevice_dimSteps($hash);
  my $totalVal = round($v / $valueSpread);
  # saturation 100..50: color full, white increase. 50..0 white full, color decrease
  my $colorVal = ($s >= 50) ? $totalVal : int(($s / 50 * $totalVal) +0.5);
  my $whiteVal = ($s >= 50) ? int(((100-$s) / 50 * $totalVal) +0.5) : $totalVal;
  return ($color, $colorVal, $whiteVal);
}

###############################################################################
#
# device specific functions RGBW bulb 
# RGB+White, only bridge V3
#
###############################################################################

sub
MilightDevice_RGBW_Pair(@)
{
  my ($hash, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($hash, 4, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 1000, undef);
  }
  return undef;
}

sub
MilightDevice_RGBW_UnPair(@)
{
  my ($hash, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($hash, 4, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $onCtrl = @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55";
  # my $fullOnCtrl = "\x4E\x1B\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
  }
  return undef;
}

sub
MilightDevice_RGBW_On(@)
{
  my ($hash, $ramp, $flags) = @_;
  my $v = 100;
  Log3 ($hash, 4, "$hash->{NAME} RGBW slot $hash->{SLOT} set on $ramp");
  # Switch on with same brightness it was switched off with, or max if undefined.
  if (ReadingsVal($hash->{NAME}, "state", "off") eq "off")
  {
    $v = ReadingsVal($hash->{NAME}, "brightness_on", 100);
  }
  else
  {
    $v = ReadingsVal($hash->{NAME}, "brightness", 100);
  }
  # When turning on, make sure we request at least minimum dim step.
  if ($v < round(100/MilightDevice_dimSteps($hash)))
  {
    $v = 100;
  }

  return MilightDevice_RGBW_Dim($hash, $v, $ramp, $flags); 
}

sub
MilightDevice_RGBW_Off(@)
{
  my ($hash, $ramp, $flags) = @_;
  Log3 ($hash, 4, "$hash->{NAME} RGBW slot $hash->{SLOT} set off $ramp");
  # Store value of brightness before turning off
  # "on" will be of the form "on 50" where 50 is current dimlevel
  if (ReadingsVal($hash->{NAME}, "state", "off") ne "off")
  {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "brightness_on", ReadingsVal($hash->{NAME}, "brightness", 100));
    readingsEndUpdate($hash, 0);
  }
  return MilightDevice_RGBW_Dim($hash, 0, $ramp, $flags);
}

sub
MilightDevice_RGBW_Dim(@)
{
  my ($hash, $v, $ramp, $flags) = @_;
  my $h = ReadingsVal($hash->{NAME}, "hue", 0);
  my $s = ReadingsVal($hash->{NAME}, "saturation", 0);
  Log3 ($hash, 4, "$hash->{NAME} RGBW slot $hash->{SLOT} dim $v $ramp ". $flags || ''); 
  return MilightDevice_HSV_Transition($hash, $h, $s, $v, $ramp, $flags);
}

sub
MilightDevice_RGBW_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  my ($cl, $wl);

  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  my @bulbCmdsOff = ("\x46", "\x48", "\x4A", "\x4C");
  my @bulbCmdsWT = ("\xC5", "\xC7", "\xC9", "\xCB");

  my $cv = $hash->{helper}->{COLORMAP}[$hue % 360];

  # mode 0 = off, 1 = color, 2 = white, 3 = disco
  # brightness 2..27 (x02..x1b) | 25 dim levels
  
  my $cf = round((($val / 100) * MilightDevice_dimSteps($hash)) + 2);
  if ($sat < 20) 
  {
    $wl = $cf;
    $cl = 0;
    $sat = 0;
  }
  else
  {
    $cl = $cf;
    $wl = 0;
    $sat = 100;
  }
  
  Log3 ($hash, 5, "MilightDevice_RGBW_setHSV wl $wl cl $cl cv $cv");
  # Set readings in FHEM
  MilightDevice_setHSV_Readings($hash, $hue, $sat, $val);

  # NOTE: All commands sent twice for reliability (it's udp with no feedback)

  # Off is shifted to "2" above so check for < 3
  if (($wl < 3) && ($cl < 3)) # off
  {
    IOWrite($hash, @bulbCmdsOff[$hash->{SLOT} -5]."\x00\x55"); # group off
    IOWrite($hash, @bulbCmdsOff[$hash->{SLOT} -5]."\x00\x55"); # group off
    $hash->{helper}->{whiteLevel} = 0;
    $hash->{helper}->{colorLevel} = 0;
    $hash->{helper}->{mode} = 0; # group off
  }
  else # on
  {
    if ($wl > 0) # white
    {
      IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55") if (($wl > 0) || ($cl > 0)); # group on
      IOWrite($hash, @bulbCmdsWT[$hash->{SLOT} -5]."\x00\x55"); # white
      IOWrite($hash, "\x4E".chr($wl)."\x55"); # brightness
      IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55") if (($wl > 0) || ($cl > 0)); # group on
      IOWrite($hash, @bulbCmdsWT[$hash->{SLOT} -5]."\x00\x55"); # white
      IOWrite($hash, "\x4E".chr($wl)."\x55"); # brightness
      $hash->{helper}->{mode} = 2; # white
    }
    elsif ($cl > 0) # color
    {
      IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55") if (($wl > 0) || ($cl > 0)); # group on
      IOWrite($hash, "\x40".chr($cv)."\x55"); # color
      IOWrite($hash, "\x4E".chr($cl)."\x55"); # brightness
      IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55") if (($wl > 0) || ($cl > 0)); # group on
      IOWrite($hash, "\x40".chr($cv)."\x55"); # color
      IOWrite($hash, "\x4E".chr($cl)."\x55"); # brightness
      $hash->{helper}->{mode} = 1; # color
    }

    $hash->{helper}->{colorValue} = $cv;
    $hash->{helper}->{colorLevel} = $cl;
    $hash->{helper}->{whiteLevel} = $wl;
  }
  
  return undef;
}

sub
MilightDevice_RGBW_DiscoModeStep(@)
{
  my ($hash, $step) = @_;
  
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  
  MilightDevice_HighLevelCmdQueue_Clear($hash);
  
  $step = 0 if ($step < 0);
  $step = 1 if ($step > 1);
  
  # Set readings in FHEM
  MilightDevice_setDisco_Readings($hash, $step, ReadingsVal($hash->{NAME}, 'discoSpeed', 5));

  # NOTE: Only sending commands once, because it makes changes on each successive command
  IOWrite($hash, "\x22\x00\x55") if (($hash->{LEDTYPE} eq 'RGB')); # switch on
  IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55") if (($hash->{LEDTYPE} eq 'RGBW')); # group on

  if ($step == 1)
  {
      IOWrite($hash, "\x27\x00\x55") if (($hash->{LEDTYPE} eq 'RGB')); # discoMode step up
      IOWrite($hash, "\x4D\x00\x55") if (($hash->{LEDTYPE} eq 'RGBW')); # discoMode step up
  }
  elsif ($step == 0)
  {
    IOWrite($hash, "\x28\x00\x55"); # discoMode step down
  }
  
  $hash->{helper}->{mode} = 3; # disco
  
  return undef;
}
sub
MilightDevice_RGBW_DiscoModeSpeed(@)
{
  my ($hash, $speed) = @_;

  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");

  MilightDevice_HighLevelCmdQueue_Clear($hash);
  
  $speed = 0 if ($speed < 0);
  $speed = 1 if ($speed > 1);
  
  # Set readings in FHEM
  MilightDevice_setDisco_Readings($hash, ReadingsVal($hash->{NAME}, 'discoMode', 1), $speed);

  # NOTE: Only sending commands once, because it makes changes on each successive command
  IOWrite($hash, "\x22\x00\x55") if (($hash->{LEDTYPE} eq 'RGB')); # switch on
  IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55") if (($hash->{LEDTYPE} eq 'RGBW')); # group on

  if ($speed == 1)
  {
    IOWrite($hash, "\x25\x00\x55") if ($hash->{LEDTYPE} eq 'RGB'); # discoMode speed up
    IOWrite($hash, "\x44\x00\x55") if ($hash->{LEDTYPE} eq 'RGBW'); # discoMode speed up
  }
  elsif ($speed == 0)
  {
    IOWrite($hash, "\x26\x00\x55") if ($hash->{LEDTYPE} eq 'RGB'); # discoMode speed down
    IOWrite($hash, "\x43\x00\x55") if ($hash->{LEDTYPE} eq 'RGBW'); # discoMode speed down
  }

  $hash->{helper}->{mode} = 3; # disco
  
  return undef;
}

###############################################################################
#
# device specific functions white bulb 
# warm white / cold white with dim, bridge V2|bridge V3
#
###############################################################################

sub
MilightDevice_White_Pair(@)
{
  my ($hash, $numSeconds) = @_;
  $numSeconds = 1 if !(defined($numSeconds));
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  Log3 ($hash, 4, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: pair $numSeconds");
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 1000, undef);
  }
  return undef;
}

sub
MilightDevice_White_UnPair(@)
{
  my ($hash, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsOnFull = ("\xB8", "\xBD", "\xB7", "\xB2");
  Log3 ($hash, 4, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $onCtrl = @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55";
  #my $fullOnCtrl = @bulbCmdsOnFull[$hash->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
    MilightDevice_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 200, undef);
  }
  return undef;
}

sub
MilightDevice_White_On(@)
{
  my ($hash, $ramp, $flags) = @_;
  my $v = 100;
  Log3 ($hash, 4, "$hash->{NAME} white slot $hash->{SLOT} set on $ramp"); 
  # Switch on with same brightness it was switched off with, or max if undefined.
  if (ReadingsVal($hash->{NAME}, "state", "off") eq "off")
  {
    $v = ReadingsVal($hash->{NAME}, "brightness_on", 100);
  }
  else
  {
    $v = ReadingsVal($hash->{NAME}, "brightness", 100);
  }
  # When turning on, make sure we request at least minimum dim step.
  if ($v < round(100/MilightDevice_dimSteps($hash)))
  {
    $v = 100;
  }
  return MilightDevice_White_Dim($hash, $v, $ramp, $flags); 
}

sub
MilightDevice_White_Off(@)
{
  my ($hash, $ramp, $flags) = @_;
  Log3 ($hash, 4, "$hash->{NAME} white slot $hash->{SLOT} set off $ramp"); 
  # Store value of brightness before turning off
  # "on" will be of the form "on 50" where 50 is current dimlevel
  if (ReadingsVal($hash->{NAME}, "state", "off") ne "off")
  {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "brightness_on", ReadingsVal($hash->{NAME}, "brightness", 100));
    readingsEndUpdate($hash, 0);
  }
  return MilightDevice_White_Dim($hash, 0, $ramp, $flags);
}

sub
MilightDevice_White_Dim(@)
{
  my ($hash, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($hash->{NAME}, "hue", 0);
  my $s = ReadingsVal($hash->{NAME}, "saturation", 0);
  Log3 ($hash, 4, "$hash->{NAME} white slot $hash->{SLOT} dim $level $ramp $flags"); 
  return MilightDevice_HSV_Transition($hash, $h, $s, $level, $ramp, $flags);
}

# $hue is colourTemperature, $val is brightness
sub
MilightDevice_White_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  
  # Validate brightness
  $val = 100 if ($val > 100);
  $val = 0 if ($val < 0);

  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsOff = ("\x3B", "\x33", "\x3A", "\x36");
  my @bulbCmdsOnFull = ("\xB8", "\xBD", "\xB7", "\xB2");
  
  # Calculate brightness hardware value (10 steps for white)
  my $maxWl = (100 / MilightDevice_dimSteps($hash));
  my $wl = round($val / $maxWl);
  
  # On first load, whiteLevel won't be defined, define it.
  $hash->{helper}->{whiteLevel} = $wl if (!defined($hash->{helper}->{whiteLevel}));

  if (ReadingsVal($hash, "brightness", 0) > 0)
  {
    # We are transitioning from on to off so store new value of wl and stop brightness up/down being triggered below
    $hash->{helper}->{whiteLevel} = $wl;
  }

  # Store new values for colourTemperature and Brightness
  MilightDevice_setHSV_Readings($hash, ReadingsVal($hash->{NAME}, "colourTemperature", 1), 0, $val);

  # Make sure we actually send off command if we should be off
  if ($wl == 0)
  {
    IOWrite($hash, @bulbCmdsOff[$hash->{SLOT} -1]."\x00\x55"); # group off
    IOWrite($hash, @bulbCmdsOff[$hash->{SLOT} -1]."\x00\x55"); # group off
    Log3 ($hash, 4, "$hash->{NAME} white off");
  }

  elsif ($wl == $maxWl)
  {
    IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55"); # group on
    IOWrite($hash, @bulbCmdsOnFull[$hash->{SLOT} -1]."\x00\x55"); # group on full
    IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55"); # group on
    IOWrite($hash, @bulbCmdsOnFull[$hash->{SLOT} -1]."\x00\x55"); # group on full
    Log3 ($hash, 4, "$hash->{NAME} white full brightness");
  }

  else
  {
    # Not off or MAX brightness, so make sure we are on
    IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55"); # group on
    IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55"); # group on

    if ($hash->{helper}->{whiteLevel} > $wl)
    {
      # Brightness level should be decreased
      Log3 ($hash, 4, "$hash->{NAME} white brightness decrease from $hash->{helper}->{whiteLevel} to $wl");
      for (my $i=$hash->{helper}->{whiteLevel}; $i > $wl; $i--) 
      {
        IOWrite($hash, "\x34\x00\x55"); # brightness down
        $hash->{helper}->{whiteLevel} = $i - 1;
      }
    }

    elsif ($hash->{helper}->{whiteLevel} < $wl)
    {
      # Brightness level should be increased
      $hash->{helper}->{whiteLevel} = 1 if ($hash->{helper}->{whiteLevel} == 0);
      Log3 ($hash, 4, "$hash->{NAME} white brightness increase from $hash->{helper}->{whiteLevel} to $wl");
      for (my $i=$hash->{helper}->{whiteLevel}; $i < $wl; $i++) 
      {
        IOWrite($hash, "\x3C\x00\x55"); # brightness up
        $hash->{helper}->{whiteLevel} = $i + 1;
      }
    }
    
    else
    {
      Log3 ($hash, 4, "$hash->{NAME} white on");
    }
  }

  $hash->{helper}->{whiteLevel} = $wl;
    
  return undef;
}

sub
MilightDevice_White_setColourTemp(@)
{
  # $hue is colourTemperature (1-10), $val is brightness (0-100%)
  my ($hash, $hue) = @_;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  
  MilightDevice_HighLevelCmdQueue_Clear($hash);
 
  # Validate colourTemperature (10 steps)
  $hue = 10 if ($hue > 10);
  $hue = 1 if ($hue < 1);
  
  my $oldHue = ReadingsVal($hash->{NAME}, "colourTemperature", 1);
  
  # Store new values for colourTemperature and Brightness
  MilightDevice_setHSV_Readings($hash, $hue, 0, ReadingsVal($hash->{NAME}, "brightness", 100));
  
  # Set colour temperature
  if ($oldHue != $hue)
  {
    IOWrite($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55"); # group on
    if ($oldHue > $hue)
    {
      Log3 ($hash, 4, "$hash->{NAME} white colourTemp decrease from $oldHue to $hue");
      for (my $i=$oldHue; $i > $hue; $i--)
      {
        IOWrite($hash, "\x3F\x00\x55"); # Cooler (colourtemp down)
      }
    }
    elsif ($oldHue < $hue)
    {
      Log3 ($hash, 4, "$hash->{NAME} white colourTemp increase from $oldHue to $hue");
      for (my $i=$oldHue; $i < $hue; $i++)
      {
        IOWrite($hash, "\x3E\x00\x55"); # Warmer (colourtemp up)
      }
    }
  }  
  return undef;
}

###############################################################################
#
# device independent routines
#
###############################################################################

sub
MilightDevice_HSVFromStr(@)
{
  # Convert HSV values from string in format "h,s,v"
  my ($hash, @args) = @_;
  
  if ((!defined($args[0])) || ($args[0] !~ /^(\d{1,3}),(\d{1,3}),(\d{1,3})$/))
  {
    Log3 ($hash, 3, "MilightDevice_HSVFromStr: Could not parse h,s,v values from $args[0]");
    return (0, 0, 0);
  }
  Log3 ($hash, 5, "MilightDevice_HSVFromStr: Parsed hsv string: h:$1,s:$2,v:$3");
  return ($1, $2, $3);
}

sub
MilightDevice_HSVToStr(@)
{
  # Convert HSV values to string in format "h,s,v"
  my ($hash, $h, $s, $v) = @_;
  
  $h=0 if (!defined($h));
  $s=0 if (!defined($h));
  $v=0 if (!defined($h));
  
  Log3 ($hash, 5, "MilightDevice_HSVToStr: h:$h,s:$s,v:$v");
  return "$h,$s,$v";
}

sub
MilightDevice_validateHSV(@)
{
  # Validate and return valid values for HSV
  my ($hash, $h, $s, $v) = @_;
  $h = 0 if ($h < 0);
  $h = 360 if ($h > 360);
  $s = 0 if ($s < 0);
  $s = 100 if ($s > 100);
  $v = 0 if ($v < 0);
  $v = 100 if ($v > 100);
  
  return ($h, $s, $v);
}

# Return number of steps for each type of bulb
#  White: 10 steps (step = 10)
#  RGB: 9 steps (step = 11)
#  RGBW: 25 steps (step = 4)
sub
MilightDevice_dimSteps(@)
{
  my ($hash) = @_;
  return AttrVal($hash->{NAME}, "dimStep", 10) if ($hash->{LEDTYPE} eq 'White');
  return AttrVal($hash->{NAME}, "dimStep", 9) if ($hash->{LEDTYPE} eq 'RGB');
  return AttrVal($hash->{NAME}, "dimStep", 25) if ($hash->{LEDTYPE} eq 'RGBW');
}

# dispatcher
sub
MilightDevice_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  MilightDevice_RGB_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGB');
  MilightDevice_RGBW_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGBW');
  MilightDevice_White_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'White');
  return undef;
}

sub
MilightDevice_HSV_Transition(@)
{
  my ($hash, $hue, $sat, $val, $ramp, $flags) = @_;
  my ($hueFrom, $satFrom, $valFrom, $timeFrom);
  
  # Store target vales
  $hash->{helper}->{targetHue} = $hue;
  $hash->{helper}->{targetSat} = $sat;
  $hash->{helper}->{targetVal} = $val;
  
  # Clear command queue if flag "q" not specified
  MilightDevice_HighLevelCmdQueue_Clear($hash) if ($flags !~ m/.*[qQ].*/);
  
  # minimum stepWidth
  #FIXME  my $minDelay = MilightDevice_getBridgeDelay($hash); # Min bridge delay as specified by Milight / LimitlessLED API
  my $minDelay = 100; # FIXME: Need to replace getBridgeDelay with call to IODev

  # if queue in progress set start vals to last cached hsv target, else set start to actual hsv
  if (@{$hash->{helper}->{hlCmdQueue}} > 0)
  {
    $hueFrom = $hash->{helper}->{targetHue};
    $satFrom = $hash->{helper}->{targetSat};
    $valFrom = $hash->{helper}->{targetVal};
    $timeFrom = $hash->{helper}->{targetTime};
    Log3 ($hash, 5, "$hash->{NAME} prepare start hsv transition (is cached) hsv $hueFrom, $satFrom, $valFrom, $timeFrom");
  }
  else
  {
    $hueFrom = ReadingsVal($hash->{NAME}, "hue", 0);
    $satFrom = ReadingsVal($hash->{NAME}, "saturation", 0);
    $valFrom = ReadingsVal($hash->{NAME}, "brightness", 0);
    $timeFrom = gettimeofday();
    Log3 ($hash, 5, "$hash->{NAME} prepare start hsv transition (is actual) hsv $hueFrom, $satFrom, $valFrom, $timeFrom");
  }

  Log3 ($hash, 4, "$hash->{NAME} current HSV $hueFrom, $satFrom, $valFrom");
  Log3 ($hash, 4, "$hash->{NAME} set HSV $hue, $sat, $val with ramp: $ramp, flags: ". $flags);

  # if there is no ramp we dont need transition
  if (($ramp || 0) == 0)
  {
    Log3 ($hash, 4, "$hash->{NAME} hsv transition without ramp, hsv $hue, $sat, $val");
    $hash->{helper}->{targetTime} = $timeFrom;
    return MilightDevice_HighLevelCmdQueue_Add($hash, $hue, $sat, $val, undef, $minDelay, $timeFrom);
  }

  # calculate the left and right turn length based
  # startAngle +360 -endAngle % 360 = counter clock
  # endAngle +360 -startAngle % 360 = clockwise
  my $fadeLeft = ($hueFrom + 360 - $hue) % 360;
  my $fadeRight = ($hue + 360 - $hueFrom) % 360;
  my $direction = ($fadeLeft <=> $fadeRight); # -1 = counterclock, +1 = clockwise
  $direction = ($direction == 0)?1:$direction; # in dupt cw
  Log3 ($hash, 4, "$hash->{NAME} color rotation dev cc:$fadeLeft, cw:$fadeRight, shortest:$direction"); 
  $direction *= -1 if ($flags =~ m/.*[lL].*/); # reverse if long path desired (flag l or L is set)

  my $rotation = ($direction == 1)?$fadeRight:$fadeLeft; # angle of hue rotation in based on flags
  my $sFade = abs($sat - $satFrom);
  my $vFade = abs($val - $valFrom);
        
  my ($stepWidth, $steps, $hueToSet, $hueStep, $satToSet, $satStep, $valToSet, $valStep);
  
  # No transition, so set immediately and ignore ramp setting
  if ($rotation == 0 && $sFade == 0 && $vFade == 0)
  {
    Log3 ($hash, 4, "$hash->{NAME} hsv transition with unchanged settings, hsv $hue, $sat, $val, ramp $ramp"); 
    
    $hash->{helper}->{targetTime} = $timeFrom;
    return MilightDevice_HighLevelCmdQueue_Add($hash, $hue, $sat, $val, undef, $minDelay, $timeFrom);
  }

  # Calculate stepWidth
  if ($rotation >= ($sFade || $vFade))
  {
    $stepWidth = ($ramp * 1000 / $rotation); # how long is one step (set hsv) in ms based on hue
  }
  elsif ($sFade  >= ($rotation || $vFade))
  {
    $stepWidth = ($ramp * 1000 / $sFade); # how long is one step (set hsv) in ms based on sat
  }
  else
  {
    $stepWidth = ($ramp * 1000 / $vFade); # how long is one step (set hsv) in ms based on val
  }
  $stepWidth = $minDelay if ($stepWidth < $minDelay); # Make sure we have min stepWidth
  
  # Calculate number of steps
  $steps = int($ramp * 1000 / $stepWidth);
  
  Log3 ($hash, 4, "$hash->{NAME} transition steps: $steps stepWidth: $stepWidth");  
  
  # Calculate hue step  
  $hueToSet = $hueFrom; # Start at current hue
  $hueStep = $rotation / $steps * $direction;
  
  # Calculate saturation step
  $satToSet = $satFrom; # Start at current saturation
  $satStep = ($sat - $satFrom) / $steps;
  
  # Calculate brightness step
  $valToSet = $valFrom;  # Start at current brightness
  $valStep = ($val - $valFrom) / $steps;

  for (my $i=1; $i <= $steps; $i++)
  {
    $hueToSet += $hueStep; # Increment new hue by step (negative step decrements)
    $hueToSet -= 360 if ($hueToSet > 360); #handle turn over zero
    $hueToSet += 360 if ($hueToSet < 0);
    $satToSet += $satStep; # Increment new hue by step (negative step decrements)
    $valToSet += $valStep; # Increment new hue by step (negative step decrements)
    Log3 ($hash, 4, "$hash->{NAME} add to hl queue h:".($hueToSet).", s:".($satToSet).", v:".($valToSet)." ($i/$steps)");  
    MilightDevice_HighLevelCmdQueue_Add($hash, round($hueToSet), round($satToSet), round($valToSet), undef, $stepWidth, $timeFrom + (($i-1) * $stepWidth / 1000) );
  }
  # Set target time for completion of sequence. 
  # This may be slightly higher than what was requested since $stepWidth > minDelay (($steps * $stepWidth) > $ramp)
  $hash->{helper}->{targetTime} = $timeFrom + ($steps * $stepWidth);
  return undef;
}

sub
MilightDevice_setHSV_Readings(@)
{
  my ($hash, $hue, $sat, $val, $val_on) = @_;
  
  readingsBeginUpdate($hash); # Start update readings
  
  # Store previous state if different to requested state
  my $prevHue = ReadingsVal($hash->{NAME}, "hue", 0);
  my $prevSat = ReadingsVal($hash->{NAME}, "saturation", 0);
  my $prevVal = ReadingsVal($hash->{NAME}, "brightness", 0);
  if (($prevHue != $hue) || ($prevSat != $sat) || ($prevVal != $val))
  {
    readingsBulkUpdate($hash, "previousState", MilightDevice_HSVToStr($hash, $prevHue, $prevSat, $prevVal)); 
  }
  # Store requested values
  readingsBulkUpdate($hash, "hue", $hue);
  readingsBulkUpdate($hash, "saturation", $sat);
  readingsBulkUpdate($hash, "brightness", $val);
  # Store on brightness so we can turn on at a set brightness
  readingsBulkUpdate($hash, "brightness_on", $val_on);
  if (($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW'))
  {
    # Calc RGB values from HSV
    my ($r,$g,$b) = Color::hsv2rgb($hue/360.0,$sat/100.0,$val/100.0);
    $r *=255; $g *=255; $b*=255;
    # Store values
    readingsBulkUpdate($hash, "RGB", sprintf("%02X%02X%02X",$r,$g,$b)); # Int to Hex convert
    readingsBulkUpdate($hash, "discoMode", 0);
    readingsBulkUpdate($hash, "discoSpeed", 0);
  }
  elsif ($hash->{LEDTYPE} eq 'White')
  {
    readingsBulkUpdate($hash, "colourTemperature", $hue); 
  }
  readingsBulkUpdate($hash, "state", "on $val") if ($val > 0);
  readingsBulkUpdate($hash, "state", "off") if ($val == 0);
  readingsEndUpdate($hash, 0);
}

sub
MilightDevice_setDisco_Readings(@)
{
  # Step/Speed can be "1" or "0" when active
  my ($hash, $step, $speed) = @_;
  
  if (($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW'))
  {
    my $discoMode = ReadingsVal($hash->{NAME}, "discoMode", 0);
    $discoMode = "on";
    
    my $discoSpeed = ReadingsVal($hash->{NAME}, "discoSpeed", 5);
    $discoSpeed = "-" if ($speed == 0);
    $discoSpeed = "+" if ($speed == 1);
    
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "discoMode", $step);
    readingsBulkUpdate($hash, "discoSpeed", $speed);
    readingsEndUpdate($hash, 0);
  }
  
}

sub
MilightDevice_ColorConverter(@)
{
  my ($hash) = @_;

  my @colorMap;

  my $adjRed = 0;
  my $adjYellow = 60;
  my $adjGreen = 120;
  my $adjCyan = 180;
  my $adjBlue = 240;
  my $adjLilac = 300;

  my $devRed = 176; # (0xB0)
  #my $devYellow = 128; # (0x80)
  my $devYellow = 144;
  my $devGreen = 96; # (0x60)
  #my $devCyan = 48; # (0x30)
  my $devCyan = 56;
  my $devBlue = 16; # (0x10)
  my $devLilac = 224; # (0xE0)

  my $i= 360;

  # red to yellow
  $adjRed += 360 if ($adjRed < 0); # in case of negative adjustment
  $devRed += 256 if ($devRed < $devYellow);
  $adjYellow += 360 if ($adjYellow < $adjRed);
  for ($i = $adjRed; $i <= $adjYellow; $i++)
  {
    $colorMap[$i % 360] = ($devRed - int((($devRed - $devYellow) / ($adjYellow - $adjRed)  * ($i - $adjRed)) +0.5)) % 255;
    Log3 ($hash, 4, "$hash->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #yellow to green
  $devYellow += 256 if ($devYellow < $devGreen);
  $adjGreen += 360 if ($adjGreen < $adjYellow);
  for ($i = $adjYellow; $i <= $adjGreen; $i++)
  {
    $colorMap[$i % 360] = ($devYellow - int((($devYellow - $devGreen) / ($adjGreen - $adjYellow)  * ($i - $adjYellow)) +0.5)) % 255;
    Log3 ($hash, 4, "$hash->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #green to cyan
  $devGreen += 256 if ($devGreen < $devCyan);
  $adjCyan += 360 if ($adjCyan < $adjGreen);
  for ($i = $adjGreen; $i <= $adjCyan; $i++)
  {
    $colorMap[$i % 360] = ($devGreen - int((($devGreen - $devCyan) / ($adjCyan - $adjGreen)  * ($i - $adjGreen)) +0.5)) % 255;
    Log3 ($hash, 4, "$hash->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #cyan to blue
  $devCyan += 256 if ($devCyan < $devCyan);
  $adjBlue += 360 if ($adjBlue < $adjCyan);
  for ($i = $adjCyan; $i <= $adjBlue; $i++)
  {
    $colorMap[$i % 360] = ($devCyan - int((($devCyan - $devBlue) / ($adjBlue - $adjCyan)  * ($i - $adjCyan)) +0.5)) % 255;
    Log3 ($hash, 4, "$hash->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #blue to lilac
  $devBlue += 256 if ($devBlue < $devLilac);
  $adjLilac += 360 if ($adjLilac < $adjBlue);
  for ($i = $adjBlue; $i <= $adjLilac; $i++)
  {
    $colorMap[$i % 360] = ($devBlue - int((($devBlue - $devLilac) / ($adjLilac - $adjBlue)  * ($i- $adjBlue)) +0.5)) % 255;
    Log3 ($hash, 4, "$hash->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #lilac to red
  $devLilac += 256 if ($devLilac < $devRed);
  $adjRed += 360 if ($adjRed < $adjLilac);
  for ($i = $adjLilac; $i <= $adjRed; $i++)
  {
    $colorMap[$i % 360] = ($devLilac - int((($devLilac - $devRed) / ($adjRed - $adjLilac)  * ($i - $adjLilac)) +0.5)) % 255;
    Log3 ($hash, 4, "$hash->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }

  return \@colorMap;
}

###############################################################################
#
# high level queue, long running color transitions
#
###############################################################################

sub
MilightDevice_HighLevelCmdQueue_Add(@)
{
  my ($hash, $hue, $sat, $val, $ctrl, $delay, $targetTime) = @_;
  my $cmd;
  
  # Validate input
  ($hue, $sat, $val) = MilightDevice_validateHSV($hash, $hue, $sat, $val);

  $cmd->{hue} = $hue;
  $cmd->{sat} = $sat;
  $cmd->{val} = $val;
  $cmd->{ctrl} = $ctrl;
  $cmd->{delay} = $delay;
  $cmd->{targetTime} = $targetTime;
  $cmd->{inProgess} = 0;

  push @{$hash->{helper}->{hlCmdQueue}}, $cmd;

  my $dbgStr = unpack("H*", $cmd->{ctrl} || '');
  Log3 ($hash, 4, "$hash->{NAME} high level cmd queue add hsv/ctrl $cmd->{hue}, $cmd->{sat}, $cmd->{val}, ctrl $dbgStr, targetTime $cmd->{targetTime}, qlen ".@{$hash->{helper}->{hlCmdQueue}});

  my $actualCmd = @{$hash->{helper}->{hlCmdQueue}}[0];

  # sender busy ?
  return undef if (($actualCmd->{inProgess} || 0) == 1);
  return MilightDevice_HighLevelCmdQueue_Exec($hash);
}

sub
MilightDevice_HighLevelCmdQueue_Exec(@)
{
  my ($hash) = @_; 
  my $actualCmd = @{$hash->{helper}->{hlCmdQueue}}[0];

  # transmission complete, remove
  shift @{$hash->{helper}->{hlCmdQueue}} if ($actualCmd->{inProgess});

  # next in queue
  $actualCmd = @{$hash->{helper}->{hlCmdQueue}}[0];
  my $nextCmd = @{$hash->{helper}->{hlCmdQueue}}[1];

  # return if no more elements in queue
  return undef if (!defined($actualCmd->{inProgess}));

  # drop frames if next frame is already scheduled for given time. do not drop if it is the last frame or if it is a command  
  while (defined($nextCmd->{targetTime}) && ($nextCmd->{targetTime} < gettimeofday()) && !$actualCmd->{ctrl})
  {
    shift @{$hash->{helper}->{hlCmdQueue}};
    $actualCmd = @{$hash->{helper}->{hlCmdQueue}}[0];
    $nextCmd = @{$hash->{helper}->{hlCmdQueue}}[1];
    Log3 ($hash, 4, "$hash->{NAME} high level cmd queue exec drop frame at hlQueue level. hl qlen: ".@{$hash->{helper}->{hlCmdQueue}});
  }
  Log3 ($hash, 5, "$hash->{NAME} high level cmd queue exec dropper delay: ".($actualCmd->{targetTime} - gettimeofday()) );

  # set hsv or if a device ctrl command is scheduled: send it and ignore hsv
  if ($actualCmd->{ctrl})
  {
    my $dbgStr = unpack("H*", $actualCmd->{ctrl});
    Log3 ($hash, 4, "$hash->{NAME} high level cmd queue exec ctrl $dbgStr, qlen ".@{$hash->{helper}->{hlCmdQueue}});
    IOWrite($hash, $actualCmd->{ctrl});
  }
  else
  {
    MilightDevice_setHSV($hash, $actualCmd->{hue}, $actualCmd->{sat}, $actualCmd->{val});
  }
  $actualCmd->{inProgess} = 1;
  my $next = defined($nextCmd->{targetTime})?$nextCmd->{targetTime}:gettimeofday() + ($actualCmd->{delay} / 1000);
  Log3 ($hash, 4, "$hash->{NAME} high level cmd queue ask next $next");
  InternalTimer($next, "MilightDevice_HighLevelCmdQueue_Exec", $hash, 0);
  return undef;
}

sub
MilightDevice_HighLevelCmdQueue_Clear(@)
{
  my ($hash) = @_;
  foreach my $args (keys %intAt) 
  {
    if (($intAt{$args}{ARG} eq $hash) && ($intAt{$args}{FN} eq 'MilightDevice_HighLevelCmdQueue_Exec'))
    {
      Log3 ($hash, 4, "$hash->{NAME} high level cmd queue clear, remove timer at ".$intAt{$args}{TRIGGERTIME} );
      delete($intAt{$args}) ;
    }
  }
  $hash->{helper}->{hlCmdQueue} = [];
}

1;