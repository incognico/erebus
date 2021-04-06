#!/usr/bin/env perl

# Erebus - Discord bot for the twilightzone Xonotic server
#          Links a Xonotic server with a discord channel
#          In contrast to rcon2irc.pl this just links chats
#
# Requires https://github.com/vsTerminus/Mojo-Discord
#
# Copyright 2020-2021, Nico R. Wohlgemuth <nico@lifeisabug.com>

# Xonotic server.cfg:
#
# log_dest_udp "<locip:port>"
# sv_eventlog 1
# sv_eventlog_ipv6_delimiter 1
# rcon_secure 1 // or 2
# rcon_password "<pass>"
# sv_adminnick "^8DISCORD^3" // If the server is not using SMB modpack
#                            // (if you don't know what that is, you aren't)
# sv_logscores_bots 1 // if you want

# Note that rcon_restricted_password can be used only when smbmod is 0
# and "say" is added to rcon_restricted_commands.

use v5.28.0;

use utf8;
use strict;
use warnings;
use autodie ':all';

use lib '/etc/perl';

use feature 'signatures';
no warnings qw(experimental::signatures experimental::smartmatch);

binmode( STDOUT, ":encoding(UTF-8)" );

#use Data::Dumper;
use Digest::HMAC;
use Digest::MD4;
use Encode::Simple qw(encode_utf8 decode_utf8);
use IO::Async::Loop::Mojo;
use IO::Async::Socket;
use IO::File;
use JSON::MaybeXS;
use LWP::Simple qw($ua get);
use MaxMind::DB::Reader;
use Mojo::Discord;
use Text::ANSITable;
use Unicode::Homoglyph::Replace 'replace_homoglyphs';
use Unicode::Truncate;

$ua->timeout( 3 );
$ua->default_header( 'Accept' => 'application/json' );

my ($guild, $users, $q, $laststatus, $antispam);

my $config = {
   remip  => '2a02:c207:3003:5281::1',     # IP or hostname of the Xonotic server
   port   => 26660,                        # Port of the Xonotic Server, local port = this + 444 (log_dest_udp port)
   locip  => undef,                        # Local IP, if undef it uses $remip (log_dest_udp ip)
   secure => 1,                            # rcon_secure value in server.cfg, 0 is insecure, 1 or 2 are recommended (1 is the Xonotic default)
   smbmod => 0,                            # Set to 1 if server uses SMB modpack, otherwise use 0 and set sv_adminnick "^8DISCORD^3" in server.cfg
   pass   => '',                           # rcon_password in server.cfg
   geo    => '/home/k/GeoLite2-City.mmdb', # Path to GeoLite2-City.mmdb from maxmind.com
   logdir => "$ENV{HOME}/.xonotic/erebus/scorelogs", # If not empty (''), this folder will be used to save endmatch scoreboards to (one .txt file per match)
   debug  => 0,                            # Prints incoming log lines to console if 1

   status_re  => qr/^!status/i,                     # regexp for the status command
   xonstat_re => qr/^!(?:xon(?:stat)?s?|xs) (.+)/i, # regexp for the xonstat command
   rcon_re    => qr/^!rcon (.+)/i,                  # regexp for the rcon command, only owner_id is allowed to use this, works in linkchan only

   discord => {
     linkchan   => 824252953212616704, # The discord channel ID which will link discord and server chats
     nocmdchans => [706113584626663475, 610862900357234698, 698803767512006677], # Channel IDs where !cmds like !status are not allowed

     client_id  => 706112802137309224, # Discord bot client ID https://discordapp.com/developers/applications/
     owner_id   => 373912992758235148, # ID of the bots owner, if set this allows the owner to use the !rcon command, using 0 disables !rcon
     guild_id   => 458323696910598165, # ID of the discord guild

     joinmoji   => "\N{U+1F44B}", # Join emoji   if not empty ('') those will be displayed between the country flag
     partmoji   => "\N{U+1F44B}", # Part emoji   and the players nickname when joining or leaving the server

     showtcolor => 1, # Whether to show team color indicator for chat in Discord
     showtchat  => 1, # Whether to show team chat in Discord
     showvotes  => 0, # Whether to show in-game voting activity in Discord
   },

   # This is all optional and made for the twilightzone server, just set weather and radio->enabled to 0 and ignore it
   weather => 0,
   radio => {
      enabled      => 0,
      # for some reason now says ERROR: Filtering and streamcopy cannot be used together.
      #youtube_dl   => [qw(/usr/bin/youtube-dl -q -w -x -f bestaudio/best[height<=480] --audio-format vorbis --audio-quality 1 --no-mtime --no-warnings --prefer-ffmpeg --postprocessor-args), '-af dynaudnorm'],
      youtube_dl   => [qw(/usr/bin/youtube-dl -q -w -x -f bestaudio/best[height<=480] --audio-format vorbis --audio-quality 1 --no-mtime --no-warnings --prefer-ffmpeg)],
      yt_api_key   => '',
      tempdir      => "$ENV{HOME}/.xonotic/radiotmp",
      webdir       => '/srv/www/distfiles.lifeisabug.com/htdocs/xonotic/radio',
      queuefile    => 'queue.txt',
      playlistfile => 'playlist.txt',
      prefix       => 'radio-twlz-',
      xoncmd_re    => qr/!queue (?:add)? ?(.+)/i,
   },
};
# You can also experiment with different table border styles and paddings, Default::csingle with default (1) cell_pad looks nice but uses lots of space and chars
# As soon as it warps it looks off in discord. To get as tight as possible use Default::singlei_utf8, cell_pad 0 and extend the $shortnames hash even more.
# cell_pad 0 breaks even more on wrapping but does not wrap so often, it really needs to be played around with.

