##############################################
#
# A module to control Epson projectors via ESC/VP21
# 
# written 2013 by Henryk Ploetz <henryk at ploetzli.ch>
#
# The information is based on epson322270eu.pdf and later epson373739eu.pdf
# Some details from pl600pcm.pdf were used, but this enhanced support is not
# complete.
#
##############################################
# Definition: define <name> ESCVP21 <port> [<model>]
# Parameters:
#    port - Specify the serial port your projector is connected to, e.g. /dev/ttyUSB0
#           (For consistent naming, look into /dev/serial/by-id/ )
#           Optionally can specify the baud rate, e.g. /dev/ttyUSB0@9600
#   model - Specify the model of your projector, e.g. tw3000 (case insensitive)


package main;

use strict;
use warnings;
use POSIX;
use DevIo;

my @ESCVP21_SOURCES = (
  ['10', "cycle1"],
  ['11', "analog-rgb1"],
  ['12', "digital-rgb1"],
  ['13', "rgb-video1"],
  ['14', "ycbcr1"],
  ['15', "ypbpr1"],
  ['1f', "auto1"],
  ['20', "cycle2"],
  ['21', "analog-rgb2"],
  ['22', "rgb-video2"],
  ['23', "ycbcr2"],
  ['24', "ypbpr2"],
  ['25', "ypbpr2"],
  ['2f', "auto2"],
  ['30', "cycle3"],
  ['31', "digital-rgb3"],
  ['c0', "cycle5"],
  ['c3', "scart5"],
  ['c4', "ycbcr5"],
  ['c5', "ypbpr5"],
  ['cf', "auto5"],
  ['40', "cycle4"],
  ['41', "video-rca4"],
  ['42', "video-s4"],
  ['43', "video-ycbcr4"],
  ['44', "video-ypbpr4"],
  ['a0', "hdmi2"],
);

my @ESCVP21_SOURCES_OVERRIDE = (
  # From documentation
  ['tw[12]0', [
      ['14', "component1"],
      ['15', "component1"],
    ]
  ],
  ['tw500', [
      ['23', "rgb-video2"],
      ['24', "ycbcr2"],
    ]
  ],
  # From experience
  ['tw3000', [
      ['30', "hdmi1"],
    ]
  ],
);

my @ESCVP21_SOURCES_AVAILABLE = (
  ['tw100h?', ['10', '11', '20', '21', '23', '24', '31', '40', '41', '42', '43', '44']],
  ['ts10', ['10', '11', '12', '13', '20', '21', '22', '23', '24', '40', '41', '42']],
  ['tw10h?', ['10', '13', '14', '15', '20', '21', '40', '41', '42']],
  ['tw200h?', ['10', '13', '14', '15', '20', '21', 'c0', 'c4', 'c5', '40', '41', '42']],
  ['tw500', ['10', '11', '13', '14', '15', '1f', '20', '21', '23', '24', '25', '2f', '30', 'c0', 'c4', 'c5', 'cf', '40', '41', '42']],
  ['tw20', ['10', '13', '14', '15', '20', '21', '40', '41', '42']],
  ['tw(600|520|550|800|700|1000)', ['10', '14', '15', '1f', '20', '21', '30', 'c0', 'c3', 'c4', 'c5', 'cf', '40', '41', '42']],
  ['tw2000', ['10', '14', '15', '1f', '20', '21', '30', 'a0', '40', '41', '42']],
  ['tw[345]000', ['10', '14', '15', '1f', '20', '21', '30', 'a0', '40', '41', '42']],
  ['tw420', ['10', '11', '14', '1f', '30', '41', '42']],
);

sub ESCVP21_Initialize($$)
{
  my ($hash) = @_;
  $hash->{DefFn}    = "ESCVP21_Define";
  $hash->{SetFn}    = "ESCVP21_Set";
  $hash->{ReadFn}   = "ESCVP21_Read";  
  $hash->{ReadyFn}  = "ESCVP21_Ready";
  $hash->{UndefFn}  = "ESCVP21_Undefine";
  $hash->{AttrList} = "TIMER";  # FIXME, are these needed or are they implicit? "event-on-update-reading event-on-change-reading stateFormat webCmd"
  $hash->{fhem}{interfaces} = "switch_passive;switch_active";
  
}

