##############################################
# $Id: 32_MILIGHT.pm 69 2014-08-28 08:00:00Z herrmannj $

# TODO
# Do I need ColorConverter?

# versions
# 1 MILIGHT specific.  Based on 32_WifiLight code by herrmannj.

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
MILIGHT_Initialize(@)
{
  my ($hash) = @_;

  $hash->{DefFn} = "MILIGHT_Define";
  $hash->{UndefFn} = "MILIGHT_Undef";
  $hash->{ShutdownFn} = "MILIGHT_Undef";
  $hash->{SetFn} = "MILIGHT_Set";
  $hash->{GetFn} = "MILIGHT_Get";
  $hash->{AttrFn} = "MILIGHT_Attr";
  $hash->{NotifyFn} = "MILIGHT_Notify";
  $hash->{AttrList} = "dimStep defaultRampOn defaultRampOff";

  FHEM_colorpickerInit();
    
  return undef;
}

sub
MILIGHT_devStateIcon($)
{
  my($hash) = @_;
  $hash = $defs{$hash} if( ref($hash) ne 'HASH' );

  return undef if( !$hash );
  return undef if( $hash->{helper}->{group} );

  my $name = $hash->{NAME};

  my $percent = ReadingsVal($name,"brightness","100");
  my $s = $dim_values{int($percent/10)};

  # Return SVG coloured icon with toggle as default action
  return ".*:light_light_$s@#".ReadingsVal($name, "RGB", "FFFFFF").":toggle"
            if (($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW'));
  # Return SVG icon with toggle as default action (for White bulbs)
  return ".*:light_light_$s:toggle";
}

sub
MILIGHT_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def); 
  my $name = $a[0];
  my $key;

  return "wrong syntax: define <name> MILIGHT <type> <connection> <slot>" if(@a != 5);
  return "unknown LED type ($a[2]): choose one of RGB, RGBW, White" if !($a[2] ~~ ['RGB', 'RGBW', 'White']);
  
  $hash->{LEDTYPE} = $a[2];

  return "Invalid slot: Select one of 1..4 for White" if (($a[4] !~ /^\d*$/) || (($a[4] < 1) || ($a[4] > 4)) && ($hash->{LEDTYPE} eq 'White'));
  return "Invalid slot: Select one of 5..8 for RGBW" if (($a[4] !~ /^\d*$/) || (($a[4] < 5) || ($a[4] > 8)) && ($hash->{LEDTYPE} eq 'RGBW'));
  return "Invalid slot: Select 0 for RGB" if (($a[4] !~ /^\d*$/) || ($a[4] != 0) && ($hash->{LEDTYPE} eq 'RGB'));
  my $slot = $a[4];

  my $otherLights;

  $a[3] =~ m/(bridge-V[23]):([^:]+):*(\d+)*/g;
  $hash->{CONNECTION} = $1;
  return "unknown connection type: choose one of bridge-V2:<ip/FQDN>, bridge-V3:<ip/FQDN>" if !(defined($hash->{CONNECTION})); 
  
  $hash->{IP} = $2;
  # Port is 50000 for bridge-V2, 8899 for bridge-V3
  $hash->{PORT} = $3?$3:50000 if ($a[3] =~ m/(bridge-V2):([^:]+):*(\d+)*/g);
  $hash->{PORT} = $3?$3:8899 if ($a[3] =~ m/(bridge-V3):([^:]+):*(\d+)*/g);
  my @hlCmdQueue = [];
  $hash->{helper}->{hlCmdQueue} = \@hlCmdQueue;
  # search if this bridge is already defined 
  # if so, we need a shared buffer (llCmdQueue), shared socket and we need to check if the requied slot is free
  foreach $key (keys %defs) 
  {
    if (($defs{$key}{TYPE} eq 'MILIGHT') && ($defs{$key}{IP} eq $hash->{IP}) && ($key ne $name))
    {
      #bridge is in use
      Log3 (undef, 3, "MILIGHT: Adding $hash->{NAME} to existing bridge $hash->{CONNECTION} at $hash->{IP}");
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
  
  Log3 ($hash, 4, "define $a[0] $a[1] $a[2] $a[3]");

  # Find next free slot for new bulb
  if ($hash->{LEDTYPE} eq 'RGB')
  {
    # One bridge per RGB bulb is required.
    return "no free slot at $hash->{CONNECTION} ($hash->{IP}) for $hash->{LEDTYPE}" if (defined($otherLights->{0}));
    $hash->{SLOT} = $a[4]; 
  }
  elsif (($hash->{LEDTYPE} eq 'RGBW') || ($hash->{LEDTYPE} eq 'White'))
  {
    # Each bridge supports 4 RGBW and 4 White bulbs (only bridge-V3).
    if (defined($otherLights->{$slot}))
    {
      return "Duplicate slot ($slot) defined for $hash->{NAME}!" if (defined($otherLights->{$slot}));
    }
    else
    {
      $hash->{SLOT} = $slot;
    }
  }
  else
  {
  	return "$hash->{LEDTYPE} is not supported at $hash->{CONNECTION} ($hash->{IP})";
  }
  
  # Colormap / Commandsets
  if (($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW'))
  {
    $hash->{helper}->{COLORMAP} = MILIGHT_Milight_ColorConverter($hash);
  }
  $hash->{helper}->{COMMANDSET} = "on off toggle dim:slider,0,".round(100/MILIGHT_dimSteps($hash)).",100 dimup dimdown HSV rgb:colorpicker,RGB discoModeUp discoSpeedUp discoSpeedDown pair unpair"
  			if ($hash->{LEDTYPE} eq 'RGBW');
  $hash->{helper}->{COMMANDSET} = "on off toggle dim:slider,0,".round(100/MILIGHT_dimSteps($hash)).",100 dimup dimdown HSV rgb:colorpicker,RGB discoModeUp discoModeDown discoSpeedUp discoSpeedDown pair unpair"
  			if ($hash->{LEDTYPE} eq 'RGB');
  			
  $hash->{helper}->{COMMANDSET} = "on off toggle dim:slider,0,".round(100/MILIGHT_dimSteps($hash)).",100 dimup dimdown colourtemp:slider,1,1,10 pair unpair"
  			if ($hash->{LEDTYPE} eq 'White');
  
  # webCmds
  $attr{$name}{webCmd} = 'rgb:rgb ff2a00:rgb 00ff00:rgb 0000ff:rgb ffff00:on:off:dim' if ($hash->{LEDTYPE} eq 'RGB');
  $attr{$name}{webCmd} = 'rgb:rgb ffffff:rgb ff2a00:rgb 00ff00:rgb 0000ff:rgb ffff00:on:off:dim' if ($hash->{LEDTYPE} eq 'RGBW');
  $attr{$name}{webCmd} = 'on:off:dim:colourtemp' if ($hash->{LEDTYPE} eq 'White');
  
  # Define devStateIcon
  $attr{$name}{devStateIcon} = '{(MILIGHT_devStateIcon($name),"toggle")}' if( !defined( $attr{$name}{devStateIcon} ) );
  
  return undef;
}

sub
MILIGHT_Undef(@)
{
  return undef;
}

sub
MILIGHT_Set(@)
{
  my ($hash, $name, $cmd, @a) = @_;
  my $cnt = @a;
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
    if (defined($a[0]))
    {
      return "Usage: set $name pair <seconds(0..X)>" if ($a[0] !~ /^\d+$/);
      $ramp = $a[0];
    }
    MILIGHT_HighLevelCmdQueue_Clear($hash);
    return MILIGHT_RGB_Pair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_Pair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_Pair($hash, $ramp) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'unpair')
  {
    if (defined($a[0]))
    {
      return "Usage: set $name unpair <seconds(0..X)>" if ($a[0] !~ /^\d+$/);
      $ramp = $a[0];
    }
    MILIGHT_HighLevelCmdQueue_Clear($hash);
    return MILIGHT_RGB_UnPair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_UnPair($hash, $ramp) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_UnPair($hash, $ramp) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'on')
  {
    if (defined($a[0]))
    {
      return "Usage: set $name on <seconds(0..X)>" if ($a[0] !~ /^\d+$/);
      $ramp = $a[0];
    }
    elsif (defined($attr{$name}{defaultRampOn}))
    {
      $ramp = $attr{$name}{defaultRampOn};
    }
    return MILIGHT_RGB_On($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_On($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_On($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'off')
  {
    if (defined($a[0]))
    {
      return "Usage: set $name off <seconds(0..X)>" if ($a[0] !~ /^\d+$/);
      $ramp = $a[0];
    }
    elsif (defined($attr{$name}{defaultRampOff}))
    {
      $ramp = $attr{$name}{defaultRampOff};
    }
    return MILIGHT_RGB_Off($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_Off($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_Off($hash, $ramp, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'dimup')
  {
    return "Usage: set $name dimup" if (defined($a[1]));
    my $v = ReadingsVal($hash->{NAME}, "brightness", 0) + round(100 / MILIGHT_dimSteps($hash));
    $v = 100 if $v > 100;
    return MILIGHT_RGB_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'dimdown')
  {
    return "Usage: set $name dimdown" if (defined($a[1]));
    my $v = ReadingsVal($hash->{NAME}, "brightness", 0) - (100 / MILIGHT_dimSteps($hash));
    $v = 0 if $v < 0;
    return MILIGHT_RGB_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_Dim($hash, $v, 0, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif ($cmd eq 'dim')
  {
    $usage = "Usage: set $name dim <percent(0..100)> [seconds(0..x)] [flags(l=long path|q=don't clear queue)]";
    return $usage if (($a[0] !~ /^\d+$/) || (!($a[0] ~~ [0..100]))); # Decimal value for percent between 0..100
    if (defined($a[1]))
    {
      return $usage if (($a[1] !~ /^\d+$/) && ($a[1] > 0)); # Decimal value for ramp > 0
      $ramp = $a[1];
    }
    if (defined($a[2]))
    {   
      return $usage if ($a[2] !~ m/.*[lLqQ].*/); # Flags l=Long way round for transition, q=don't clear queue (add to end)
      $flags = $a[2];
    }
    return MILIGHT_RGB_Dim($hash, $a[0], $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_Dim($hash, $a[0], $ramp, $flags) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_Dim($hash, $a[0], $ramp, $flags) if ($hash->{LEDTYPE} eq 'White');
  }

  elsif( $cmd eq "rgb")
  {
    $usage = "Usage: set $name rgb RRGGBB [seconds(0..x)] [flags(l=long path|q=don't clear queue)]";
    return $usage if ($a[0] !~ /^([0-9A-Fa-f]{1,2})([0-9A-Fa-f]{1,2})([0-9A-Fa-f]{1,2})$/);
    my( $r, $g, $b ) = (hex($1)/255.0, hex($2)/255.0, hex($3)/255.0);
    my( $h, $s, $v ) = Color::rgb2hsv($r,$g,$b);
    if (defined($a[1]))
    {
      return $usage if (($a[1] !~ /^\d+$/) && ($a[1] > 0)); # Decimal value for ramp > 0
      $ramp = $a[1];
    }
    if (defined($a[2]))
    {   
      return $usage if ($a[2] !~ m/.*[lLqQ].*/); # Flags l=Long way round for transition, q=don't clear queue (add to end)
      $flags = $a[2];
    }
    MILIGHT_HSV_Transition($hash, $h, $s, $v, $ramp, $flags, 100);
    return MILIGHT_SetHSV_Target($hash, $h, $s, $v);    
  }

  elsif ($cmd eq 'hsv')
  {
    $usage = "Usage: set $name hsv <h(0..360)>,<s(0..100)>,<v(0..100)> [seconds(0..x)] [flags(l=long path|q=don't clear queue)]";
    return $usage if ($a[0] !~ /^(\d{1,3}),(\d{1,3}),(\d{1,3})$/);
    my ($h, $s, $v) = ($1, $2, $3);
    return "Invalid hue ($h): valid range 0..360" if !(($hue >= 0) && ($hue <= 360));
    return "Invalid saturation ($s): valid range 0..100" if !(($sat >= 0) && ($sat <= 100));
    return "Invalid brightness ($v): valid range 0..100" if !(($val >= 0) && ($val <= 100));
    if (defined($a[1]))
    {
      return $usage if (($a[1] !~ /^\d+$/) && ($a[1] > 0)); # Decimal value for ramp > 0
      $ramp = $a[1];
    }
    if (defined($a[2]))
    {   
      return $usage if ($a[2] !~ m/.*[lLqQ].*/); # Flags l=Long way round for transition, q=don't clear queue (add to end)
      $flags = $a[2];
    }
    MILIGHT_HSV_Transition($hash, $h, $s, $v, $ramp, $flags, 100);
    return MILIGHT_SetHSV_Target($hash, $h, $s, $v);
  }
  
  elsif ($cmd eq 'discoModeUp')
  {
    return MILIGHT_RGBW_DiscoModeStep($hash, 1);
  }

  elsif ($cmd eq 'discoModeDown')
  {
    return MILIGHT_RGBW_DiscoModeStep($hash, 0);
  }
    
  elsif ($cmd eq 'discoSpeedUp')
  {
    return MILIGHT_RGBW_DiscoModeSpeed($hash, 1);
  }

  elsif ($cmd eq 'discoSpeedDown')
  {
    return MILIGHT_RGBW_DiscoModeSpeed($hash, 0);
  }
    
  elsif ($cmd eq 'colourtemp')
  {
    if (defined($a[0]))
    {
      return "Usage: set $name colourTemperature <1=Cool..10=Warm>" if (($a[0] !~ /^\d+$/) || (!($a[0] ~~ [1..10])));
    }
    return MILIGHT_White_setColourTemp($hash, $a[0]);
  }

  return SetExtensions($hash, $hash->{helper}->{COMMANDSET}, $name, $cmd, @a);
}

sub
MILIGHT_Get(@)
{
  my ($hash, @a) = @_;

  my $name = $a[0];
  return "$name: get needs at least one parameter" if(@a < 2);

  my $cmd= $a[1];

  if($cmd eq "rgb" || $cmd eq "RGB") {
    return ReadingsVal($name, "RGB", "FFFFFF");
  }
  
  return "Unknown argument $cmd, choose one of rgb:noArg RGB:noArg";
}

sub
MILIGHT_Attr(@)
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
MILIGHT_Notify(@)
{
  my ($hash, $eventSrc) = @_;
  my $events = deviceEvents($eventSrc, 1);
  my ($hue, $sat, $val);

  # wait for global: INITIALIZED after start up
  if ($eventSrc->{NAME} eq 'global' && @{$events}[0] eq 'INITIALIZED')
  {
    # Default to OFF if not defined
    $hue = defined($hash->{READINGS}->{hue}->{VAL})?$hash->{READINGS}->{hue}->{VAL}:0;
    $sat = defined($hash->{READINGS}->{saturation}->{VAL})?$hash->{READINGS}->{saturation}->{VAL}:0;
    $val = defined($hash->{READINGS}->{brightness}->{VAL})?$hash->{READINGS}->{brightness}->{VAL}:0;
    
    # Restore state
    return MILIGHT_RGB_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGB');
    return MILIGHT_RGBW_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGBW');
    return MILIGHT_White_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'White');
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
MILIGHT_RGB_Pair(@)
{
  my ($hash, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  Log3 ($hash, 3, "$hash->{NAME} RGB LED slot $hash->{SLOT} pair $numSeconds s"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 1000, undef);
  }
  return undef;
}

sub
MILIGHT_RGB_UnPair(@)
{
  my ($hash) = @_;
  my $numSeconds = 8;
  Log3 ($hash, 3, "$hash->{NAME} RGB LED slot $hash->{SLOT} unpair $numSeconds s"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 250, undef);
  }
  return undef;
}

sub
MILIGHT_RGB_On(@)
{
  my ($hash, $ramp, $flags) = @_;
  my $v = 100;
  Log3 ($hash, 3, "$hash->{NAME} RGB slot $hash->{SLOT} set on $ramp");
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
  if ($v < round(100/MILIGHT_dimSteps($hash)))
  {
    $v = 100;
  }

  return MILIGHT_RGB_Dim($hash, $v, $ramp, $flags); 
}

sub
MILIGHT_RGB_Off(@)
{
  my ($hash, $ramp, $flags) = @_;
  Log3 ($hash, 3, "$hash->{NAME} RGB slot $hash->{SLOT} set off $ramp");
  # Store value of brightness before turning off
  # "on" will be of the form "on 50" where 50 is current dimlevel
  if (ReadingsVal($hash->{NAME}, "state", "off") ne "off")
  {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "brightness_on", ReadingsVal($hash->{NAME}, "brightness", 100));
    readingsEndUpdate($hash, 0);
  }
  return MILIGHT_RGB_Dim($hash, 0, $ramp, $flags);
}

sub
MILIGHT_RGB_Dim(@)
{
  my ($hash, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($hash->{NAME}, "hue", 0);
  my $s = ReadingsVal($hash->{NAME}, "saturation", 0);
  Log3 ($hash, 3, "$hash->{NAME} RGB slot $hash->{SLOT} dim $level $ramp $flags"); 
  return MILIGHT_HSV_Transition($hash, $h, $s, $level, $ramp, $flags, 500);
}

sub
MILIGHT_RGB_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  Log3 ($hash, 4, "$hash->{NAME} RGB slot $hash->{SLOT} set h:$hue, s:$sat, v:$val"); 
  $sat = 100;
  MILIGHT_setHSV_Readings($hash, $hue, $sat, $val);
  # convert to device specs
  my ($cv, $cl, $wl) = MILIGHT_RGB_ColorConverter($hash, $hue, $sat, $val);
  Log3 ($hash, 4, "$hash->{NAME} RGB slot $hash->{SLOT} set levels: $cv, $cl, $wl");
  return MILIGHT_RGB_setLevels($hash, $cv, $cl, $wl);
}

sub
MILIGHT_RGB_setLevels(@)
{
  my ($hash, $cv, $cl, $wl) = @_;
  my $receiver = sockaddr_in($hash->{PORT}, inet_aton($hash->{IP}));
  my $delay = 100;
  my $lock = 0;

  # mode 0: off, 1: mixed "white", 2: color
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  if ((($hash->{helper}->{colorValue} != $cv) && ($cl > 0)) || ($hash->{helper}->{colorLevel} != $cl) || ($hash->{helper}->{whiteLevel} != $wl))
  {
    $hash->{helper}->{llLock} += 1;
    $lock = 1;
  }
  # need to touch color value (only if visible) or color level ?
  if ((($hash->{helper}->{colorValue} != $cv) && ($cl > 0)) || $hash->{helper}->{colorLevel} != $cl)
  {
    # if color all off switch on
    if ($hash->{helper}->{mode} == 0)
    {
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x22\x00\x55", $receiver, $delay); # switch on
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $hash->{helper}->{colorValue} = $cv;
      $hash->{helper}->{colorLevel} = 1;
      $hash->{helper}->{mode} = 2;
    }
    elsif ($hash->{helper}->{mode} == 1)
    {
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $hash->{helper}->{colorValue} = $cv;
      $hash->{helper}->{mode} = 2;
    }
    else
    {
      $hash->{helper}->{colorValue} = $cv;
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
    }
    # cl decrease
    if ($hash->{helper}->{colorLevel} > $cl)
    {
      for (my $i=$hash->{helper}->{colorLevel}; $i > $cl; $i--) 
      {
        MILIGHT_LowLevelCmdQueue_Add($hash, "\x24\x00\x55", $receiver, $delay); # brightness down
        $hash->{helper}->{colorLevel} = $i - 1;
      }
      if ($cl == 0)
      {
        # need to switch off color
        # if no white is required and no white is active we can must entirely switch off
        MILIGHT_LowLevelCmdQueue_Add($hash, "\x21\x00\x55", $receiver, $delay); # switch off
        $hash->{helper}->{colorLevel} = 0;
        $hash->{helper}->{mode} = 0;
      }
    }
    # cl inrease
    if ($hash->{helper}->{colorLevel} < $cl)
    {
      for (my $i=$hash->{helper}->{colorLevel}; $i < $cl; $i++)
      {
        MILIGHT_LowLevelCmdQueue_Add($hash, "\x23\x00\x55", $receiver, $delay); # brightness up
        $hash->{helper}->{colorLevel} = $i + 1;
      }
    }
  }
  # unlock ll queue
  MILIGHT_LowLevelCmdQueue_Add($hash, "\x00", $receiver, 0, 1) if $lock;
  return undef;
}

sub
MILIGHT_RGB_ColorConverter(@)
{
  my ($hash, $h, $s, $v) = @_;
  my $color = $hash->{helper}->{COLORMAP}[$h % 360];
  
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
# device specific functions RGBW bulb 
# RGB white, only bridge V3
#
###############################################################################

sub
MILIGHT_RGBW_Pair(@)
{
  my ($hash, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($hash, 3, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 1000, undef);
  }
  return undef;
}

sub
MILIGHT_RGBW_UnPair(@)
{
  my ($hash, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($hash, 3, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $onCtrl = @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55";
  my $fullOnCtrl = "\x4E\x1B\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $fullOnCtrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $fullOnCtrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $fullOnCtrl, 250, undef);
  }
  return undef;
}

sub
MILIGHT_RGBW_On(@)
{
  my ($hash, $ramp, $flags) = @_;
  my $v = 100;
  Log3 ($hash, 3, "$hash->{NAME} RGBW slot $hash->{SLOT} set on $ramp");
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
  if ($v < round(100/MILIGHT_dimSteps($hash)))
  {
    $v = 100;
  }

  return MILIGHT_RGBW_Dim($hash, $v, $ramp, $flags); 
}

sub
MILIGHT_RGBW_Off(@)
{
  my ($hash, $ramp, $flags) = @_;
  Log3 ($hash, 3, "$hash->{NAME} RGBW slot $hash->{SLOT} set off $ramp");
  # Store value of brightness before turning off
  # "on" will be of the form "on 50" where 50 is current dimlevel
  if (ReadingsVal($hash->{NAME}, "state", "off") ne "off")
  {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "brightness_on", ReadingsVal($hash->{NAME}, "brightness", 100));
    readingsEndUpdate($hash, 0);
  }
  return MILIGHT_RGBW_Dim($hash, 0, $ramp, $flags);
}

sub
MILIGHT_RGBW_Dim(@)
{
  my ($hash, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($hash->{NAME}, "hue", 0);
  my $s = ReadingsVal($hash->{NAME}, "saturation", 0);
  Log3 ($hash, 3, "$hash->{NAME} RGBW slot $hash->{SLOT} dim $level $ramp ". $flags || ''); 
  return MILIGHT_HSV_Transition($hash, $h, $s, $level, $ramp, $flags, 100);
}

sub
MILIGHT_RGBW_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  my ($cl, $wl);

  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  my @bulbCmdsOff = ("\x46", "\x48", "\x4A", "\x4C");
  my @bulbCmdsWT = ("\xC5", "\xC7", "\xC9", "\xCB");

  my $receiver = sockaddr_in($hash->{PORT}, inet_aton($hash->{IP}));
  my $delay = 100;
  my $cv = $hash->{helper}->{COLORMAP}[$hue % 360];

  # mode 0 = off, 1 = color, 2 = white, 3 = disco
  # brightness 2..27 (x02..x1b) | 25 dim levels
  my $cf = int((($val / 100) * 25) + 2);
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
  
  Log3 ($hash, 3, "DEBUG: wl $wl cl $cl");
  # Set readings in FHEM
  MILIGHT_setHSV_Readings($hash, $hue, $sat, $val);

  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $hash->{helper}->{llLock} += 1;
  Log3 ($hash, 5, "$hash->{NAME} RGBW slot $hash->{SLOT} lock queue ".$hash->{helper}->{llLock});

  # Off is shifted to "2" above so check for < 3
  if (($wl < 3) && ($cl < 3)) # off
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOff[$hash->{SLOT} -5]."\x00\x55", $receiver, $delay); # group off
    $hash->{helper}->{whiteLevel} = 0;
    $hash->{helper}->{colorLevel} = 0;
    $hash->{helper}->{mode} = 0; # group off
  }
  else # on
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55", $receiver, $delay) if (($wl > 0) || ($cl > 0)); # group on
    if ($wl > 0) # white
    {
      MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsWT[$hash->{SLOT} -5]."\x00\x55", $receiver, $delay); # white
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x4E".chr($wl)."\x55", $receiver, $delay); # brightness
      $hash->{helper}->{mode} = 2; # white
    }
    elsif ($cl > 0) # color
    {
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x40".chr($cv)."\x55", $receiver, $delay); # color
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x4E".chr($cl)."\x55", $receiver, $delay); # brightness
      $hash->{helper}->{mode} = 1; # color
    }

    $hash->{helper}->{colorValue} = $cv;
    $hash->{helper}->{colorLevel} = $cl;
    $hash->{helper}->{whiteLevel} = $wl;
  }
  # unlock ll queue after complete cmd is send
  MILIGHT_LowLevelCmdQueue_Add($hash, "\x00", $receiver, 0, 1);
  
  return undef;
}

sub
MILIGHT_RGBW_DiscoModeStep(@)
{
  my ($hash, $step) = @_;
  
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");

  my $receiver = sockaddr_in($hash->{PORT}, inet_aton($hash->{IP}));
  my $delay = 100;
  
  MILIGHT_HighLevelCmdQueue_Clear($hash);
  
  $step = 0 if ($step < 0);
  $step = 1 if ($step > 1);
  
  # Set readings in FHEM
  MILIGHT_setDisco_Readings($hash, $step, ReadingsVal($hash->{NAME}, 'discoSpeed', 5));

  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $hash->{helper}->{llLock} += 1;
  Log3 ($hash, 5, "$hash->{NAME} RGBW slot $hash->{SLOT} lock queue ".$hash->{helper}->{llLock});

  MILIGHT_LowLevelCmdQueue_Add($hash, "\x22\x00\x55", $receiver, $delay) if (($hash->{LEDTYPE} eq 'RGB')); # switch on
  MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55", $receiver, $delay) if (($hash->{LEDTYPE} eq 'RGBW')); # group on

  if ($step == 1)
  {
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x27\x00\x55", $receiver, $delay) if (($hash->{LEDTYPE} eq 'RGB')); # discoMode step up
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x4D\x00\x55", $receiver, $delay) if (($hash->{LEDTYPE} eq 'RGBW')); # discoMode step up
  }
  elsif ($step == 0)
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, "\x28\x00\x55", $receiver, $delay); # discoMode step down
  }
  
  $hash->{helper}->{mode} = 3; # disco

  # unlock ll queue after complete cmd is send
  MILIGHT_LowLevelCmdQueue_Add($hash, "\x00", $receiver, 0, 1);
  
  return undef;
}
sub
MILIGHT_RGBW_DiscoModeSpeed(@)
{
  my ($hash, $speed) = @_;

  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");

  my $receiver = sockaddr_in($hash->{PORT}, inet_aton($hash->{IP}));
  my $delay = 100;

  MILIGHT_HighLevelCmdQueue_Clear($hash);
  
  $speed = 0 if ($speed < 0);
  $speed = 1 if ($speed > 1);
  
  # Set readings in FHEM
  MILIGHT_setDisco_Readings($hash, ReadingsVal($hash->{NAME}, 'discoMode', 1), $speed);
  
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $hash->{helper}->{llLock} += 1;
  Log3 ($hash, 5, "$hash->{NAME} RGBW slot $hash->{SLOT} lock queue ".$hash->{helper}->{llLock});

  MILIGHT_LowLevelCmdQueue_Add($hash, "\x22\x00\x55", $receiver, $delay) if (($hash->{LEDTYPE} eq 'RGB')); # switch on
  MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOn[$hash->{SLOT} -5]."\x00\x55", $receiver, $delay) if (($hash->{LEDTYPE} eq 'RGBW')); # group on

  if ($speed == 1)
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, "\x25\x00\x55", $receiver, $delay) if ($hash->{LEDTYPE} eq 'RGB'); # discoMode speed up
    MILIGHT_LowLevelCmdQueue_Add($hash, "\x44\x00\x55", $receiver, $delay) if ($hash->{LEDTYPE} eq 'RGBW'); # discoMode speed up
  }
  elsif ($speed == 0)
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, "\x26\x00\x55", $receiver, $delay) if ($hash->{LEDTYPE} eq 'RGB'); # discoMode speed down
    MILIGHT_LowLevelCmdQueue_Add($hash, "\x43\x00\x55", $receiver, $delay) if ($hash->{LEDTYPE} eq 'RGBW'); # discoMode speed down
  }

  $hash->{helper}->{mode} = 3; # disco

  # unlock ll queue after complete cmd is send
  MILIGHT_LowLevelCmdQueue_Add($hash, "\x00", $receiver, 0, 1);
  
  return undef;
}

###############################################################################
#
# device specific functions white bulb 
# warm white / cold white with dim, bridge V2|bridge V3
#
###############################################################################

sub
MILIGHT_White_Pair(@)
{
  my ($hash, $numSeconds) = @_;
  $numSeconds = 1 if !(defined($numSeconds));
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  Log3 ($hash, 3, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: pair $numSeconds");
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $ctrl, 1000, undef);
  }
  return undef;
}