my $discord = Mojo::Discord->new(
   'version'   => 9999,
   'url'       => 'https://xonotic.lifeisabug.com',
   'token'     => '', # Discord bot secret token https://discordapp.com/developers/applications/
   'reconnect' => 1,
   'verbose'   => 0,
   'logdir'    => "$ENV{HOME}/.xonotic/erebus",
   'logfile'   => 'discord.log',
   'loglevel'  => 'info',
);

my $teams = {
   -1 => {
      color  => 'SPECTATOR',
      scolor => 'S',
      emoji  => ':telescope:',
   },
   1 => {
      color  => 'NONE',
      scolor => '-',
      emoji  => ':white_square_button:',
   },
   5 => {
      color  => 'RED',
      scolor => 'R',
      id     => 1,
      emoji  => ':red_square:',
   },
   10 => {
      color  => 'PINK',
      scolor => 'P',
      id     => 4,
      emoji  => ':purple_square:',
   },
   13 => {
      color  => 'YELLOW',
      scolor => 'Y',
      id     => 3,
      emoji  => ':yellow_square:',
   },
   14 => {
      color  => 'BLUE',
      scolor => 'B',
      id     => 2,
      emoji  => ':blue_square:',
   },
   spectator => {
      color  => 'SPECTATOR',
      scolor => 'S',
      id     => 1337,
      emoji  => ':telescope:',
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
   'BCKILLS'    => 'BCK',
   #'DEATHS'     => 'DTHS',
   'DESTROYED'  => 'DSTRYD',
   'DMG'        => 'DMG+',
   'DMGTAKEN'   => 'DMG-',
   'DROPS'      => 'DRPS',
   'FCKILLS'    => 'FCK',
   'KCKILLS'    => 'KCK',
   #'KILLS'      => 'KLLS',
   'OBJECTIVES' => 'OBJ',
   'PICKUPS'    => 'PUPS',
   'PUSHES'     => 'PSHS',
   'RETURNS'    => 'RETS',
   'REVIVALS'   => 'REVS',
   #'SCORE'      => 'SCRE',
   'SUICIDES'   => 'SK',
   'TEAM'       => 'T',
   'TEAMKILLS'  => 'TK',
};

my $discord_char_limit = 1980; # -20

#my $discord_markdown_pattern = qr/(?<!\\)(`|@|:|#|\||__|\*|~|>)/;
my $discord_markdown_pattern = qr/(?<!\\)(`|@|#|\||_|\*|~|>)/;

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

die('SMB modpack is required for the configured feature set.') if (($$config{weather} || $$config{radio}{enabled}) && !$$config{smbmod});

require Weather::METNO if ($$config{weather});

if ($$config{radio}{enabled})
{
   $$q{blocked} = [];

   $$config{radio}{queuefile}    = $$config{radio}{webdir} . '/' . $$config{radio}{queuefile};
   $$config{radio}{playlistfile} = $$config{radio}{webdir} . '/' . $$config{radio}{playlistfile};

   push ($$config{radio}{youtube_dl}->@*, '-o');
   push ($$config{radio}{youtube_dl}->@*, $$config{radio}{tempdir} . '/%(id)s.%(ext)s');

   require File::Copy;
   require HTML::Entities;
   require IO::Async::Process;
   require URI::Escape;
   File::Copy->import;
   HTML::Entities->import;
   URI::Escape->import;
}

my $gi = MaxMind::DB::Reader->new(file => $$config{'geo'});

discord_on_ready();
discord_on_guild_create();
discord_on_message_create();

$discord->init();

my ($recvbuf, @cmdqueue);

my ($matchid, $map, $bots, $players, $type, $instagib, $maptime, $teamplay, @lastplayers)
=  ('none',   '',   0,     {},       '',    0,         0,        0,         (),         );
my (@pscorelabels, $pscorekey, $pscoreorder, $pscores, @tscorelabels, $tscorekey, $tscorekey2, $tscoreorder, $tscoreorder2, $tscores)
=  ((),            'SCORE',    0,            {},       (),            'SCORE',    '',          0,            0,             {},     );

my $xonstream = IO::Async::Socket->new(
   recv_len => 1400,

   on_recv => sub ($self, $dgram, $addr)
   {
      chall_recvd($1) if ($dgram =~ /^${qheader}challenge (.*)(\0|$)/);

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

               $$players{$info[1]}{name} = $info[4] = 'unnamed' unless $$players{$info[1]}{name};

               unless ($info[3] eq 'bot')
               {
                  my $r = $gi->record_for_address($$players{$info[1]}{ip});

                  $$players{$info[1]}{geo} = $r->{country}{iso_code} ? lc($r->{country}{iso_code}) : undef;

                  if ($$config{weather})
                  {
                     return if (exists $$q{weather}{$$players{$info[1]}{ip}} && $$q{weather}{$$players{$info[1]}{ip}}+10800 > time);

                     my $w = Weather::METNO->new(lat => $r->{location}{latitude}, lon => $r->{location}{longitude}, uid => '');
                     rcon(sprintf('defer 6 "tell #%u ^6Welcome^7, %s^6!^7 Your local ^5weather^7 forecast: ^5%.1f°C ^7/^5 %.1f°F ^8:: ^5%s ^8::^7 Cld: %u%% ^8::^7 Hum: %u%% ^8::^7 Fog: %u%% ^8::^7 UVI: %.3g ^8::^7 Wind: ^5%s^7 from %s"', $info[2], rconquote($info[4]), $w->temp_c, $w->temp_f, $w->symbol_txt, $w->cloudiness, $w->humidity, $w->foginess, $w->uvindex, $w->windspeed_bft_txt, $w->windfrom_dir));
                     $$q{weather}{$$players{$info[1]}{ip}} = time;
                  }

                  $msg = '_has joined the game_' unless ($info[1] ~~ @lastplayers); # filter joins after map change to prevent spam
               }
               else
               {
                  $bots++;
               }
            }
            when ( 'part' )
            {
               $delaydelete = $info[1];

               if (defined $$players{$info[1]}{ip})
               {
                  unless ($$players{$info[1]}{ip} eq 'bot')
                  {
                     $msg = '_has left the game_';
                     @lastplayers = grep { $_ != $delaydelete } @lastplayers;
                  }
                  else
                  {
                     $bots--;
                  }
               }

               delete $$antispam{$$players{$info[1]}{ip}} if (exists $$antispam{$$players{$info[1]}{ip}});
            }
            when ( 'chat' )
            {
               $msg = $info[2];

               if ($$config{radio}{enabled} && defined $$players{$info[1]}{ip})
               {
                  if ($msg =~ /$$config{radio}{xoncmd_re}/)
                  {
                     radioq_request($1, $$players{$info[1]}{ip}, $$players{$info[1]}{name});

                     next;
                  }
                  elsif ($msg ~~ ['1','2','3','0'] && defined $$q{search_tmp}{$$players{$info[1]}{ip}})
                  {
                     radioq_request($msg, $$players{$info[1]}{ip}, $$players{$info[1]}{name}, 1);

                     next;
                  }
               }
            }
            when ( 'chat_spec' )
            {
               $msg = '(SPECTATOR) ' . $info[2];
            }
            when ( 'chat_team' )
            {
               $msg = "($$teams{$info[2]}{color}) $info[3]" if $$config{discord}{showtchat};
            }
            when ( 'name' )
            {
               $$players{$info[1]}{name} = $info[2];
            }
            when ( 'team' )
            {
               $$players{$info[1]}{team} = $info[2];

               $teamplay = 1 if ($info[2] ~~ [5, 10, 13, 14]);
            }
            when ( 'gamestart' )
            {
               ($bots, $players, $teamplay) = (0, {}, 0);

               ($type, $map) = (uc($1), $2) if ($info[1] =~ /^([a-z]+)_(.+)$/);

               $matchid = $info[2];
            }
            when ( 'gameinfo' )
            {
               if ($info[1] eq 'mutators' && $info[2] eq 'LIST')
               {
                  $instagib = 'instagib' ~~ @info[3..$#info] ? 1 : 0;
               } 
               elsif ($info[1] eq 'end')
               {
                  if ($type && $map)
                  {
                     my $status = ($instagib ? 'i' : '') . "$type on $map";
                     $discord->status_update( { 'name' => $status, type => 0 } ) unless (defined $laststatus && $status eq $laststatus);
                     $laststatus = $status;
                  }
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
                  $msg = ':checkered_flag: set a record: ' . sprintf(' %.3f seconds!', $info[2]);
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

                  $msg = ":flags: captured the $$teams{$info[2]}{color} flag for team $$teams{$info[3]}{color}" . ($$players{$info[4]}{recordset} ? sprintf(' in a record %.3f seconds!', $$players{$info[4]}{recordset}) : '');

                  delete $$players{$info[4]}{recordset};
               }
            }
            when ( 'vote' )
            {
               next unless ($$config{discord}{showvotes});

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

               ($type, $map) = (uc($1), $2) if ($info[1] =~ /^([a-z]+)_(.+)$/);
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
                        my $label = $1;
                        my $flags = $2;

                        $pscorelabels[$_] = $label;

                        if ($flags && $flags =~ /!!/)
                        {
                           $pscorekey   = $label;
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
                        else
                        {
                           $tscorekey2   = $label;
                           $tscoreorder2 = 1 if ($flags && $flags =~ /</);
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
                        # *-1 for correct sorting, abs()'d later, in CTS scoreflag is < but 0 is worst
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

               my $t     = Text::ANSITable->new(use_utf8 => 1, wide => 1, use_color => 0, border_style => 'Default::singlei_utf8'); # cell_pad => $teamplay ? 0 : 1
               my @cols  = grep { length && !/^(FPS|ELO)$/ } @pscorelabels;

               if ($teamplay)
               {
                  $pscorekey = $$shortnames{$pscorekey} if (exists $$shortnames{$pscorekey});

                  for my $id (keys(%$pscores))
                  {
                     for (@cols)
                     {
                        $$pscores{$id}{$$shortnames{$_}} = delete $$pscores{$id}{$_} if (exists $$shortnames{$_});
                     }
                  }

                  for (@cols)
                  {
                     $_ = $$shortnames{$_} if (exists $$shortnames{$_});
                  }

                  unshift(@cols, exists $$shortnames{TEAM} ? $$shortnames{TEAM} : 'TEAM');
               }
               else
               {
                  @cols = grep { !/^(TEAM(KILLS)|TK)$/n } @cols;
               }

               $t->columns(['NAME', @cols, 'PTIME']);

               my @pkeys_sorted = sort {$$pscores{$b}{$pscorekey} <=> $$pscores{$a}{$pscorekey}} @pkeys;
               @pkeys_sorted    = reverse(@pkeys_sorted) if $pscoreorder;

               my $tt;
               if ($teamplay)
               {
                  my @tkeys = keys(%$tscores);

                  $tt = Text::ANSITable->new(use_utf8 => 1, wide => 1, use_color => 0, border_style => 'Default::singlei_utf8');
                  my @tcols  = grep { length } @tscorelabels;

                  $tt->columns(['TEAM', @tcols]);

                  my @tkeys_sorted = sort {
                     $$tscores{$b}{$tscorekey} <=> $$tscores{$a}{$tscorekey} ||
                     $$tscores{$a} <=> $$tscores{$b}
                  } @tkeys;
                  @tkeys_sorted    = reverse(@tkeys_sorted) if $tscoreorder;

                  for my $id (@tkeys_sorted)
                  {
                     my @row;

                     push(@row, $$teams{$id}{color});
                     push(@row, int($$tscores{$id}{$_})) for (@tcols);

                     $tt->add_row(\@row);
                  }

                  @pkeys_sorted = sort {
                     $$tscores{$$pscores{($tscoreorder ? $a : $b)}{TEAM}}{$tscorekey} <=> $$tscores{$$pscores{($tscoreorder ? $b : $a)}{TEAM}}{$tscorekey} ||
                     $$pscores{$a}{TEAM} <=> $$pscores{$b}{TEAM}
                  } @pkeys_sorted;
               }

               my $lastteam;
               for my $id (@pkeys_sorted)
               {
                  if ($teamplay)
                  {
                     $t->add_row_separator() if ($lastteam && ($lastteam != $$pscores{$id}{TEAM}));
                     $lastteam = $$pscores{$id}{TEAM};
                  }

                  my @row;

                  $$pscores{$id}{NAME} = replace_homoglyphs($$pscores{$id}{NAME});
                  $$pscores{$id}{NAME} =~ s/[^\x00-\xFF]|\s+//g;

                  push(@row, truncate_egc($$pscores{$id}{NAME}, $teamplay ? 18 : 24, '~'));

                  for (@cols)
                  {
                     given ( $_ )
                     {
                        when ( /SCO?RE/ )
                        {
                           # server reported score in CA = float (actually damage dealt), Xonotic "bug"
                           push(@row, int($$pscores{$id}{$_}));
                        }
                        when ( /^T(EAM)?$/n )
                        {
                           push(@row, $$teams{$$pscores{$id}{TEAM}}{scolor}) if $teamplay;
                        }
                        when ( 'BCTIME' )
                        {
                           push(@row, duration($$pscores{$id}{$_}, 1));
                        }
                        when ( /^(CAPTIME|FASTEST)$/n )
                        {
                            push(@row, $$pscores{$id}{$_} ? sprintf('%.2fs', abs($$pscores{$id}{$_}/100)) : '-');
                        }
                        when ( /^(DMG([+-]|TAKEN)?)$/n )
                        {
                           push(@row, sprintf('%.2fk', $$pscores{$id}{$_}/1000));
                        }
                        when ( 'ELO' )
                        {
                           push(@row, $$pscores{$id}{$_} <= 0 ? '-' : int($$pscores{$id}{$_}));
                        }
                        when ( 'FPS' )
                        {
                           push(@row, $$pscores{$id}{$_} ? $$pscores{$id}{$_} : '-');
                        }
                        default
                        {
                           push(@row, $$pscores{$id}{$_});
                        }
                     }
                  }

                  # more correct but breaks table formatting in discord when wrapping
                  #for (qw(BCTIME CAPTIME DMG DMGTAKEN DMG+ DMG- ELO FASTEST FPS SCORE))
                  #{
                  #   $t->set_column_style($_ => type => 'num') if ($_ ~~ @cols);
                  #}

                  push(@row, duration($$pscores{$id}{PTIME}, 1));

                  $t->add_row(\@row);
               }

               $discord->send_message_content_blocking( $$config{discord}{linkchan}, ":video_game: `$heading`" );
               say localtime(time) . "\n" . $heading;

               my $tt_text;
               if ($teamplay)
               {
                  $tt_text = $tt->draw;
                  $tt_text =~ s/^\s|\s$//gm;

                  $discord->send_message_content_blocking( $$config{discord}{linkchan}, "```q\n$tt_text\n```" );
                  say localtime(time) . "\n" . $tt_text;
               }

               my $t_text = $t->draw;
               $t_text =~ s/^\s|\s$//gm;

               $discord->send_message_content_blocking( $$config{discord}{linkchan}, "```q\n$1\n```" ) while ($t_text =~ /\G(.{0,$discord_char_limit}(?:.\z|\R))/sg);
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

               (@pscorelabels, $pscorekey, $pscoreorder, $pscores, @tscorelabels, $tscorekey, $tscorekey2, $tscoreorder, $tscoreorder2, $tscores)
             = ((),            'SCORE',    0,            {},       (),            'SCORE',    '',          0,            0,             {}      );
            }
            when ( 'gameover' )
            {
               ($teamplay, $matchid) = (0, 'none');
            }
         }

         if (defined $msg)
         {
            return unless (defined $$players{$info[1]}{name});
            return if ($$players{$info[1]}{ip} eq 'bot');

            my $nick = $$players{$info[1]}{name};
            my $ip   = $$players{$info[1]}{ip};
            my $team = $$players{$info[1]}{team};

            say localtime(time) . " -> <$nick> $msg";

            return if (exists $$antispam{$ip} && $msg eq $$antispam{$ip});
            $$antispam{$ip} = $msg;

            $nick =~ s/`//g;

            $msg =~ s/(\s|\R)+/ /gn;
            $msg =~ s/\@+everyone/everyone/g;
            $msg =~ s/\@+here/here/g;
            $msg =~ s/$discord_markdown_pattern/\\$1/g;

            $msg = '_' . substr($msg, length($nick)+1) . '_' if ($msg =~ /^\Q$nick\E /); # /me

            my $t = '';
            $t = $$teams{$team}{emoji} . ' ' if ($$config{discord}{showtcolor} && $teamplay);

            my $final = "$t`$nick`  $msg";

            $final =~ s/^/$$config{discord}{partmoji} / if ($$config{discord}{partmoji} && $info[0] eq 'part');
            $final =~ s/^/$$config{discord}{joinmoji} / if ($$config{discord}{joinmoji} && $info[0] eq 'join');

            my $message = {
               content => ':' . (defined $$players{$info[1]}{geo} ? ('flag_' . $$players{$info[1]}{geo}) : 'gay_pride_flag') . ': ' . $final,
               allowed_mentions => { parse => [] },
            };

            $discord->send_message( $$config{discord}{linkchan}, $message );
         }

         delete $$players{$delaydelete} if (defined $delaydelete);
      }
   }
);