sub ESCVP21_Define($$)
{
  my ($hash, $def) = @_;
  DevIo_CloseDev($hash);
  my @args = split("[ \t]+", $def);
  if (int(@args) < 2) {
    return "Invalid number of arguments: define <name> ESCVP21 <port> [<model>]";
  }

  my ($name, $type, $port, $model) = @args;
  $model = "unknown" unless defined $model;
  $attr{$hash->{NAME}}{TIMER}=30;
  $hash->{Model} = lc($model);
  $hash->{DeviceName} = $port;
  $hash->{CommandQueue} = '';
  $hash->{ActiveCommand} = '';
  $hash->{STATE} = 'Initialized';

  my %table = ESCVP21_SourceTable($hash);
  $hash->{SourceTable} = \%table;
  $attr{$hash->{NAME}}{webCmd} = "on:off:mute";

  my $dev;
  my $baudrate;
  ($dev, $baudrate) = split("@", $port);
  $readyfnlist{"$name.$dev"} = $hash;
  return undef;
}

sub ESCVP21_Ready($)
{
  my ($hash) = @_;
  return DevIo_OpenDev($hash, 0, "ESCVP21_Init");
}

sub ESCVP21_Undefine($$) 
{
  my ($hash,$arg) = @_;
  DevIo_CloseDev($hash); 
  return undef;
}

sub ESCVP21_Init($) 
{
  my ($hash) = @_;
  my $time = gettimeofday();
  $hash->{CommandQueue} = '';
  $hash->{ActiveCommand} = "init";
  ESCVP21_Command($hash,"");
  ESCVP21_ArmWatchdog($hash);

  return undef;
}

sub ESCVP21_ArmWatchdog($)
{
  my ($hash) = @_;
  my $time = gettimeofday();
  my $name = $hash->{NAME};

  Log 5, "ESCVP21_ArmWatchdog: Watchdog disarmed";
  RemoveInternalTimer("watchdog:".$name);

  if($hash->{ActiveCommand}) {
    my $timeout;
    if($hash->{ActiveCommand} =~ /^power(On|Off)$/) {
      # Power commands take a while
      $timeout = 60;
    } elsif($hash->{ActiveCommand} =~ /^SOURCE/) {
      # Source changes may incorporate autoadjust and also take some time
      $timeout = 5;
    } else {
      # All others should be faster
      $timeout = 3;
    }

    Log 5, "ESCVP21_ArmWatchdog: Watchdog armed for $timeout seconds";
    InternalTimer($time + $timeout, "ESCVP21_Watchdog", "watchdog:".$name, 1);
  }
}

sub ESCVP21_Watchdog($)
{
  my($in) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  
  Log 3, "ESCVP21_Watchdog: called for command '$hash->{ActiveCommand}', resetting communication";
  
  ESCVP21_Queue($hash, $hash->{ActiveCommand}, 1) unless $hash->{ActiveCommand} =~ /^init/;
  
  my $command_queue_saved = $hash->{CommandQueue};
  ESCVP21_Init($hash);
  $hash->{CommandQueue} = $command_queue_saved;
}

sub ESCVP21_Read($)
{
  my ($hash) = @_;
  my $buffer = '';
  my $line = undef;
  if(defined($hash->{PARTIAL}) && $hash->{PARTIAL}) {
    $buffer = $hash->{PARTIAL} . DevIo_SimpleRead($hash);
  } else {
    $buffer = DevIo_SimpleRead($hash);
  }

  ($line, $buffer) = ESCVP21_Parse($buffer);
  while($line) {
    Log 4, "ESCVP21_Read (" . $hash->{ActiveCommand} . ") '$line'";

    # When we get a state response, update the corresponding reading
    if($line =~ /([^=]+)=([^=]+)/) {
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, $1, $2);
      ESCVP21_UpdateState($hash);
      readingsEndUpdate($hash, 1);
    }

    my $last_command = $hash->{ActiveCommand};

    if($hash->{ActiveCommand} eq "init") {
      # Wait for the first colon response
      if($line eq ":") {
	$hash->{ActiveCommand} = "initPwr";
	ESCVP21_Command($hash,"PWR?");
      }
    } elsif ($hash->{ActiveCommand} eq "initPwr") {
      # Wait for the first PWR state response
      if($line =~ /^PWR=.*/) {
	$hash->{ActiveCommand} = "";
	
	# Done initialising, begin polling for status
	ESCVP21_GetStatus($hash);
      }
    } elsif($line eq ":") {
      # When we get a colon prompt, the current command finished
      $hash->{ActiveCommand} = "";
    }

    if($line eq "ERR" and not $last_command eq "getERR") {
      # Insert an error query into the queue
      ESCVP21_Queue($hash,"getERR",1);
    }

    if($line eq ":") {
      ESCVP21_IssueQueuedCommand($hash);
    }

    ESCVP21_ArmWatchdog($hash);
  
    ($line, $buffer) = ESCVP21_Parse($buffer);
  }

  $hash->{PARTIAL} = $buffer;
  Log 5, "ESCVP21_Read-Tail '$buffer'";
}

