#!/usr/bin/env perl

# Erebus - Discord bot for the twilightzone Xonotic server
#          Links a Xonotic server with a discord channel
#          In contrast to rcon2irc.pl this just links chats
#
# Requires https://github.com/vsTerminus/Mojo-Discord (release v3+)
# Based on https://github.com/vsTerminus/Goose
#
# Copyright 2020, Nico R. Wohlgemuth <nico@lifeisabug.com>

# Xonotic server.cfg:
#
# log_dest_udp "<locip:port>"
# sv_eventlog 1
# sv_eventlog_ipv6_delimiter 1
# sv_logscores_bots 1 // if you want
# rcon_secure 1 // or 2
# rcon_password <pass>
# sv_adminnick "^8DISCORD^3" // If the server is not using SMB modpack
#                            // (if you don't know what that is, you aren't)

# TODO:
# - split endmatch scoreboard before $discord_char_limit on newline
# - sort player scoreboard in teams with line sep or 1 msg per team
# - use Text::ANSITable methods for formatting columns?
# - the rcon_secure 2 challenge stuff can be improved a lot
#   - make use of IO::Async for this and get rid of @cmdqueue
#   - add a $challange_timeout variable
#   - maybe save the challenge and only request a new one if needed
#   - when it is good enough, remove $$config{secure} and always use this method
#     and possibly fall back to method 1 if $challange_timeout is exceeded
#   - for now it is fine as Xonotic defaults to rcon_secure 1 anyways

use v5.28.0;

use utf8;
use strict;
use warnings;

use lib '/etc/perl';

use feature 'signatures';
no warnings qw(experimental::signatures experimental::smartmatch);

binmode( STDOUT, ":encoding(UTF-8)" );

#use Data::Dumper;
use Mojo::Discord;
use IO::Async::Loop::Mojo;
use IO::Async::Socket;
use IO::File;
use Digest::HMAC;
use Digest::MD4;
use MaxMind::DB::Reader;
use Encode::Simple qw(encode_utf8 decode_utf8);
use Unicode::Truncate;
use Text::ANSITable;
use LWP::Simple qw($ua get);
use JSON;

$ua->timeout( 6 );

my $self;

my $config = {
   game   => 'Xonotic',                    # Initial 'Playing' status in discord, get overwritten after a map is loaded anyways
   remip  => '2a02:c207:3003:5281::1',     # IP of the Xonotic server
   port   => 26000,                        # Port of the Xonotic Server, local port = this + 444
   locip  => undef,                        # Local IP, if undef it uses $remip
   secure => 1,                            # rcon_secure value in server.cfg, 0 is insecure, 1 or 2 are recommended (1 is the Xonotic default)
   smbmod => 1,                            # Set to 1 if server uses SMB modpack, otherwise you should set sv_adminnick "^8DISCORD^3" in server.cfg
   pass   => '',                           # rcon_password in server.cfg
   geo    => '/home/k/GeoLite2-City.mmdb', # Path to GeoLite2-City.mmdb from maxmind.com
   logdir => "$ENV{HOME}/.xonotic/erebus/scorelogs", # If not empty (''), this folder will be used to save endmatch scoreboards to (one .txt file per match)
   debug  => 0,                            # Prints incoming log lines to console if 1

   discord => {
     linkchan   => 706113584626663475, # The discord channel ID which will link discord and server chats
     nocmdchans => [458683388887302155, 610862900357234698, 673626913864155187, 698803767512006677], # Channel IDs where !cmds like !status are not allowed
     client_id  => ,                   # Discord bot client ID https://discordapp.com/developers/applications/
     owner_id   => 373912992758235148, # ID of the bots owner, if not 0 this allows the owner to use the !rcon command
     joinmoji   => '<:NyanPasu:562191812702240779>', # Join emoji  if not empty ('') those will be displayed between the country flag
     partmoji   => '<:gtfo:603609334781313037>',     # Part emoji  and the players nickname when joining or leaving the server
   },

   status_re  => qr/^!xstat(us|su)/i,               # regexp for the status command, you probably want  qr/^!status/i  here for !status
   xonstat_re => qr/^!(?:xon(?:stat)?s?|xs) (.+)/i, # regexp for the xonstat command
   rcon_re    => qr/^!rcon (.+)/i,                  # regexp for the rcon command, only owner_id is allowed to use this, works in linkchan only
};
# You can also experiemnt with different table border styles and paddings, Default::csingle with default (1) cell_pad looks nice but uses lots of space and chars
# As soon as it warps it looks off in discord. To get as tight as possible use Default::singlei_utf8, cell_pad 0 and extend the $shortnames hash even more.

my $discord = Mojo::Discord->new(
   'version'   => 9999,
   'url'       => 'https://xonotic.lifeisabug.com',
   'token'     => '',
   'name'      => 'Erebus',
   'reconnect' => 1,
   'verbose'   => 0,
   'logdir'    => "$ENV{HOME}/.xonotic/erebus",
   'logfile'   => 'discord.log',
   'loglevel'  => 'info',
);

my $teams = {
   -1 => {
      color => 'NONE',
   },
   1 => {
      color => 'NONE',
   },
   5 => {
      color => 'RED',
      id    => 1,
   },
   10 => {
      color => 'PINK',
      id => 4,
   },
   13 => {
      color => 'YELLOW',
      id => 3,
   },
   14 => {
      color => 'BLUE',
      id => 2,
   },
   spectator => {
      color => 'SPECTATOR',
   },
};

