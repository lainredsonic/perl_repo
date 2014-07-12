#!/usr/bin/perl -w
use strict;
use Audio::Wav;

my @tones;
my %dtmf = (
 '1' => [ 697, 1209 ],
 '2' => [ 697, 1336 ],
 '3' => [ 697, 1477 ],
 'A' => [ 697, 1633 ],
 '4' => [ 770, 1209 ],
 '5' => [ 770, 1336 ],
 '6' => [ 770, 1477 ],
 'B' => [ 770, 1633 ],
 '7' => [ 852, 1209 ],
 '8' => [ 852, 1336 ],
 '9' => [ 852, 1477 ],
 'C' => [ 852, 1633 ],
 '*' => [ 941, 1209 ],
 '0' => [ 941, 1336 ],
 '#' => [ 941, 1477 ],
 'D' => [ 941, 1633 ],
);

if (@ARGV > 0) {
  @tones = split'',$ARGV[0];
} else {
  @tones = sort keys %dtmf;
}

my $play = $ARGV[1] || 0;


my $sample_rate = 8000;
my $bits_sample = 8;
my $num_channels = 1;
my $pi = 4 * atan2 1, 1;
my $duration = 0.5 * $sample_rate;

my $wav = new Audio::Wav;

my $details = {
                'bits_sample'       => $bits_sample,
                'sample_rate'       => $sample_rate,
                'channels'          => $num_channels,
              };

my $write = $wav -> write( 'dtmf.wav', $details );

for my $tone (@tones) {
  my @hz = map { 2 * $pi * $_ } @{$dtmf{$tone}};
  add_tone(@hz);
}

$write -> finish();

Win32::Sound::Play('dtmf.wav') if $play && $main::can_play;

sub add_tone {
  my (@hz) = @_;
  for my $pos ( 0 .. $duration ) {
    my $time = $pos / $sample_rate;
    my $val = 63 * sin($time * $hz[0]) + 63 * sin($time * $hz[1]);
    $write -> write( $val );    
  }
}

BEGIN {
  if ($^O =~ /MSWin32/) {
    require Win32::Sound;
    our $can_play = 1;
  }
}