sub ESCVP21_Parse($@)
{
  my $msg = undef;
  my ($tail) = @_;
  
  if($tail =~ /^(.*?)(:|\x0d)(.*)$/s) {
    if($2 eq ":") {
      $msg = $1 . $2;
    } else {
      $msg = $1;
    }
    $tail = $3;
  }

  return ($msg, $tail);
}


sub ESCVP21_GetStatus($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  RemoveInternalTimer("getStatus:".$name);
  
  # Only queue commands when the queue is empty, otherwise, try again in a few seconds
  if(!$hash->{CommandQueue}) {
    InternalTimer(gettimeofday()+$attr{$hash->{NAME}}{TIMER}, "ESCVP21_GetStatus_t", "getStatus:".$name, 1);

    ESCVP21_QueueGet($hash,"VOL");
    ESCVP21_QueueGet($hash,"SOURCE");
    ESCVP21_QueueGet($hash,"PWR");
    ESCVP21_QueueGet($hash,"MSEL");
    ESCVP21_QueueGet($hash,"MUTE");
    ESCVP21_QueueGet($hash,"LAMP");
    ESCVP21_QueueGet($hash,"ERR");
  } else {
    InternalTimer(gettimeofday()+5, "ESCVP21_GetStatus_t", "getStatus:".$name, 1);
  }
}

sub ESCVP21_GetStatus_t($)
{
  my($in) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  ESCVP21_GetStatus($hash);
}

sub ESCVP21_Set($@)
{
  my ($hash, $name, $cmd, @args) = @_;

  Log 5, "ESCVP21_Set: $cmd";

  if($cmd eq 'mute') {
    ESCVP21_Queue($hash,"muteOn");
    ESCVP21_QueueGet($hash,"MUTE");
  } elsif($cmd eq 'unmute') {
    ESCVP21_Queue($hash,"muteOff");
    ESCVP21_QueueGet($hash,"MUTE");
  } elsif($cmd eq 'on') {
    ESCVP21_Queue($hash,"powerOn");
    ESCVP21_QueueGet($hash,"PWR");
  } elsif($cmd eq 'off') {
    ESCVP21_Queue($hash,"powerOff");
    ESCVP21_QueueGet($hash,"PWR");
  } elsif($cmd eq 'raw') {
    ESCVP21_Queue($hash,join(" ", @args));
  } elsif($cmd eq 'source') {
    ESCVP21_ChangeSource($hash, $args[0]);
  } elsif($cmd =~ /^([^-]+)-(.*)$/) {
    my ($on,$muted) = (0,0);
    ($on, $muted) = (1, 0) if $1 eq 'on';
    ($on, $muted) = (0, 0) if $1 eq 'off';
    ($on, $muted) = (1, 1) if $1 eq 'mute';

    if($on) {
      ESCVP21_Queue($hash,"powerOn");
      ESCVP21_QueueGet($hash,"PWR");

      ESCVP21_ChangeSource($hash, $2);

      if($muted) {
	ESCVP21_Queue($hash,"muteOn");
	ESCVP21_QueueGet($hash,"MUTE");
      } else {
	ESCVP21_Queue($hash,"muteOff");
	ESCVP21_QueueGet($hash,"MUTE");
      }

    } else {
      ESCVP21_Queue($hash,"powerOff");
      ESCVP21_QueueGet($hash,"PWR");
    }

  }
  
}