my $modes = {
   'ARENA'     => 'Duel Arena',
   'AS'        => 'Assault',
   'CA'        => 'Clan Arena',
   'CONQUEST'  => 'Conquest',
   'COOP'      => 'Cooperative',
   'CQ'        => 'Conquest',
   'CTF'       => 'Capture the Flag',
   'CTS'       => 'Race - Complete the Stage',
   'DM'        => 'Deathmatch',
   'DOM'       => 'Domination',
   'DOTC'      => 'Defense of the Core (MOBA)',
   'DUEL'      => 'Duel',
   'FT'        => 'Freeze Tag',
   'INF'       => 'Infection',
   'INV'       => 'Invasion',
   'JAILBREAK' => 'Jailbreak',
   'JB'        => 'Jailbreak',
   'KA'        => 'Keepaway',
   'KH'        => 'Key Hunt',
   'LMS'       => 'Last Man Standing',
   'NB'        => 'Nexball',
   'ONS'       => 'Onslaught',
   'RACE'      => 'Race',
   'RC'        => 'Race',
   'RUNE'      => 'Runematch',
   'RUNEMATCH' => 'Runematch',
   'SNAFU'     => '???',
   'TDM'       => 'Team Deathmatch',
   'VIP'       => 'Very Important Player',
};

my $shortnames = {
   'BCKILLS'   => 'BCK',
   'DMG'       => 'DMG+',
   'DMGTAKEN'  => 'DMG-',
   'FCKILLS'   => 'FCK',
   'PICKUPS'   => 'PCKUPS',
   'REVIVALS'  => 'REVS',
   'SUICIDES'  => 'SK',
   'TEAMKILLS' => 'TK',
};

my $discord_char_limit = 2000;