sub
MILIGHT_White_UnPair(@)
{
  my ($hash, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsOnFull = ("\xB8", "\xBD", "\xB7", "\xB2");
  Log3 ($hash, 3, "$hash->{NAME}, $hash->{LEDTYPE} at $hash->{CONNECTION}, slot $hash->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $onCtrl = @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55";
  my $fullOnCtrl = @bulbCmdsOnFull[$hash->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $onCtrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $fullOnCtrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $fullOnCtrl, 250, undef);
    MILIGHT_HighLevelCmdQueue_Add($hash, undef, undef, undef, $fullOnCtrl, 250, undef);
  }
  return undef;
}

sub
MILIGHT_White_On(@)
{
  my ($hash, $ramp, $flags) = @_;
  my $v = 100;
  Log3 ($hash, 3, "$hash->{NAME} white slot $hash->{SLOT} set on $ramp"); 
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
  if ($v < round(100/MILIGHT_dimSteps($hash)))
  {
    $v = 100;
  }
  return MILIGHT_White_Dim($hash, $v, $ramp, $flags); 
}

sub
MILIGHT_White_Off(@)
{
  my ($hash, $ramp, $flags) = @_;
  Log3 ($hash, 3, "$hash->{NAME} white slot $hash->{SLOT} set off $ramp"); 
  # Store value of brightness before turning off
  # "on" will be of the form "on 50" where 50 is current dimlevel
  if (ReadingsVal($hash->{NAME}, "state", "off") ne "off")
  {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "brightness_on", ReadingsVal($hash->{NAME}, "brightness", 100));
    readingsEndUpdate($hash, 0);
  }
  return MILIGHT_White_Dim($hash, 0, $ramp, $flags);
}

