#!/usr/bin/env perl

use 5.28.0;

use utf8;
use strict;
use warnings;

use feature 'signatures';
no warnings qw(experimental::signatures experimental::smartmatch);

use CGI qw(header param -utf8);
use CGI::Carp qw(fatalsToBrowser warningsToBrowser);
use File::Slurper qw(read_lines write_text);
use IO::File;
use Tie::File;

my $radiourl     = 'http://distfiles.lifeisabug.com/xonotic/radio';
my $radiopath    = '/srv/www/distfiles.lifeisabug.com/htdocs/xonotic/radio';
my $queuefile    = $radiopath . '/queue.txt';    # new incoming tracks
my $playlistfile = $radiopath . '/playlist.txt'; # all tracks
my $secret       = ''; # secret matches? advance track...

unless (param('secret') eq $secret)
{
   print_header(404);
   exit;
}

tie my @queue, 'Tie::File', $queuefile, recsep => "\n", discipline => ':encoding(UTF-8)'
   or die($!);

if (scalar @queue > 0)
{
   my $out = IO::File->new($playlistfile, '>>:encoding(UTF-8)');
   my $current = shift @queue;
   $out->print($current . "\n");
   undef $out;

   print_header();
   print $radiourl . '/' . $current;
}
else
{
   my @playlist = read_lines($playlistfile);
   my $random   = $playlist[int rand @playlist];

   if ($random)
   {
      my %uniq;
      @playlist = grep { !$uniq{$_}++ } @playlist;
      write_text($playlistfile, (join "\n", @playlist) . "\n");

      print_header();
      print $radiourl . '/' . $random;
   }
   else
   {
      print_header(404);
      exit;
   }
}

sub print_header ($status = 200)
{
	print header(
		-charset => 'utf-8',
		-type    => 'text/plain',
		-status  => $status,
	);
}
