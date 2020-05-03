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
# sv_logscores_bots 1
# rcon_secure 1
# rcon_password <pass>

# TODO:
# - discord2rcon
# - endmatch statistics

use v5.16.0;

use utf8;
use strict;
use warnings;

use lib '/etc/perl';

no warnings 'experimental::smartmatch';

binmode( STDOUT, ":encoding(UTF-8)" );

#use Data::Dumper;
use Mojo::Discord;
use IO::Async::Loop::Mojo;
use IO::Async::Socket;
use Digest::HMAC;
use Digest::MD4;
use MaxMind::DB::Reader;
use Encode::Simple qw(encode_utf8 decode_utf8);
use LWP::Simple qw($ua get);
use JSON;

$ua->agent( 'Mozilla/5.0' );
$ua->timeout( 6 );

my $self;

my $config = {
   game  => 'Xonotic @ twlz',
   chan  => 706113584626663475,
   remip => '2a02:c207:3003:5281::1',
   locip => undef, # undef = $remip
   port  => 26000, # local port += 444
   pass  => '',
   geo   => '/home/k/GeoLite2-City.mmdb',
   debug => 0,

   discord => {
      client_id => ,
      owner_id  => 373912992758235148,
   }
};

my $discord = Mojo::Discord->new(
   'version'   => 9999,
   'url'       => 'https://xonotic.lifeisabug.com',
   'token'     => '',
   'name'      => 'Erebus',
   'reconnect' => 1,
   'verbose'   => 0,
   'logdir'    => "$ENV{HOME}/.xonotic",
   'logfile'   => 'discord.log',
   'loglevel'  => 'info',
   'rate_limits' => 0, # until Mojo::Discord is fixed
);

my $modes = {
   'AS'   => 'Assault',
   'CA'   => 'Clan Arena',
   'COOP' => 'Cooperative',
   'CQ'   => 'Conquest',
   'CTF'  => 'Capture the Flag',
   'CTS'  => 'Race - Complete the Stage',
   'DM'   => 'Deathmatch',
   'DOM'  => 'Domination',
   'DUEL' => 'Duel',
   'FT'   => 'Freeze Tag',
   'INF'  => 'Infection',
   'INV'  => 'Invasion',
   'JB'   => 'Jailbreak',
   'KA'   => 'Keepaway',
   'KH'   => 'Key Hunt',
   'LMS'  => 'Last Man Standing',
   'NB'   => 'Nexball',
   'ONS'  => 'Onslaught',
   'RACE' => 'Race',
   'TDM'  => 'Team Deathmatch',
};

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

###

my $gi = MaxMind::DB::Reader->new(file => $$config{'geo'});

discord_on_ready();
discord_on_message_create();

$discord->init();

my ($map, $bots, $players, $type, $maptime) = ('', 0);