sub ESCVP21_ChangeSource($$)
{
  my ($hash, $source) = @_;
  my %table = %{$hash->{SourceTable}};
  my $done = 0;
  while( my ($key, $value) = each %table ) {
    if( lc($source) eq lc($value) ) {
      ESCVP21_Queue($hash,"SOURCE " . uc($key));
      ESCVP21_QueueGet($hash,"SOURCE");
      $done = 1;
      last;
    }
  }

  unless($done) {
    if($source =~ /[0-9a-f]{2}/i) {
      ESCVP21_Queue($hash,"SOURCE " . uc($source));
      ESCVP21_QueueGet($hash,"SOURCE");
      $done = 1;
    }
  }

}

sub ESCVP21_QueueGet($$)
{
  my ($hash,$param) = @_;
  ESCVP21_Queue($hash,"get".$param);
}

sub ESCVP21_Queue($@)
{
  my ($hash,$cmd,$prepend) = @_;
  if($hash->{CommandQueue}) {
    if($prepend) {
      $hash->{CommandQueue} = $cmd . "|" . $hash->{CommandQueue};
    } else {
      $hash->{CommandQueue} .=  "|" . $cmd;
    }
  } else {
    $hash->{CommandQueue} = $cmd
  }
  
  ESCVP21_IssueQueuedCommand($hash);
  ESCVP21_ArmWatchdog($hash);
}


sub ESCVP21_IssueQueuedCommand($)
{
  my ($hash) = @_;
  # If a command is still active we can't do anything
  if($hash->{ActiveCommand}) {
    return;
  }
  
  ($hash->{ActiveCommand}, $hash->{CommandQueue}) = split(/\|/, $hash->{CommandQueue}, 2);

  if($hash->{ActiveCommand}) {
    Log 4, "ESCVP21 executing ". $hash->{ActiveCommand};
    
    if($hash->{ActiveCommand} eq 'muteOn') {
      ESCVP21_Command($hash, "MUTE ON");
    } elsif($hash->{ActiveCommand} eq 'muteOff') {
      ESCVP21_Command($hash, "MUTE OFF");
    } elsif($hash->{ActiveCommand} eq 'powerOn') {
      ESCVP21_Command($hash, "PWR ON");
    } elsif($hash->{ActiveCommand} eq 'powerOff') {
      ESCVP21_Command($hash, "PWR OFF");
    } elsif($hash->{ActiveCommand} =~ /^get(.*)$/) {
      ESCVP21_Command($hash, $1."?");
    } else {
      # Assume a raw command and hope the user knows what he or she's doing
      ESCVP21_Command($hash, $hash->{ActiveCommand});
    }
  }

}

sub ESCVP21_UpdateState($)
{
  my ($hash) = @_;
  my $state = undef;
  my $onoff = 0;
  my $source = $hash->{READINGS}{SOURCE}{VAL} . "-unknown";
  my %table = %{$hash->{SourceTable}};

  # If it's on or powering up, consider it on
  if($hash->{READINGS}{PWR}{VAL} eq '01' or $hash->{READINGS}{PWR}{VAL} eq '02') {
    if($hash->{READINGS}{MUTE}{VAL} eq 'ON') {
      $state = "mute";
    } else {
      $state = "on";
    }
    $onoff = 1;
  } else {
    $state = "off";
    $onoff = 0;
  }
  
  while( my ($key, $value) = each %table ) {
    if( lc($hash->{READINGS}{SOURCE}{VAL}) eq lc($key) ) {
      $source = $value;
      last;
    }
  }
  

  readingsBulkUpdate($hash, "state", $state);
  readingsBulkUpdate($hash, "onoff", $onoff);
  readingsBulkUpdate($hash, "source", $source) unless $source eq "-unknown";
}