my $loop = IO::Async::Loop::Mojo->new();
$loop->add($xonstream);
$xonstream->connect(
   socktype      => 'dgram',
   service       => $$config{port},
   local_service => $$config{port}+444,
   host          => $$config{remip},
   local_host    => defined $$config{locip} ? $$config{locip} : $$config{remip},
)->get;
$loop->run unless (Mojo::IOLoop->is_running);

exit;

###

sub discord_on_ready ()
{
   $discord->gw->on('READY' => sub ($gw, $hash)
   {
      add_me($hash->{'user'});
      $discord->status_update( { 'name' => ($laststatus ? $laststatus : 'Xonotic'), type => 0 } );
   });

   return;
}

sub discord_on_guild_create ()
{
   $discord->gw->on('GUILD_CREATE' => sub ($gw, $hash) { $guild = $discord->get_guild($$config{'discord'}{'guild_id'}); });

   return;
}

sub discord_on_message_create ()
{
   $discord->gw->on('MESSAGE_CREATE' => sub ($gw, $hash)
   {
      my $id       = $hash->{'author'}->{'id'};
      my $username = $hash->{'author'}->{'username'};
      my $bot      = exists $hash->{'author'}->{'bot'} ? $hash->{'author'}->{'bot'} : 0;
      my $nickname = $hash->{'member'}->{'nick'};
      my $msg      = $hash->{'content'};
      my $msgid    = $hash->{'id'};
      my $channel  = $hash->{'channel_id'};
      my @mentions = $hash->{'mentions'}->@*;

      add_user($_) for (@mentions);

      unless ( $bot )
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
               $discord->create_reaction( $channel, $msgid, "\N{U+2705}" );
               say localtime(time) . " !! RCON used by: <$username> Command: $2";

               return;
            }

            return unless (keys %$players > 0);

            $msg =~ s/`//g;
            if ( $msg =~ s/<@!?(\d+)>/\@$$users{'users'}{$1}{'username'}/g ) # user/nick
            {
               $msg =~ s/(?:\R^)\@$$users{'users'}{$1}{'username'}/ >>> /m if ($1 == $$users{'id'});
            }
            $msg =~ s/(\R|\s)+/ /gn;
            $msg =~ s/<#(\d+)>/#$$guild{'channels'}{$1}{'name'}/g; # channel
            $msg =~ s/<@&(\d+)>/\@$$guild{'roles'}{$1}{'name'}/g; # role
            $msg =~ s/<a?(:[^:.]+:)\d+>/$1/g; # emoji

            return unless $msg;

            my $nick = defined $nickname ? $nickname : $username;
            $nick =~ s/`//g;
            $nick =~ s/(\R|\s)+/ /gn;

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

            my $xonstaturl = 'https://stats.xonotic.org/player/';
            my $json = get($xonstaturl . $qid);

            if ($json)
            {
               $stats = decode_json(encode_utf8($json));
            }
            else
            {
               $discord->send_message( $channel, '`No response from server; Correct player ID?`');
               return;
            }

            my $snick   = decode_utf8($$stats{player}{stripped_nick});
            my $games   = $$stats{games_played}{overall}{games};
            my $win     = $$stats{games_played}{overall}{wins};
            my $loss    = $$stats{games_played}{overall}{losses};
            my $pct     = $$stats{games_played}{overall}{win_pct};
            my $kills   = $$stats{overall_stats}{overall}{total_kills};
            my $deaths  = $$stats{overall_stats}{overall}{total_deaths};
            my $ratio   = $$stats{overall_stats}{overall}{k_d_ratio};
            #my $elo     = $$stats{elos}{overall}{elo} ? $$stats{elos}{overall}{elo}          : 0;
            #my $elot    = $$stats{elos}{overall}{elo} ? $$stats{elos}{overall}{game_type_cd} : 0;
            #my $elog    = $$stats{elos}{overall}{elo} ? $$stats{elos}{overall}{games}        : 0;
            my $capr    = $$stats{overall_stats}{ctf}{cap_ratio} ? $$stats{overall_stats}{ctf}{cap_ratio} : 0;
            #my $favmap  = $$stats{fav_maps}{overall}{map_name};
            #my $favmapt = $$stats{fav_maps}{overall}{game_type_cd};
            my $lastp   = $$stats{overall_stats}{overall}{last_played_fuzzy};
            my $joined  = $$stats{player}{joined_fuzzy};
            #my $active  = $$stats{player}{active_ind} eq JSON->true ? 1 : 0;

            my $embed = {
               'color' => '3447003',
               'provider' => {
                  'name' => 'XonStat',
                  'url'  => 'https://stats.xonotic.org',
                },
               'thumbnail' => {
                  'url' => 'https://cdn.discordapp.com/emojis/706283635719929876.png?v=1',
               },
                'footer' => {
                   'text' => "First seen: $joined",
                },
                'fields' => [
                 {
                    'name'   => 'Name',
                    'value'  => "**[$snick]($xonstaturl$qid)**",
                    'inline' => \0,
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
                    'value'  => "$kills",
                    'inline' => \1,
                 },
                 {
                    'name'   => 'Deaths',
                    'value'  => "$deaths",
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

            #if ($elo && $elo != 100)
            #{
            #   push $$embed{'fields'}->@*, { 'name' => uc($elot) . ' ELO',   'value' => sprintf('%.2f', $elo),  'inline' => \1, };
            #   push $$embed{'fields'}->@*, { 'name' => uc($elot) . ' Games', 'value' => $elog,                  'inline' => \1, };
            #}

            #push $$embed{'fields'}->@*, { 'name' => 'Favourite Map', 'value' => sprintf('%s (%s)', $favmap, uc($favmapt)), 'inline' => \1, };
            push $$embed{'fields'}->@*, { 'name' => 'Last played', 'value' => $lastp, 'inline' => \1, };

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

sub add_me ($user)
{
   $$users{'id'} = $$user{'id'};
   add_user($user);

   return;
}

sub add_user ($user)
{
   $$users{'users'}{$$user{'id'}} = $user;

   return;
}

###

sub xonmsg ($nick, $msg)
{
   $nick = rconquote($nick);
   $msg  = rconquote($msg);

   my $line = $$config{smbmod} ? 'sv_cmd ircmsg ^3(^8DISCORD^3) ^7' . $nick . '^3: ^7' . $msg : 'say "^7' . $nick . '^3: ^7' . $msg . '"';

   rcon($line);

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

sub qfont_decode ($qstr = '', $ascii = 0)
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

sub rconquote ($str)
{
   $str =~ s/[\000-\037|\377]//g;
   $str =~ s/(\R|\s)+/ /gn;
   $str = stripcolors($str);
   $str =~ s/\^/\^\^/g;
   $str = replace_homoglyphs($str);

   return $str;
}

sub duration ($sec, $nos = 0)
{
   return '-' unless $sec;

   my @gmt = gmtime($sec);

   $gmt[5] -= 70;

   return ($gmt[7] ?  $gmt[7]                                                                  .'d' : '').
          ($gmt[2] ? ($gmt[7]                       ? ($nos ? "\N{U+200E}" : ' ') : '').$gmt[2].'h' : '').
          ($gmt[1] ? ($gmt[7] || $gmt[2]            ? ($nos ? "\N{U+200E}" : ' ') : '').$gmt[1].'m' : '').
          ($gmt[0] ? ($gmt[7] || $gmt[2] || $gmt[1] ? ($nos ? "\N{U+200E}" : ' ') : '').$gmt[0].'s' : '');
}

sub radioq_request ($request, $ip, $name, $choose = 0)
{
   my ($search, $details, $vid, $title, $sec);

   unless ($choose)
   {
      my $cooldown = 240;

      if (exists $$q{ts}{$ip} && $$q{ts}{$ip}+$cooldown > time)
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^3' . rconquote($name) . '^7: Cooldown! Wait ' . duration(($$q{ts}{$ip}+$cooldown)-time) . ' until you can use the queue again.');
         return;
      }

      $$q{ts}{$ip} = time;

      my $query  = uri_escape_utf8($request);
      my $json_s = get("https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=3&type=video&q=$query&key=$$config{radio}{yt_api_key}");

      if ($json_s)
      {
         $search = decode_json($json_s);
      }
      else
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Error querying YouTube API (Probably no quota left, try again tomorrow) ' . "\N{U+1F61E}");
         return;
      }

      if (scalar $$search{items}->@* > 0)
      {
         my $results = 'sv_cmd ircmsg ^0[^1YouTube^0] ^3' . rconquote($name) . '^7: Choose by saying the number:';

         for (0..$$search{items}->$#*)
         {
            $$q{search_tmp}{$ip}{$_+1}{vid}   = $$search{items}[$_]{id}{videoId};
            $$q{search_tmp}{$ip}{$_+1}{title} = rconquote(decode_entities($$search{items}[$_]{snippet}{title}));

            $results .= (' ^0[^1' . ($_+1) . '^0] ^7' . truncate_egc($$q{search_tmp}{$ip}{$_+1}{title}, 64));
         }

         $results .= ' ^0[^10^0] ^7None/Cancel';

         rcon($results);

         return;
      }
      else
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Nothing found for ' . rconquote($request) . " \N{U+1F61E}");
         return;
      }
   }
   else
   {
      unless ($request)
      {
         delete $$q{search_tmp}{$ip};

         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^3' . rconquote($name) . '^7: Canceled.');
         return;
      }

      unless (defined $$q{search_tmp}{$ip}{$request})
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7No such ID: ^0[^1' . $request . '^0]');
         return;
      }

      $vid   = $$q{search_tmp}{$ip}{$request}{vid};
      $title = $$q{search_tmp}{$ip}{$request}{title};

      delete $$q{search_tmp}{$ip};

      if ($vid ~~ $$q{blocked}->@[0..99])
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Already processed recently: ' . $title);
         return;
      }
      else
      {
         unshift($$q{blocked}->@*, $vid);
      }
   }

   if (-e "$$config{radio}{webdir}/$$config{radio}{prefix}$vid.pk3")
   {
      my $queuefile = IO::File->new($$config{radio}{queuefile}, '<:encoding(UTF-8)');
      while(my $line = <$queuefile>)
      {
         $line =~ s/\s$vid\.ogg\s(\d+)\s/$sec = $1/eg;
         last if $sec;
      }
      undef $queuefile;

      if ($sec)
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Already queued: ' . $title);
         return;
      }

      my $playlistfile = IO::File->new($$config{radio}{playlistfile}, '<:encoding(UTF-8)');
      while(my $line = <$playlistfile>)
      {
         $line =~ s/\s$vid\.ogg\s(\d+)\s/$sec = $1/eg;
         last if $sec;
      }
      undef $playlistfile;

      unless ($sec)
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Error getting playtime from playlistfile' . "\N{U+1F61E}");
         return;
      }

      my $pk3 = "$$config{radio}{prefix}$vid.pk3";

      $queuefile = IO::File->new($$config{radio}{queuefile}, '>>:encoding(UTF-8)');
      $queuefile->print("$pk3 $vid.ogg $sec $title\n");
      undef $queuefile;

      rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Re-Queueing existing track: ' . $title);
      $discord->send_message( $$config{discord}{linkchan}, ':musical_note: `' . $title . '` was added to the :radio: queue' );
      return;
   }

   my $json_v = get("https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=$vid&key=$$config{radio}{yt_api_key}");

   if ($json_v)
   {
      $details = decode_json($json_v);
   }
   else
   {
      rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Error querying YouTube API ' . "\N{U+1F61E}");
      return;
   }

   if (scalar $$details{items}->@* > 0)
   {
      $$details{items}[0]{contentDetails}{duration} =~ s/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/$sec = ($1 ? $1 * 60 * 60 : 0) + ($2 ? $2 * 60 : 0) + ($3 ? $3 : 0)/eg;

      if (!$sec || $sec > 900)
      {
         rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Track too long. Max. length: 15min' . "\N{U+1F61E}");
         return;
      }
   }
   else
   {
      rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Error querying details ' . "\N{U+1F61E}");
      return;
   }

   say localtime(time) . ' ** YouTube: Processing: ' . $title;
   rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Processing: ' . $title);

   $loop->open_process(
      command => [$$config{radio}{youtube_dl}->@*, 'https://www.youtube.com/watch?v='.$vid],

      on_finish => sub ($process, $exitcode)
      {
         my $status = ($exitcode >> 8);

         unless ($status)
         {
            radioq_ytdl_to_xon($vid, $sec, $title);
         }
         else
         {
            say localtime(time) . ' ## YouTube: Error, youtube-dl failed for: ' . $title;
            rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Error downloading track: ' . $title);
         }
      },
   );

   return;
}