my $xonstream = IO::Async::Socket->new(
   on_recv => sub {
      my ( $self, $dgram, $addr ) = @_;

      $dgram =~ s/(?:\377){4}n//g;
      $dgram =~ s/\^(\d|x[\dA-Fa-f]{3})//g;

      while( $dgram =~ s/^(.*)\n// )
      {
         my $line = decode_utf8($1);

         next unless (substr($line, 0, 1) eq ':');
         substr($line, 0, 1, '');

         say "Received line: $line" if $$config{debug};

         my ($msg, $delaydelete);
         my @info = split(':', $line);

         given ( $info[0] )
         {
            when ( 'join' )
            {
               $info[3] =~ s/_/:/g;

               $$players{$info[1]}{slot} = $info[2];
               $$players{$info[1]}{ip}   = $info[3];
               $$players{$info[1]}{name} = qfont_decode(join('', @info[4..$#info]));

               unless ($info[3] eq 'bot')
               {
                  my $r = $gi->record_for_address($$players{$info[1]}{ip});
                  $$players{$info[1]}{geo} = $r->{country}{iso_code} ? lc($r->{country}{iso_code}) : 'white';

                  $msg = 'has joined the game';
               }
               else
               {
                  $bots++;
               }
            }
            when ( 'part' )
            {
               $delaydelete = $info[1];

               unless (exists $$players{$info[1]} && $$players{$info[1]}{ip} eq 'bot')
               {
                  $msg = 'has left the game';
               }
               else
               {
                  $bots--;
               }
            }
            when ( 'chat' )
            {
               $msg = join('', @info[2..$#info]);
            }
            when ( 'chat_spec' )
            {
               $msg = '(spectator) ' . join('', @info[2..$#info]);
            }
            when ( 'name' )
            {
               $$players{$info[1]}{name} = join('', @info[2..$#info]);
            }
            when ( 'gamestart' )
            {
               ($players, $bots) = ({}, 0);

               if ($info[1] =~ /^([a-z]+)_(.+)$/) {
                  ($type, $map) = (uc($1), $2);
                  $discord->status_update( { 'name' => "$type on $map @ twlz Xonotic", type => 0 } );
               }
            }
            when ( 'startdelay_ended' )
            {
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
                         'value'  => $type,
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

                  push @{$$embed{'fields'}}, { 'name' => 'Bots', 'value' => $bots, 'inline' => \1, } if ($bots);

                  my $message = {
                     'content' => '',
                     'embed' => $embed,
                  };

                  $discord->send_message( $$config{chan}, $message );
               }
            }
            when ( 'team' )
            {
               $$players{$info[1]}{team} = $info[2];
            }
            when ( 'scores' )
            {
               if ($info[1] =~ /^([a-z]+)_(.+)$/)
               {
                  $maptime = $info[2];

                  $discord->status_update( { 'name' => "$1 on $2 @ twlz Xonotic", type => 0 } ) unless ($2 eq $map);
                  ($type, $map) = (uc($1), $2);

                  if (keys %$players > 0 && $type && $map)
                  {
                     my $p = (keys %$players) - $bots;

                     my ($sp, $sb) = ('', '');
                     $sp = 's' if ($p != 1);
                     $sb = 's' if ($bots != 1);

                     my $embed = {
                        'color' => '3447003',
                        'provider' => {
                           'name' => 'twlz',
                           'url' => 'https://xonotic.lifeisabug.com',
                         },
                         'fields' => [
                         {
                            'name'   => 'Info',
                            'value'  => $$modes{$type} . ' with ' . $p . ' player'.$sp . ($bots ? (' and ' . $bots . ' bot'.$sb) : '') . ' on ' . $map . ' finished after ' . duration($maptime),
                            'inline' => \0,
                         },
                         ],
                     };

                     my $message = {
                        'content' => '',
                        'embed' => $embed,
                     };

                     $discord->send_message( $$config{chan}, $message );
                  }
               }
            }
            when ( 'vote' )
            {
               if ($info[1] eq 'vcall')
               {
                  $info[1] = $info[2];
                  $msg = 'called a vote: ' . $info[3];
               }
            }
         }

         if ($msg)
         {
            return unless (exists $$players{$info[1]});

            $msg =~ s/\@+everyone/everyone/g;
            $msg =~ s/\@+here/here/g;
            $msg =~ s/$discord_markdown_pattern/\\$1/g;

            say localtime(time) . " -> <$$players{$info[1]}{name}> $msg";

            $$players{$info[1]}{name} =~ s/`//g;

            my $final = "`$$players{$info[1]}{name}`  $msg";

            $final =~ s/^/<:gtfo:603609334781313037> / if ($info[0] eq 'part');
            $final =~ s/^/<:NyanPasu:562191812702240779> / if ($info[0] eq 'join');

            $discord->send_message( $$config{chan}, ':flag_' . $$players{$info[1]}{geo} . ': ' . $final );
         }

         delete $$players{$delaydelete} if (defined $delaydelete);
      }
   },
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

sub discord_on_message_create
{
   $discord->gw->on('MESSAGE_CREATE' => sub
   {
      my ($gw, $hash) = @_;

      my $id = $hash->{'author'}->{'id'};
      my $author = $hash->{'author'};
      my $msg = $hash->{'content'};
      my $msgid = $hash->{'id'};
      my $channel = $hash->{'channel_id'};
      my @mentions = @{$hash->{'mentions'}};

      add_user($_) for(@mentions);

      unless ( exists $author->{'bot'} && $author->{'bot'} )
      {
         $msg =~ s/\@+everyone/everyone/g;
         $msg =~ s/\@+here/here/g;

         if ( $channel eq $$config{'chan'} )
         {
            $msg =~ s/`//g;
            $msg =~ s/%/%%/g;
            $msg =~ s/\R/ /g;
            $msg =~ s/<@!?(\d+)>/\@$self->{'users'}->{$1}->{'username'}/g; # user/nick, ! is quote
            $msg =~ s/<#(\d+)>/#$self->{'channelnames'}->{$1}/g; # channel
            $msg =~ s/<@&(\d+)>/\@$self->{'rolenames'}->{$1}/g; # role
            $msg =~ s/<(:.+:)\d+>/$1/g; # emoji

            return unless $msg;

            say localtime(time) . " <- <$$author{'username'}> $msg";

            toxon($msg);
         }
         elsif ( $msg =~ /^!(?:xon(?:stat)?s?|xs) (.+)/i && $channel ne $$config{chan} )
         {
            my ($qid, $stats);
            ($qid = $1) =~ s/[^0-9]//g;

            unless ($qid) {
               $discord->send_message( $channel, 'Invalid player ID');
               return;
            }

            my $xonstaturl = 'https://stats.xonotic.org/player/';
            my $json = get( $xonstaturl . $qid . '.json');

            if ($json) {
               $stats = decode_json($json);
            }
            else {
               $discord->send_message( $channel, 'No response from server; Correct player ID?');
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
#               'thumbnail' => {
#                  'url' => "https://cdn.discordapp.com/emojis/458355320364859393.png?v=1",
#                  'width' => 38,
#                  'height' => 38,
#               },
                'image' => {
                   'url' => "https://stats.xonotic.org/static/badges/$qid.png?" . time, # work around discord image caching
                   'width' => 650,
                   'height' => 70,
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
                    'name'   => 'Games Played',
                    'value'  => $games,
                    'inline' => \1,
                 },
                 {
                    'name'   => 'Favourite Map',
                    'value'  => sprintf('%s (%s)', $favmap, $favmapt),
                    'inline' => \1,
                 },
                 {
                    'name'   => 'Cap Ratio',
                    'value'  => $capr ? sprintf('%.2f', $capr) : '-',
                    'inline' => \1,
                 },
                 ],
            };

            my $message = {
               'content' => '',
               'embed' => $embed,
            };

            $discord->send_message( $channel, $message );

            # TODO: change to old syntax, the image embedding thing sucks
            # main::msg($target, "%s :: games: %d/%d/%d (%.2f%% win) :: k/d: %.2f (%d/%d)%s :: fav map: %s (%s) :: last played %s", $snick, $games, $win, $loss, $pct, $ratio, $kills, $deaths, ($elo && $elo ne 100) ? sprintf(' :: %s elo: %.2f (%d games%s)', $elot, $elo, $elog, $elot eq 'ctf' ? sprintf(', %.2f cr', $capr) : '' ) : '', $favmap, $favmapt, $last);
         }
      }
   });

   return;
}

sub toxon {
   my $msg = shift // return;

   # TODO :)

   #$xonstream->send($msg);

   return;
}

sub discord_on_ready
{
   $discord->gw->on('READY' => sub
   {
      my ($gw, $hash) = @_;
      add_me($hash->{'user'});
      $discord->status_update( { 'name' => $$config{'game'}, type => 0 } ) if ( $$config{'game'} );
   });

   return;
}

sub add_me
{
   my ($user) = @_;
   $self->{'id'} = $user->{'id'};
   add_user($user);

   return;
}

sub add_user
{
   my ($user) = @_;
   my $id = $user->{'id'};
   $self->{'users'}{$id} = $user;

   return;
}

sub add_guild
{
   my ($guild) = @_;

   $self->{'guilds'}{$guild->{'id'}} = $guild;

   foreach my $channel (@{$guild->{'channels'}})
   {
      $self->{'channels'}{$channel->{'id'}} = $guild->{'id'};
      $self->{'channelnames'}{$channel->{'id'}} = $channel->{'name'}
   }

   foreach my $role (@{$guild->{'roles'}})
   {
      $self->{'rolenames'}{$role->{'id'}} = $role->{'name'};
   }

   return;
}

sub qfont_decode {
   my $qstr = shift // '';
   my @chars;

   for (split('', $qstr)) {
      my $i = ord($_) - 0xE000;
      my $c = ($_ ge "\N{U+E000}" && $_ le "\N{U+E0FF}")
      ? $qfont_unicode_glyphs[$i % @qfont_unicode_glyphs]
      : $_;
      #printf "<$_:$c|ord:%d>", ord;
      push @chars, $c if defined $c;
   }

   return join '', @chars;
}

sub duration
{
   my $sec = shift || return 0;

   my @gmt = gmtime($sec);

   $gmt[5] -= 70;

   return ($gmt[7] ?  $gmt[7]                                          .'d' : '').
          ($gmt[2] ? ($gmt[7]                       ? ' ' : '').$gmt[2].'h' : '').
          ($gmt[1] ? ($gmt[7] || $gmt[2]            ? ' ' : '').$gmt[1].'m' : '').
          ($gmt[0] ? ($gmt[7] || $gmt[2] || $gmt[1] ? ' ' : '').$gmt[0].'s' : '');
}