sub ESCVP21_SourceTable($)
{
  my ($hash) = @_;
  my %table = ();
  my @available;
  my @override;

  foreach (@ESCVP21_SOURCES_AVAILABLE) {
    my ($modelre, $available_list) = @$_;
    if( $hash->{Model} =~ /^$modelre$/i ) {
      Log 4, "ESCVP21: Available sources defined by " . $modelre;
      @available = @$available_list;
      last;
    }
  }

  foreach (@ESCVP21_SOURCES_OVERRIDE) {
    my ($modelre, $override_list) = @$_;
    if( $hash->{Model} =~ /^$modelre$/i ) {
      Log 4, "ESCVP21: Override defined by " . $modelre;
      @override = @$override_list;
      last;
    }
  }
  
  foreach (@ESCVP21_SOURCES) {
    my ($code, $name) = @$_;
    if( (!@available) || ($code ~~ @available)) {
      $table{lc($code)} = lc($name);
      if(@override) {
	foreach (@override) {
	  my ($code_o, $name_o) = @$_;
	  if(lc($code_o) eq lc($code)) {
	    $table{lc($code)} = lc($name_o);
	  }
	}
      }
      Log 4, "ESCVP21: " . $code . " is mapped to " . $table{lc($code)};
    }
  }

  return %table;
}

sub ESCVP21_Command($$) 
{
  my ($hash,$command) = @_;
  DevIo_SimpleWrite($hash,$command."\x0d",'');
}

1;

=pod
=begin html

<a name="ESCVP21"></a>
<h3>ESCVP21</h3>
<ul>

  Many EPSON projectors (both home and business) have a communications interface
  for remote control and status reporting. This can be in the form of a serial
  port (RS-232), a USB port or an Ethernet port. The protocol used on this port
  most often is ESC/VP21. This module supports control of simple functions on the
  projector through ESC/VP21. It has only been tested with EH-TW3000 over RS-232.
  The network protocol is similar and may be supported in the future.

  <a name="ESCVP21define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ESCVP21 &lt;device&gt; [&lt;model&gt;]</code> <br>
    <br>
    USB or serial devices-connected devices:<br><ul>
      &lt;device&gt; specifies the serial port to communicate with the projector.
      The name of the serial-device depends on your distribution and several
      other factors. Under Linux it's usually something like /dev/ttyS0 for a
      physical COM port in the computer, /dev/ttyUSB0 or /dev/ttyACM0 for USB
      connected devices (both USB projector or serial projector using USB-serial
      converter). The numbers may differ, check your kernel log (using the dmesg
      command) soon after connecting the USB cable. Many distributions also offer
      a consistent naming in /dev/serial/by-id/, check there.

      You can also specify a baudrate if the device name contains the @
      character, e.g.: /dev/ttyACM0@9600, though this should usually always
      be 9600.<br><br>

      If the baudrate is "directio" (e.g.: /dev/ttyACM0@directio), then the
      perl module Device::SerialPort is not needed, and fhem opens the device
      with simple file io. This might work if the operating system uses sane
      defaults for the serial parameters, e.g. some Linux distributions and
      OSX.  <br><br>

    </ul>
    Network-connected devices:<br><ul>
    Not supported currently.
    </ul>
    <br>

    If a model name is specified (case insensitive, without the "emp-" prefix),
    it is used to limit the possible input source values to the ones supported
    by the projector (if known) and may be used to map certain source values
    to better symbolic names.

    Examples:
    <ul>
      <code>define Projector_Living_Room ESCVP21 /dev/serial/by-id/usb-Prolific_Technology_Inc._USB-Serial_Controller_D-if00-port0 tw3000</code><br>
    </ul>


  </ul>
  <br>

  <a name="ESCVP21set"></a>
  <b>Set </b>
  <ul>
    <li>on<br>
	Switch the projector on.
	</li><br>
    <li>off<br>
	Switch the projector off.
	</li><br>
    <li>mute<br>
	'Mute' the projector output, e.g. display a black screen.
	</li><br>
    <li>unmute<br>
	'Unmute' the projector output.
        </li><br>
    <li>source &lt;source&gt;.<br>
	Switch the projector input source. The names are the same as
	reported by the 'source' reading, so if in doubt look there.
	A raw two character hex code may also be specified.
	</li><br>
    <li>&lt;state&gt;-&lt;source&gt;<br>
	Switch state ("on", "off" or "mute" and source in one command.
	The source is ignored if the new state is off.
	</li><br>

  </ul>

  <a name="ESCVP21get"></a>
  <b>Get</b>
  <ul>N/A</ul>

  <a name="ESCVP21attr"></a>
  <b>Attributes</b>
  <ul>
    <li>TIMER<br>
	The projector must be queried for readings changes, and this attribute
	specifies the number of seconds between queries.
        </li><br>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
  <br>
</ul>

=end html
=cut