sub radioq_ytdl_to_xon ($vid, $sec, $title)
{
   $loop->open_process(
      command => ['zip', '-9', '-j', '-q', "$$config{radio}{tempdir}/$$config{radio}{prefix}$vid.pk3", "$$config{radio}{tempdir}/$vid.ogg"],

      on_finish => sub ($process, $exitcode)
      {
         my $status = ($exitcode >> 8);

         unless ($status)
         {
            unlink "$$config{radio}{tempdir}/$vid.ogg";

            my $pk3 = "$$config{radio}{prefix}$vid.pk3";
            move("$$config{radio}{tempdir}/$pk3", "$$config{radio}{webdir}/$pk3");

            my $file = IO::File->new($$config{radio}{queuefile}, '>>:encoding(UTF-8)');
            $file->print("$pk3 $vid.ogg $sec $title\n");
            undef $file;

            say localtime(time) . ' ** YouTube: Finished: ' . $title;
            rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Successfully queued: ' . $title . ' (Playtime: ' . duration($sec) . ')');
            $discord->send_message( $$config{discord}{linkchan}, ':musical_note: `' . $title . '` was added to the :radio: queue' );
         }
         else
         {
            say localtime(time) . ' ## YouTube: Error, zip failed for: ' . $title;
            rcon('sv_cmd ircmsg ^0[^1YouTube^0] ^7Error creating pk3 for ' . $title);
         }
      },
   );

   return;
}