sub
MILIGHT_White_Dim(@)
{
  my ($hash, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($hash->{NAME}, "hue", 0);
  my $s = ReadingsVal($hash->{NAME}, "saturation", 0);
  Log3 ($hash, 3, "$hash->{NAME} white slot $hash->{SLOT} dim $level $ramp $flags"); 
  return MILIGHT_HSV_Transition($hash, $h, $s, $level, $ramp, $flags, 100);
}

# $hue is colourTemperature, $val is brightness
sub
MILIGHT_White_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  
  # Validate brightness
  $val = 100 if ($val > 100);
  $val = 0 if ($val < 0);

  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsOff = ("\x3B", "\x33", "\x3A", "\x36");
  my $receiver = sockaddr_in($hash->{PORT}, inet_aton($hash->{IP}));
  my $delay = 100;
  
  # Store new values for colourTemperature and Brightness
  MILIGHT_setHSV_Readings($hash, ReadingsVal($hash->{NAME}, "colourTemperature", 1), 0, $val);

  # Calculate brightness hardware value (10 steps for white)
  my $wl = (100 / MILIGHT_dimSteps($hash));
  $wl = int($val / $wl);
  
  # Brightness down
  if ($hash->{helper}->{whiteLevel} > $wl)
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
    Log3 ($hash, 3, "$hash->{NAME} white brightness decrease from $hash->{helper}->{whiteLevel} to $wl");
    for (my $i=$hash->{helper}->{whiteLevel}; $i > $wl; $i--) 
    {
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x34\x00\x55", $receiver, $delay); # brightness down
      $hash->{helper}->{whiteLevel} = $i - 1;
    }
  }
  # Brightness Up
  elsif ($hash->{helper}->{whiteLevel} < $wl)
  {
    $hash->{helper}->{whiteLevel} = 1 if ($hash->{helper}->{whiteLevel} == 0);
    MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
    Log3 ($hash, 3, "$hash->{NAME} white brightness increase from $hash->{helper}->{whiteLevel} to $wl");
    for (my $i=$hash->{helper}->{whiteLevel}; $i < $wl; $i++) 
    {
      MILIGHT_LowLevelCmdQueue_Add($hash, "\x3C\x00\x55", $receiver, $delay); # brightness up
      $hash->{helper}->{whiteLevel} = $i + 1;
    }
  }

  # Make sure we actually send off command if we should be off
  if ($wl == 0)
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOff[$hash->{SLOT} -1]."\x00\x55", $receiver, $delay); # group off
  }
    
  return undef;
}