#my $discord_markdown_pattern = qr/(?<!\\)(`|@|:|#|\||__|\*|~|>)/;
my $discord_markdown_pattern = qr/(?<!\\)(`|@|#|\||__|\*|~|>)/;

my @qfont_unicode_glyphs = (
   "\N{U+0020}",     "\N{U+0020}",     "\N{U+2014}",     "\N{U+0020}",
   "\N{U+005F}",     "\N{U+2747}",     "\N{U+2020}",     "\N{U+00B7}",
   "\N{U+0001F52B}", "\N{U+0020}",     "\N{U+0020}",     "\N{U+25A0}",
   "\N{U+2022}",     "\N{U+2192}",     "\N{U+2748}",     "\N{U+2748}",
   "\N{U+005B}",     "\N{U+005D}",     "\N{U+0001F47D}", "\N{U+0001F603}",
   "\N{U+0001F61E}", "\N{U+0001F635}", "\N{U+0001F615}", "\N{U+0001F60A}",
   "\N{U+00AB}",     "\N{U+00BB}",     "\N{U+2022}",     "\N{U+203E}",
   "\N{U+2748}",     "\N{U+25AC}",     "\N{U+25AC}",     "\N{U+25AC}",
   "\N{U+0020}",     "\N{U+0021}",     "\N{U+0022}",     "\N{U+0023}",
   "\N{U+0024}",     "\N{U+0025}",     "\N{U+0026}",     "\N{U+0027}",
   "\N{U+0028}",     "\N{U+0029}",     "\N{U+00D7}",     "\N{U+002B}",
   "\N{U+002C}",     "\N{U+002D}",     "\N{U+002E}",     "\N{U+002F}",
   "\N{U+0030}",     "\N{U+0031}",     "\N{U+0032}",     "\N{U+0033}",
   "\N{U+0034}",     "\N{U+0035}",     "\N{U+0036}",     "\N{U+0037}",
   "\N{U+0038}",     "\N{U+0039}",     "\N{U+003A}",     "\N{U+003B}",
   "\N{U+003C}",     "\N{U+003D}",     "\N{U+003E}",     "\N{U+003F}",
   "\N{U+0040}",     "\N{U+0041}",     "\N{U+0042}",     "\N{U+0043}",
   "\N{U+0044}",     "\N{U+0045}",     "\N{U+0046}",     "\N{U+0047}",
   "\N{U+0048}",     "\N{U+0049}",     "\N{U+004A}",     "\N{U+004B}",
   "\N{U+004C}",     "\N{U+004D}",     "\N{U+004E}",     "\N{U+004F}",
   "\N{U+0050}",     "\N{U+0051}",     "\N{U+0052}",     "\N{U+0053}",
   "\N{U+0054}",     "\N{U+0055}",     "\N{U+0056}",     "\N{U+0057}",
   "\N{U+0058}",     "\N{U+0059}",     "\N{U+005A}",     "\N{U+005B}",
   "\N{U+005C}",     "\N{U+005D}",     "\N{U+005E}",     "\N{U+005F}",
   "\N{U+0027}",     "\N{U+0061}",     "\N{U+0062}",     "\N{U+0063}",
   "\N{U+0064}",     "\N{U+0065}",     "\N{U+0066}",     "\N{U+0067}",
   "\N{U+0068}",     "\N{U+0069}",     "\N{U+006A}",     "\N{U+006B}",
   "\N{U+006C}",     "\N{U+006D}",     "\N{U+006E}",     "\N{U+006F}",
   "\N{U+0070}",     "\N{U+0071}",     "\N{U+0072}",     "\N{U+0073}",
   "\N{U+0074}",     "\N{U+0075}",     "\N{U+0076}",     "\N{U+0077}",
   "\N{U+0078}",     "\N{U+0079}",     "\N{U+007A}",     "\N{U+007B}",
   "\N{U+007C}",     "\N{U+007D}",     "\N{U+007E}",     "\N{U+2190}",
   "\N{U+003C}",     "\N{U+003D}",     "\N{U+003E}",     "\N{U+0001F680}",
   "\N{U+00A1}",     "\N{U+004F}",     "\N{U+0055}",     "\N{U+0049}",
   "\N{U+0043}",     "\N{U+00A9}",     "\N{U+00AE}",     "\N{U+25A0}",
   "\N{U+00BF}",     "\N{U+25B6}",     "\N{U+2748}",     "\N{U+2748}",
   "\N{U+2772}",     "\N{U+2773}",     "\N{U+0001F47D}", "\N{U+0001F603}",
   "\N{U+0001F61E}", "\N{U+0001F635}", "\N{U+0001F615}", "\N{U+0001F60A}",
   "\N{U+00AB}",     "\N{U+00BB}",     "\N{U+2747}",     "\N{U+0078}",
   "\N{U+2748}",     "\N{U+2014}",     "\N{U+2014}",     "\N{U+2014}",
   "\N{U+0020}",     "\N{U+0021}",     "\N{U+0022}",     "\N{U+0023}",
   "\N{U+0024}",     "\N{U+0025}",     "\N{U+0026}",     "\N{U+0027}",
   "\N{U+0028}",     "\N{U+0029}",     "\N{U+002A}",     "\N{U+002B}",
   "\N{U+002C}",     "\N{U+002D}",     "\N{U+002E}",     "\N{U+002F}",
   "\N{U+0030}",     "\N{U+0031}",     "\N{U+0032}",     "\N{U+0033}",
   "\N{U+0034}",     "\N{U+0035}",     "\N{U+0036}",     "\N{U+0037}",
   "\N{U+0038}",     "\N{U+0039}",     "\N{U+003A}",     "\N{U+003B}",
   "\N{U+003C}",     "\N{U+003D}",     "\N{U+003E}",     "\N{U+003F}",
   "\N{U+0040}",     "\N{U+0041}",     "\N{U+0042}",     "\N{U+0043}",
   "\N{U+0044}",     "\N{U+0045}",     "\N{U+0046}",     "\N{U+0047}",
   "\N{U+0048}",     "\N{U+0049}",     "\N{U+004A}",     "\N{U+004B}",
   "\N{U+004C}",     "\N{U+004D}",     "\N{U+004E}",     "\N{U+004F}",
   "\N{U+0050}",     "\N{U+0051}",     "\N{U+0052}",     "\N{U+0053}",
   "\N{U+0054}",     "\N{U+0055}",     "\N{U+0056}",     "\N{U+0057}",
   "\N{U+0058}",     "\N{U+0059}",     "\N{U+005A}",     "\N{U+005B}",
   "\N{U+005C}",     "\N{U+005D}",     "\N{U+005E}",     "\N{U+005F}",
   "\N{U+0027}",     "\N{U+0041}",     "\N{U+0042}",     "\N{U+0043}",
   "\N{U+0044}",     "\N{U+0045}",     "\N{U+0046}",     "\N{U+0047}",
   "\N{U+0048}",     "\N{U+0049}",     "\N{U+004A}",     "\N{U+004B}",
   "\N{U+004C}",     "\N{U+004D}",     "\N{U+004E}",     "\N{U+004F}",
   "\N{U+0050}",     "\N{U+0051}",     "\N{U+0052}",     "\N{U+0053}",
   "\N{U+0054}",     "\N{U+0055}",     "\N{U+0056}",     "\N{U+0057}",
   "\N{U+0058}",     "\N{U+0059}",     "\N{U+005A}",     "\N{U+007B}",
   "\N{U+007C}",     "\N{U+007D}",     "\N{U+007E}",     "\N{U+25C0}"
);

my @qfont_ascii_table = (
 '\0', '#',  '#',  '#',  '#',  '.',  '#',  '#',
 '#',  '\t', '\n', '#',  ' ',  '\r', '.',  '.',
 '[',  ']',  '0',  '1',  '2',  '3',  '4',  '5',
 '6',  '7',  '8',  '9',  '.',  '<',  '=',  '>',
 ' ',  '!',  '"',  '#',  '$',  '%',  '&',  '\'',
 '(',  ')',  '*',  '+',  ',',  '-',  '.',  '/',
 '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',
 '8',  '9',  ':',  ';',  '<',  '=',  '>',  '?',
 '@',  'A',  'B',  'C',  'D',  'E',  'F',  'G',
 'H',  'I',  'J',  'K',  'L',  'M',  'N',  'O',
 'P',  'Q',  'R',  'S',  'T',  'U',  'V',  'W',
 'X',  'Y',  'Z',  '[',  '\\', ']',  '^',  '_',
 '`',  'a',  'b',  'c',  'd',  'e',  'f',  'g',
 'h',  'i',  'j',  'k',  'l',  'm',  'n',  'o',
 'p',  'q',  'r',  's',  't',  'u',  'v',  'w',
 'x',  'y',  'z',  '{',  '|',  '}',  '~',  '<',

 '<',  '=',  '>',  '#',  '#',  '.',  '#',  '#',
 '#',  '#',  ' ',  '#',  ' ',  '>',  '.',  '.',
 '[',  ']',  '0',  '1',  '2',  '3',  '4',  '5',
 '6',  '7',  '8',  '9',  '.',  '<',  '=',  '>',
 ' ',  '!',  '"',  '#',  '$',  '%',  '&',  '\'',
 '(',  ')',  '*',  '+',  ',',  '-',  '.',  '/',
 '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',
 '8',  '9',  ':',  ';',  '<',  '=',  '>',  '?',
 '@',  'A',  'B',  'C',  'D',  'E',  'F',  'G',
 'H',  'I',  'J',  'K',  'L',  'M',  'N',  'O',
 'P',  'Q',  'R',  'S',  'T',  'U',  'V',  'W',
 'X',  'Y',  'Z',  '[',  '\\', ']',  '^',  '_',
 '`',  'a',  'b',  'c',  'd',  'e',  'f',  'g',
 'h',  'i',  'j',  'k',  'l',  'm',  'n',  'o',
 'p',  'q',  'r',  's',  't',  'u',  'v',  'w',
 'x',  'y',  'z',  '{',  '|',  '}',  '~',  '<'
);