sub
MILIGHT_White_setColourTemp(@)
{
  # $hue is colourTemperature (1-10), $val is brightness (0-100%)
  my ($hash, $hue) = @_;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my $receiver = sockaddr_in($hash->{PORT}, inet_aton($hash->{IP}));
  my $delay = 100;
  
  MILIGHT_HighLevelCmdQueue_Clear($hash);
 
  # Validate colourTemperature (10 steps)
  $hue = 10 if ($hue > 10);
  $hue = 1 if ($hue < 1);
  
  my $oldHue = ReadingsVal($hash->{NAME}, "colourTemperature", 1);
  
  # Store new values for colourTemperature and Brightness
  MILIGHT_setHSV_Readings($hash, $hue, 0, ReadingsVal($hash->{NAME}, "brightness", 100));
  
  # Set colour temperature
  if ($oldHue != $hue)
  {
    MILIGHT_LowLevelCmdQueue_Add($hash, @bulbCmdsOn[$hash->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
    if ($oldHue > $hue)
    {
      Log3 ($hash, 3, "$hash->{NAME} white colourTemp decrease from $oldHue to $hue");
      for (my $i=$oldHue; $i > $hue; $i--)
      {
        MILIGHT_LowLevelCmdQueue_Add($hash, "\x3F\x00\x55", $receiver, $delay); # Cooler (colourtemp down)
      }
    }
    elsif ($oldHue < $hue)
    {
      Log3 ($hash, 3, "$hash->{NAME} white colourTemp increase from $oldHue to $hue");
      for (my $i=$oldHue; $i < $hue; $i++)
      {
        MILIGHT_LowLevelCmdQueue_Add($hash, "\x3E\x00\x55", $receiver, $delay); # Warmer (colourtemp up)
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

# Return number of steps for each type of bulb
#  White: 10 steps (step = 10)
#  RGB: 9 steps (step = 11)
#  RGBW: 25 steps (step = 4)
sub
MILIGHT_dimSteps(@)
{
  my ($hash) = @_;
  return AttrVal($hash->{NAME}, "dimStep", 10) if ($hash->{LEDTYPE} eq 'White');
  return AttrVal($hash->{NAME}, "dimStep", 9) if ($hash->{LEDTYPE} eq 'RGB');
  return AttrVal($hash->{NAME}, "dimStep", 25) if ($hash->{LEDTYPE} eq 'RGBW');
}

# dispatcher
sub
MILIGHT_setHSV(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  MILIGHT_RGB_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGB');
  MILIGHT_RGBW_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'RGBW');
  MILIGHT_White_setHSV($hash, $hue, $sat, $val) if ($hash->{LEDTYPE} eq 'White');
  return undef;
}

sub
MILIGHT_HSV_Transition(@)
{
  my ($hash, $hue, $sat, $val, $ramp, $flags, $delay) = @_;
  my ($hueFrom, $satFrom, $valFrom, $timeFrom);
  
  # Clear command queue if flag "q" not specified
  MILIGHT_HighLevelCmdQueue_Clear($hash) if ($flags !~ m/.*[qQ].*/);
  
  # minimum stepWidth
  my $minDelay = $delay;

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
    $hueFrom = $hash->{READINGS}->{hue}->{VAL};
    $satFrom = $hash->{READINGS}->{saturation}->{VAL};
    $valFrom = $hash->{READINGS}->{brightness}->{VAL};
    $timeFrom = gettimeofday();
    Log3 ($hash, 5, "$hash->{NAME} prepare start hsv transition (is actual) hsv $hueFrom, $satFrom, $valFrom, $timeFrom");
  }

  Log3 ($hash, 4, "$hash->{NAME} current HSV $hueFrom, $satFrom, $valFrom");
  Log3 ($hash, 3, "$hash->{NAME} set HSV $hue, $sat, $val with ramp: $ramp, flags: ". $flags);

  # if there is no ramp we dont need transition
  if (($ramp || 0) == 0)
  {
    Log3 ($hash, 4, "$hash->{NAME} hsv transition without ramp routed to direct settings, hsv $hue, $sat, $val");
    $hash->{helper}->{targetTime} = $timeFrom;
    return MILIGHT_HighLevelCmdQueue_Add($hash, $hue, $sat, $val, undef, $delay, $timeFrom);
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
  
  # fix if there is in fact no transition, blocks queue for given ramp time with actual hsv values
  if ($rotation == 0 && $sFade == 0 && $vFade == 0)
  {
    Log3 ($hash, 4, "$hash->{NAME} hsv transition with unchanged settings, hsv $hue, $sat, $val, ramp $ramp"); 
    
    $hash->{helper}->{targetTime} = $timeFrom + $ramp;
    return MILIGHT_HighLevelCmdQueue_Add($hash, $hue, $sat, $val, undef, $delay, $timeFrom + $ramp);
  }

  if ($rotation >= ($sFade || $vFade))
  {
    $stepWidth = ($ramp * 1000 / $rotation); # how long is one step (set hsv) in ms based on hue
    $stepWidth = $minDelay if ($stepWidth < $minDelay);
    $steps = int($ramp * 1000 / $stepWidth); # how many steps will we need ?
    Log3 ($hash, 4, "$hash->{NAME} transit (H>S||V) steps: $steps stepWidth: $stepWidth");  
  }
  elsif ($sFade  >= ($rotation || $vFade))
  {
    $stepWidth = ($ramp * 1000 / $sFade); # how long is one step (set hsv) in ms based on sat
    $stepWidth = $minDelay if ($stepWidth < $minDelay);
    $steps = int($ramp * 1000 / $stepWidth); # how many steps will we need ?
    Log3 ($hash, 4, "$hash->{NAME} transit (S>H||V) steps: $steps stepWidth: $stepWidth");  
  }
  else
  {
    $stepWidth = ($ramp * 1000 / $vFade); # how long is one step (set hsv) in ms based on val
    $stepWidth = $minDelay if ($stepWidth < $minDelay);
    $steps = int($ramp * 1000 / $stepWidth); # how many steps will we need ?
    Log3 ($hash, 4, "$hash->{NAME} transit (V>H||S) steps: $steps stepWidth: $stepWidth");  
  }
        
  $hueToSet = $hueFrom; # prepare tmp working hue
  $hueStep = $rotation / $steps * $direction; # how big is one hue step base on timing choosen
          
  $satToSet = $satFrom; # prepare workin sat
  $satStep = ($sat - $satFrom) / $steps;
          
  $valToSet = $valFrom;
  $valStep = ($val - $valFrom) / $steps;

  for (my $i=1; $i <= $steps; $i++)
  {
    $hueToSet += $hueStep;
    $hueToSet -= 360 if ($hueToSet > 360); #handle turn over zero
    $hueToSet += 360 if ($hueToSet < 0);
    $satToSet += $satStep;
    $valToSet += $valStep;
    Log3 ($hash, 4, "$hash->{NAME} add to hl queue h:".($hueToSet).", s:".($satToSet).", v:".($valToSet)." ($i/$steps)");  
    MILIGHT_HighLevelCmdQueue_Add($hash, int($hueToSet +0.5), int($satToSet +0.5), int($valToSet +0.5), undef, $stepWidth, $timeFrom + (($i-1) * $stepWidth / 1000) );
  }
  $hash->{helper}->{targetTime} = $timeFrom + $ramp;
  return undef;
}

sub
MILIGHT_SetHSV_Target(@)
{
  my ($hash, $hue, $sat, $val) = @_;
  $hash->{helper}->{targetHue} = $hue;
  $hash->{helper}->{targetSat} = $sat;
  $hash->{helper}->{targetVal} = $val;
  return undef;
}

sub
MILIGHT_setHSV_Readings(@)
{
  my ($hash, $hue, $sat, $val, $val_on) = @_;
  
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "brightness", $val);
  readingsBulkUpdate($hash, "brightness_on", $val_on);
  if (($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW'))
  {
    # Calc RGB values from HSV
    my ($r,$g,$b) = Color::hsv2rgb($hue/360.0,$sat/100.0,$val/100.0);
    $r *=255; $g *=255; $b*=255;
    # Store values
    readingsBulkUpdate($hash, "hue", $hue);
    readingsBulkUpdate($hash, "saturation", $sat);
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
MILIGHT_setDisco_Readings(@)
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
MILIGHT_Milight_ColorConverter(@)
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
  my $devYellow = 128; # (0x80)
  #my $devYellow = 144;
  my $devGreen = 96; # (0x60)
  my $devCyan = 48; # (0x30)
  #my $devCyan = 56;
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
MILIGHT_HighLevelCmdQueue_Add(@)
{
  my ($hash, $hue, $sat, $val, $ctrl, $delay, $targetTime) = @_;
  my $cmd;

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
  return MILIGHT_HighLevelCmdQueue_Exec($hash);
}

sub
MILIGHT_HighLevelCmdQueue_Exec(@)
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
    my $receiver = sockaddr_in($hash->{PORT}, inet_aton($hash->{IP}));
    MILIGHT_LowLevelCmdQueue_Add($hash, $actualCmd->{ctrl}, $receiver, 100);
  }
  else
  {
    if (($hash->{helper}->{llLock} == 0) || (@{$hash->{helper}->{hlCmdQueue}} == 1))
    {
      Log3 ($hash, 4, "$hash->{NAME} high level cmd queue exec hsv $actualCmd->{hue}, $actualCmd->{sat}, $actualCmd->{val}, delay $actualCmd->{delay}, hl qlen ".@{$hash->{helper}->{hlCmdQueue}}.", ll qlen ".@{$hash->{helper}->{llCmdQueue}}.", lock ".$hash->{helper}->{llLock});
      MILIGHT_setHSV($hash, $actualCmd->{hue}, $actualCmd->{sat}, $actualCmd->{val});
    }
    else
    {
      Log3 ($hash, 5, "$hash->{NAME} high level cmd queue exec drop frame at llQueue level. ll qlen: ".@{$hash->{helper}->{llCmdQueue}}.", lock ".$hash->{helper}->{llLock});
    }
  }
  $actualCmd->{inProgess} = 1;
  my $next = defined($nextCmd->{targetTime})?$nextCmd->{targetTime}:gettimeofday() + ($actualCmd->{delay} / 1000);
  Log3 ($hash, 4, "$hash->{NAME} high level cmd queue ask next $next");
  InternalTimer($next, "MILIGHT_HighLevelCmdQueue_Exec", $hash, 0);
  return undef;
}

sub
MILIGHT_HighLevelCmdQueue_Clear(@)
{
  my ($hash) = @_;
  foreach my $a (keys %intAt) 
  {
    if (($intAt{$a}{ARG} eq $hash) && ($intAt{$a}{FN} eq 'MILIGHT_HighLevelCmdQueue_Exec'))
    {
      Log3 ($hash, 4, "$hash->{NAME} high level cmd queue clear, remove timer at ".$intAt{$a}{TRIGGERTIME} );
      delete($intAt{$a}) ;
    }
  }
  $hash->{helper}->{hlCmdQueue} = [];
}

###############################################################################
#
# atomic low level udp communication to device
# required because there are timing requirements, mostly limitaions in processing speed of the bridge
# the commands should never be interrupted or canceled because some fhem readings are set in advance
#
###############################################################################

sub
MILIGHT_LowLevelCmdQueue_Add(@)
{
  my ($hash, $command, $receiver, $delay, $unlock) = @_;
  my $cmd;

  $cmd->{command} = $command;
  $cmd->{sender} = $hash;
  $cmd->{receiver} = $receiver;
  $cmd->{delay} = $delay;
  $cmd->{unlock} = $unlock;
  $cmd->{inProgess} = 0;

  # push cmd into queue
  push @{$hash->{helper}->{llCmdQueue}}, $cmd;

  my $dbgStr = unpack("H*", $cmd->{command});
  Log3 ($hash, 5, "$hash->{NAME} low level cmd queue add $dbgStr, qlen ".@{$hash->{helper}->{llCmdQueue}}); 

  my $actualCmd = @{$hash->{helper}->{llCmdQueue}}[0];
 
  # sender busy ?
  return undef if ($actualCmd->{inProgess});
  return MILIGHT_LowLevelCmdQueue_Send($hash);
}

sub
MILIGHT_LowLevelCmdQueue_Send(@)
{
  my ($hash) = @_; 
  my $actualCmd = @{$hash->{helper}->{llCmdQueue}}[0];

  # transmission complete, remove
  shift @{$hash->{helper}->{llCmdQueue}} if ($actualCmd->{inProgess});

  # next in queue
  $actualCmd = @{$hash->{helper}->{llCmdQueue}}[0];
  
  # remove a low level queue lock if present and get next 
  while (($actualCmd->{unlock} || 0) == 1) 
  { 
    $actualCmd->{sender}->{helper}->{llLock} -= 1;
    Log3 ($hash, 5, "$hash->{NAME} | $actualCmd->{sender}->{NAME} unlock queue ".$actualCmd->{sender}->{helper}->{llLock});
    shift @{$hash->{helper}->{llCmdQueue}}; 
    $actualCmd = @{$hash->{helper}->{llCmdQueue}}[0];
  }

  # return if no more elements in queue
  return undef if (!defined($actualCmd->{command}));

  my $dbgStr = unpack("H*", $actualCmd->{command});
  Log3 ($hash, 5, "$hash->{NAME} low level cmd queue qlen ".@{$hash->{helper}->{llCmdQueue}}.", send $dbgStr");

  send($hash->{helper}->{SOCKET}, $actualCmd->{command}, 0, $actualCmd->{receiver}) or Log3 ($hash, 1, "$hash->{NAME} low level cmd queue send ERROR $@ $dbgStr, qlen ".@{$hash->{helper}->{llCmdQueue}});

  $actualCmd->{inProgess} = 1;
  my $msec = $actualCmd->{delay} / 1000;
  InternalTimer(gettimeofday()+$msec, "MILIGHT_LowLevelCmdQueue_Send", $hash, 0);
  return undef;
}

1;