my $qheader = "\377\377\377\377";

###

my $gi = MaxMind::DB::Reader->new(file => $$config{'geo'});

discord_on_ready();
discord_on_message_create();

$discord->init();

my ($recvbuf, @cmdqueue);

my ($matchid, $map, $bots, $players, $type, $instagib, $maptime, $teamplay, @lastplayers)
=  ('none',   '',   0,     {},       '',    0,         0,        0,         (),         );
my (@pscorelabels, $pscorekey, $pscoreorder, $pscores, @tscorelabels, $tscorekey, $tscoreorder, $tscores)
=  ((),            'SCORE',    0,            {},        (),            'SCORE',    0,            {},    );

my $xonstream = IO::Async::Socket->new(
   recv_len => 1400,

   on_recv => sub ($self, $dgram, $addr)
   {
      chall_recvd($1) if ($dgram =~ /^${qheader}challenge (.*?)(\0|$)/);

      ($recvbuf .= $dgram) =~ s/${qheader}n?//g;

      while( $recvbuf =~ s/^(.*?)\n// )
      {
         my $line = decode_utf8(stripcolors($1));

         next unless (substr($line, 0, 1, '') eq ':');

         my $fields = {
            chat      => 3,
            chat_spec => 3,
            chat_team => 4,
            join      => 5,
            name      => 3,
            player    => 7,
         };

         my @info = (split /:/, $line, $$fields{($line =~ /^([^:]*)/)[0]} || -1);

         next if ($info[0] eq 'anticheat');
         say localtime(time) . " -- Key: $info[0] | Fields: @info[1..$#info]" if $$config{debug};

         my ($msg, $delaydelete);

         given ( $info[0] )
         {
            when ( 'join' )
            {
                $$players{$info[1]}{slot} = $info[2];
               ($$players{$info[1]}{ip}   = $info[3]) =~ s/_/:/g;
                $$players{$info[1]}{name} = qfont_decode($info[4]);

               unless ($info[3] eq 'bot')
               {
                  my $r = $gi->record_for_address($$players{$info[1]}{ip});
                  $$players{$info[1]}{geo} = $r->{country}{iso_code} ? lc($r->{country}{iso_code}) : 'white';

                  $msg = 'has joined the game' unless ($info[1] ~~ @lastplayers);
               }
               else
               {
                  $bots++;
               }
            }
            when ( 'part' )
            {
               $delaydelete = $info[1];

               if (defined $$players{$info[1]})
               {
                  unless ($$players{$info[1]}{ip} eq 'bot')
                  {
                     $msg = 'has left the game';
                  }
                  else
                  {
                     $bots--;
                  }
               }
            }
            when ( 'chat' )
            {
               $msg = $info[2];
            }
            when ( 'chat_spec' )
            {
               $msg = '(SPECTATOR) ' . $info[2];
            }
            when ( 'chat_team' )
            {
               #next;
               $msg = "($$teams{$info[2]}{color}) $info[3]";
            }
            when ( 'name' )
            {
               $$players{$info[1]}{name} = $info[2];
            }
            when ( 'team' )
            {
               $$players{$info[1]}{team} = $info[2];
            }
            when ( 'gamestart' )
            {
               ($bots, $players, $teamplay)
             = (0,     {},       0        );
               (@pscorelabels, $pscorekey, $pscoreorder, $pscores, @tscorelabels, $tscorekey, $tscoreorder, $tscores)
             = ((),            'SCORE',    0,            {},       (),            'SCORE',    0,            {}      );

               $matchid = $info[2];

               if ($info[1] =~ /^([a-z]+)_(.+)$/)
               {
                  ($type, $map) = (uc($1), $2);
                  $discord->status_update( { 'name' => ($instagib ? 'i' : '') . "$type on $map", type => 0 } );
               }
            }
            when ( 'gameinfo' )
            {
               if ($info[1] eq 'mutators' && $info[2] eq 'LIST')
               {
                  $instagib = 'instagib' ~~ @info[3..$#info] ? 1 : 0;
               }
            }
            when ( 'startdelay_ended' )
            {
               @lastplayers = ();

               if (keys %$players > 0 && $type && $map)
               {
                  my $embed = {
                     'color' => '3447003',
                     'provider' => {
                        'name' => 'twlz',
                        'url' => 'https://xonotic.lifeisabug.com',
                      },
                      'fields' => [
                      {
                         'name'   => 'Type',
                         'value'  => $type . ($instagib ? ' (InstaGib)' : ''),
                         'inline' => \1,
                      },
                      {
                         'name'   => 'Map',
                         'value'  => $map,
                         'inline' => \1,
                      },
                      {
                         'name'   => 'Players',
                         'value'  => (keys %$players) - $bots,
                         'inline' => \1,
                      },
                      ],
                  };

                  #push $$embed{'fields'}->@*, { 'name' => 'Bots', 'value' => $bots, 'inline' => \1, } if ($bots);

                  my $message = {
                     'content' => '',
                     'embed' => $embed,
                  };

                  $discord->send_message( $$config{discord}{linkchan}, $message );
               }
            }
            when ( 'recordset' )
            {
               if ($type && $type eq 'CTS') 
               {
                  $msg = ':checkered_flag: set a record: ' . sprintf(' %.4f seconds!', $info[2]);
               }
               else
               {
                  $$players{$info[1]}{recordset} = $info[2];
               }
            }
            when ( 'ctf' )
            {
               if ($info[1] eq 'capture')
               {
                  $info[1] = $info[4];
                  $$players{$info[4]}{team} = $info[3];

                  $msg = ":flags: captured the $$teams{$info[2]}{color} flag for team $$teams{$info[3]}{color}" . ($$players{$info[4]}{recordset} ? sprintf(' in a record %.4f seconds!', $$players{$info[4]}{recordset}) : '');

                  delete $$players{$info[4]}{recordset};
               }
            }
            when ( 'vote' )
            {
               given ( $info[1] )
               {
                  when ( 'vcall' )
                  {
                     $info[1] = $info[2];

                     $msg = ':ballot_box: called a vote: ' . $info[3];
                  }
                  when ( 'vyes' )
                  {
                     $discord->send_message( $$config{discord}{linkchan}, ':white_check_mark: `the vote was accepted`' );
                  }
                  when ( 'vno' )
                  {
                     $discord->send_message( $$config{discord}{linkchan}, ':x: `the vote was denied`' );
                  }
               }
            }
            when ( 'scores' )
            {
               $maptime = $info[2];

               if ($info[1] =~ /^([a-z]+)_(.+)$/)
               {
                  ($type, $map) = (uc($1), $2);
                  $discord->status_update( { 'name' => ($instagib ? 'i' : '') . "$type on $map", type => 0 } );
               }
            }
            when ( 'labels' )
            {
               if ($info[1] eq 'player')
               {
                  @pscorelabels = map { uc } split(/,/, $info[2]);

                  for (0..$#pscorelabels)
                  {
                     if ($pscorelabels[$_] =~ /^([A-Z]+)([!<]+)?$/)
                     {
                        my $label = defined $$shortnames{$1} ? $$shortnames{$1} : $1;
                        my $flags = $2;

                        $pscorelabels[$_] = $label;

                        if ($flags && $flags =~ /!!/)
                        {
                           $pscorekey   = defined $$shortnames{$label} ? $$shortnames{$label} : $label;
                           $pscoreorder = 1 if ($flags =~ /</);
                        }
                     }
                  }
               }
               elsif ($info[1] eq 'teamscores')
               {
                  $teamplay = 1;

                  @tscorelabels = map { uc } split(/,/, $info[2], 2);

                  for (0..$#tscorelabels)
                  {
                     if ($tscorelabels[$_] =~ /^([A-Z]+)([!<]+)?$/)
                     {
                        my $label = $1;
                        my $flags = $2;

                        $tscorelabels[$_] = $label;

                        if ($flags && $flags =~ /!!/)
                        {
                           $tscorekey   = $label;
                           $tscoreorder = 1 if ($flags =~ /</);
                        }
                     }
                  }
               }
            }
            when ( 'player' )
            {
               if ($info[1] eq 'see-labels')
               {
                  next if ($info[4] eq 'spectator');

                  my @score = split(/,/, $info[2]);

                  for my $i (0..$#score)
                  {
                     if ($pscorelabels[$i])
                     {
                        $$pscores{$info[5]}{$pscorelabels[$i]} = $pscorelabels[$i] eq 'FASTEST' ? $score[$i]*-1 : $score[$i];
                     }
                  }

                  $$pscores{$info[5]}{PTIME} = $info[3];
                  $$pscores{$info[5]}{TEAM}  = $info[4];
                  $$pscores{$info[5]}{NAME}  = qfont_decode($info[6], 1);
               }
            }
            when ( 'teamscores' )
            {
               if ($info[1] eq 'see-labels')
               {
                  my @tscore = split(/,/, $info[2], 2);

                  for my $i (0..$#tscore)
                  {
                     $$tscores{$info[3]}{$tscorelabels[$i]} = $tscore[$i] if $tscorelabels[$i];
                  }
               }
            }
            when ( 'end' )
            {
               return unless $pscores;

               my @pkeys = keys(%$pscores);

               my $heading = '>>> Scores ';
               $heading   .= ('for ' . ($instagib ? 'InstaGib ' : '') . "$type ($$modes{$type}) on $map / ") if ($type && $map);
               $heading   .= "Players: " . scalar(@pkeys) . ($maptime ? (' / Match duration: ' . duration($maptime)) : '');
               $heading   .= ' <<<';

               my $t     = Text::ANSITable->new(use_utf8 => 1, wide => 1, use_color => 0, border_style => 'Default::csingle');
               my @cols  = grep { length && !/^FPS$/ } @pscorelabels;
               @cols     = grep { !/^TEAMKILLS|TK$/ }  @cols unless $teamplay;

               $t->columns(['NAME', @cols, 'PTIME']);

               my @pkeys_sorted = sort {$$pscores{$b}{$pscorekey} <=> $$pscores{$a}{$pscorekey}} @pkeys;
               @pkeys_sorted    = reverse(@pkeys_sorted) if $pscoreorder;

               my $tt;
               if ($teamplay)
               {
                  my @tkeys = keys(%$tscores);

                  $tt = Text::ANSITable->new(use_utf8 => 1, wide => 1, use_color => 0, border_style => 'Default::csingle');
                  my @tcols  = grep { length } @tscorelabels;

                  $tt->columns(['TEAM', @tcols]);

                  my @tkeys_sorted = sort {$$tscores{$b}{$tscorekey} <=> $$tscores{$a}{$tscorekey}} @tkeys;
                  @tkeys_sorted    = reverse(@tkeys_sorted) if $tscoreorder;

                  for my $id (@tkeys_sorted)
                  {
                     my @row;

                     push(@row, $$teams{$id}{color});
                     push(@row, int($$tscores{$id}{$_})) for (@tcols);

                     $tt->add_row(\@row);
                  }

                  @pkeys_sorted = sort {$$pscores{$b}{TEAM} <=> $$pscores{$a}{TEAM}} @pkeys;
               }

               my $lastteam;
               for my $id (@pkeys_sorted)
               {
                  my @row;

                  $$pscores{$id}{NAME} =~ s/[^\x00-\xFF]|\s+//g;

                  push(@row, truncate_egc($$pscores{$id}{NAME}, 18, '~'));

                  for (@cols)
                  {
                     given ( $_ )
                     {
                        when ( 'BCTIME' )
                        {
                           push(@row, duration($$pscores{$id}{$_}, 1));
                        }
                        when ( /^(?:CAPTIME|FASTEST)$/ )
                        {
                            push(@row, $$pscores{$id}{$_} ? sprintf('%.2fs', abs($$pscores{$id}{$_}/100)) : '-');
                        }
                        when ( /^DMG(?:[+-]|TAKEN)?$/ )
                        {
                           push(@row, sprintf('%.2fk', $$pscores{$id}{$_}/1000));
                        }
                        when ( 'ELO' )
                        {
                           push(@row, $$pscores{$id}{$_} < 0 ? '-' : int($$pscores{$id}{$_}));
                        }
                        when ( 'FPS' )
                        {
                           push(@row, $$pscores{$id}{$_} ? $$pscores{$id}{$_} : '-');
                        }
                        when ( 'SCORE' )
                        {
                           # server reported score in CA = DMG/100; Xonotic bug
                           push(@row, (($type && $type eq 'CA') ? '?' : int($$pscores{$id}{$_})));
                        }
                        default
                        {
                           push(@row, $$pscores{$id}{$_});
                        }
                     }
                  }

                  # more correct but breaks table formatting in discord when wrapping
                  #for (qw(BCTIME CAPTIME ELO DMG DMGTAKEN DMG+ DMG- FASTEST FPS))
                  #{
                  #   $t->set_column_style($_ => type => 'num') if ($_ ~~ @cols);
                  #}

                  push(@row, duration($$pscores{$id}{PTIME}, 1));

                  $t->add_row(\@row);

                  if ($teamplay)
                  {
                     # TODO: for some reason $t->add_row_separator() does nothing
                     $t->add_row_separator() if ($lastteam && ($lastteam != $$pscores{$id}{TEAM}));
                     $lastteam = $$pscores{$id}{TEAM};
                  }
               }

               $discord->send_message( $$config{discord}{linkchan}, ":video_game: `$heading`" );
               say localtime(time) . "\n" . $heading;

               my $tt_text;
               if ($teamplay)
               {
                  $tt_text = $tt->draw;
                  $tt_text =~ s/(?:^\s|\s$)//gm;

                  $discord->send_message( $$config{discord}{linkchan}, "```\n$tt_text```" );
                  say localtime(time) . "\n" . $tt_text;
               }

               my $t_text = $t->draw;
               $t_text =~ s/(?:^\s|\s$)//gm;

               $discord->send_message( $$config{discord}{linkchan}, "```\n$t_text```" );
               say localtime(time) . "\n$t_text";

               my $of;
               my $filename = $matchid ne 'none' ? "$$config{logdir}/$matchid.txt" : "$$config{logdir}/0." . time . '_no_id.txt';
               if ($$config{logdir} && $matchid && ($of = IO::File->new($filename, '>>:encoding(UTF-8)')))
               {
                  $of->print($heading . "\n");
                  $of->print($tt_text . "\n") if ($teamplay);
                  $of->print($t_text  . "\n");

                  undef $of;

                  say localtime(time) . " ** Scoretables written to $filename";
               }

               @lastplayers = @pkeys_sorted;
            }
            when ( 'gameover' )
            {
               $matchid = 'none';
            }
         }

         if (defined $msg)
         {
            return unless (exists $$players{$info[1]});

            $msg =~ s/(\s|\R)+/ /g;
            $msg =~ s/\@+everyone/everyone/g;
            $msg =~ s/\@+here/here/g;
            $msg =~ s/$discord_markdown_pattern/\\$1/g;

            say localtime(time) . " -> <$$players{$info[1]}{name}> $msg";

            $$players{$info[1]}{name} =~ s/`//g;

            my $final = "`$$players{$info[1]}{name}`  $msg";

            $final =~ s/^/$$config{discord}{partmoji} / if ($$config{discord}{partmoji} && $info[0] eq 'part');
            $final =~ s/^/$$config{discord}{joinmoji} / if ($$config{discord}{joinmoji} && $info[0] eq 'join');

            $discord->send_message( $$config{discord}{linkchan}, ':flag_' . $$players{$info[1]}{geo} . ': ' . $final );
         }

         delete $$players{$delaydelete} if (defined $delaydelete);
      }
   }
);

my $loop = IO::Async::Loop::Mojo->new();
$loop->add($xonstream);
$xonstream->connect(
   addr => {
      family   => $$config{remip} =~ /:/ ? 'inet6' : 'inet',
      socktype => 'dgram',
      port     => $$config{port},
      ip       => $$config{remip},
   },
   local_addr => {
      family   => defined $$config{locip} ? ( $$config{locip} =~ /:/ ? 'inet6' : 'inet' ) : ( $$config{remip} =~ /:/ ? 'inet6' : 'inet' ),
      socktype => 'dgram',
      port     => $$config{port}+444,
      ip       => defined $$config{locip} ? $$config{locip} : $$config{remip},
   },
)->get;
$loop->run unless (Mojo::IOLoop->is_running);

exit;

###

sub discord_on_message_create ()
{
   $discord->gw->on('MESSAGE_CREATE' => sub ($gw, $hash)
   {
      my $id       = $hash->{'author'}->{'id'};
      my $author   = $hash->{'author'};
      my $member   = $hash->{'member'};
      my $msg      = $hash->{'content'};
      my $msgid    = $hash->{'id'};
      my $channel  = $hash->{'channel_id'};
      my @mentions = $hash->{'mentions'}->@*;

      add_user($_) for(@mentions);

      unless ( exists $author->{'bot'} && $author->{'bot'} )
      {
         $msg =~ s/\@+everyone/everyone/g;
         $msg =~ s/\@+here/here/g;

         if ( $channel eq $$config{discord}{linkchan} )
         {
            if ( $msg =~ /(.*)?$$config{rcon_re}/i && $id == $$config{discord}{owner_id} )
            {
               return if $1;
               return unless $2;

               rcon($2);
               $discord->send_message( $channel, '`sent`' );
               say localtime(time) . " !! RCON used by: <$$author{'username'}> Command: $2";

               return;
            }

            $msg =~ s/`//g;
            $msg =~ s/\^/\^\^/g;
            if ( $msg =~ s/<@!?(\d+)>/\@$self->{'users'}->{$1}->{'username'}/g ) # user/nick
            {
               $msg =~ s/(?:\R^)\@$self->{'users'}->{$1}->{'username'}/ >>> /m if ($1 == $self->{'id'}); # quote
            }
            $msg =~ s/(?:\R|\s)+/ /g;
            $msg =~ s/<#(\d+)>/#$self->{'channelnames'}->{$1}/g; # channel
            $msg =~ s/<@&(\d+)>/\@$self->{'rolenames'}->{$1}/g; # role
            $msg =~ s/<a?(:.+:)\d+>/$1/g; # emoji
            $msg = stripcolors($msg);

            return unless $msg;

            my $nick = defined $$member{'nick'} ? $$member{'nick'} : $$author{'username'};
            $nick =~ s/\^/\^\^/g;
            $nick = stripcolors($nick);

            say localtime(time) . " <- <$nick> $msg";

            xonmsg($nick, $msg);
         }
         elsif ( $channel ~~ $$config{discord}{nocmdchans}->@* )
         {
            return;
         }
         elsif ( $msg =~ /$$config{status_re}/ )
         {
            unless ($map && $type)
            {
               $discord->send_message( $channel, '`No idea yet, I just woke up. Ask me later :D`' );
            }
            else
            {
               $discord->send_message( $channel, 'Type: **' . ($instagib ? 'i' : '') . "$type**  Map: **$map**  Players: **" . ((keys %$players) - $bots) . '**' );
            }
         }
         elsif ( $msg =~ /$$config{xonstat_re}/ )
         {
            my ($qid, $stats);
            ($qid = $1) =~ s/[^0-9]//g;

            unless ($qid)
            {
               $discord->send_message( $channel, '`Invalid player ID`');
               return;
            }

            my $xonstaturl = 'http://stats.xonotic.org/player/';
            my $json = get($xonstaturl . $qid . '.json');

            if ($json)
            {
               $stats = decode_json($json);
            }
            else
            {
               $discord->send_message( $channel, '`No response from server; Correct player ID?`');
               return;
            }

            my $snick   = $stats->[0]->{player}->{stripped_nick};
            my $games   = $stats->[0]->{games_played}->{overall}->{games};
            my $win     = $stats->[0]->{games_played}->{overall}->{wins};
            my $loss    = $stats->[0]->{games_played}->{overall}->{losses};
            my $pct     = $stats->[0]->{games_played}->{overall}->{win_pct};
            my $kills   = $stats->[0]->{overall_stats}->{overall}->{total_kills};
            my $deaths  = $stats->[0]->{overall_stats}->{overall}->{total_deaths};
            my $ratio   = $stats->[0]->{overall_stats}->{overall}->{k_d_ratio};
            my $elo     = $stats->[0]->{elos}->{overall}->{elo} ? $stats->[0]->{elos}->{overall}->{elo}          : 0;
            my $elot    = $stats->[0]->{elos}->{overall}->{elo} ? $stats->[0]->{elos}->{overall}->{game_type_cd} : 0;
            my $elog    = $stats->[0]->{elos}->{overall}->{elo} ? $stats->[0]->{elos}->{overall}->{games}        : 0;
            my $capr    = $stats->[0]->{overall_stats}->{ctf}->{cap_ratio} ? $stats->[0]->{overall_stats}->{ctf}->{cap_ratio} : 0;
            my $favmap  = $stats->[0]->{fav_maps}->{overall}->{map_name};
            my $favmapt = $stats->[0]->{fav_maps}->{overall}->{game_type_cd};
            my $lastp   = $stats->[0]->{overall_stats}->{overall}->{last_played_fuzzy};

            my $embed = {
               'color' => '3447003',
               'provider' => {
                  'name' => 'XonStat',
                  'url' => 'https://stats.xonotic.org',
                },
               'thumbnail' => {
                  'url' => 'https://cdn.discordapp.com/emojis/706283635719929876.png?v=1',
               },
                'footer' => {
                   'text' => "Last played: $lastp",
                },
                'fields' => [
                 {
                    'name'   => 'Name',
                    'value'  => "**[$snick]($xonstaturl$qid)**",
                    'inline' => \1,
                 },
                 {
                    'name'   => 'Games (W/L)',
                    'value'  => "$games ($win/$loss)",
                    'inline' => \1,
                 },
                 {
                    'name'   => 'Won',
                    'value'  => sprintf('%.2f%%', $pct),
                    'inline' => \1,
                 },
                 {
                    'name'   => 'Kills',
                    'value'  => $kills,
                    'inline' => \1,
                 },
                 {
                    'name'   => 'Deaths',
                    'value'  => $deaths,
                    'inline' => \1,
                 },
                 {
                    'name'   => 'K/D Ratio',
                    'value'  => sprintf('%.2f', $ratio),
                    'inline' => \1,
                 },
                 ],
            };

            push $$embed{'fields'}->@*, { 'name' => 'CTF Cap Ratio', 'value' => sprintf('%.2f', $capr), 'inline' => \1, } if $capr;

            if ($elo && $elo != 100)
            {
               push $$embed{'fields'}->@*, { 'name' => uc($elot) . ' ELO',   'value' => sprintf('%.2f', $elo),  'inline' => \1, };
               push $$embed{'fields'}->@*, { 'name' => uc($elot) . ' Games', 'value' => $elog,                  'inline' => \1, };
            }

            push $$embed{'fields'}->@*, { 'name' => 'Favourite Map', 'value' => sprintf('%s (%s)', $favmap, uc($favmapt)), 'inline' => \1, };

            my $message = {
               'content' => '',
               'embed' => $embed,
            };

            $discord->send_message( $channel, $message );
         }
      }
   });

   return;
}

sub xonmsg ($usr, $msg)
{
   rcon($$config{smbmod} ? "ircmsg ^3(^8DISCORD^3) ^7$usr^3: ^7$msg" : "msg ^7$usr^3: ^7$msg");

   return;
}

sub rcon ($line)
{
   $line = encode_utf8($line);

   if ($$config{secure} == 2)
   {
      push(@cmdqueue, $line);
      $xonstream->send($qheader.'getchallenge');
   }
   elsif ($$config{secure} == 1)
   {
      my $t = sprintf('%ld.%06d', time, int(rand(1000000)));
      my $d = Digest::HMAC::hmac("$t $line", $$config{pass}, \&Digest::MD4::md4);
      $xonstream->send($qheader."srcon HMAC-MD4 TIME $d $t $line");
   }
   else
   {
      say 'WARNING: Using plain text rcon_password, consider using rcon_secure >= 1';
      $xonstream->send($qheader."rcon $$config{pass} $line");
   }

   return;
}

sub chall_recvd ($c)
{
   my $line = shift(@cmdqueue);
   my $d = Digest::HMAC::hmac("$c $line", $$config{pass}, \&Digest::MD4::md4);
 
   $xonstream->send($qheader."srcon HMAC-MD4 CHALLENGE $d $c $line");

   return;
}

sub qfont_decode ($qstr, $ascii = 0)
{
   my @chars;

   for (split('', $qstr))
   {
      my $i = ord($_) - 0xE000;
      my $c = ($_ ge "\N{U+E000}" && $_ le "\N{U+E0FF}")
      ? ($ascii ? $qfont_ascii_table[$i % @qfont_ascii_table] : $qfont_unicode_glyphs[$i % @qfont_unicode_glyphs])
      : $_;
      push @chars, $c if defined $c;
   }

   return join '', @chars;
}

sub stripcolors ($str)
{
   $str =~ s/\^(\d|x[\dA-Fa-f]{3})//g;

   return $str;
}

sub duration ($sec, $nos = 0)
{
   return '-' unless $sec;

   my @gmt = gmtime($sec);

   $gmt[5] -= 70;

   return ($gmt[7] ?  $gmt[7]                                                        .'d' : '').
          ($gmt[2] ? ($gmt[7]                       ? ($nos ? '' : ' ') : '').$gmt[2].'h' : '').
          ($gmt[1] ? ($gmt[7] || $gmt[2]            ? ($nos ? '' : ' ') : '').$gmt[1].'m' : '').
          ($gmt[0] ? ($gmt[7] || $gmt[2] || $gmt[1] ? ($nos ? '' : ' ') : '').$gmt[0].'s' : '');
}

sub discord_on_ready ()
{
   $discord->gw->on('READY' => sub ($gw, $hash)
   {
      add_me($hash->{'user'});
      $discord->status_update( { 'name' => $$config{'game'}, type => 0 } ) if ( $$config{'game'} );
   });

   return;
}

sub add_me ($user)
{
   $self->{'id'} = $user->{'id'};
   add_user($user);

   return;
}

sub add_user ($user)
{
   $self->{'users'}{$user->{'id'}} = $user;

   return;
}

sub add_guild ($guild)
{
   $self->{'guilds'}{$guild->{'id'}} = $guild;

   foreach my $channel ($guild->{'channels'}->@*)
   {
      $self->{'channels'}{$channel->{'id'}} = $guild->{'id'};
      $self->{'channelnames'}{$channel->{'id'}} = $channel->{'name'}
   }

   foreach my $role ($guild->{'roles'}->@*)
   {
      $self->{'rolenames'}{$role->{'id'}} = $role->{'name'};
   }

   return;
}
