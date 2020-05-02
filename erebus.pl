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
# rcon_secure 1
# rcon_password <pass>

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
   ipv6  => 1,
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
   'CTS'  => 'Race - Complete The Stage',
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
   'TDM'  => 'Team Death Match',
};

#my $discord_markdown_pattern = qr/(?<!\\)(`|@|:|#|\||__|\*|~|>)/;
my $discord_markdown_pattern = qr/(?<!\\)(`|@|#|\||__|\*|~|>)/;

###

my ($players, $type, $map);

my $gi = MaxMind::DB::Reader->new(file => $$config{'geo'});

discord_on_ready();
discord_on_message_create();

$discord->init();

my $xonstream = IO::Async::Socket->new(
   on_recv => sub {
      my ( $self, $dgram, $addr ) = @_;

      $dgram =~ s/(?:\377){4}n//g;
      $dgram =~ s/\^(\d|x[\dA-Fa-f]{3})//g;

      while( $dgram =~ s/^(.*)\n// )
      {
         my $line = decode_utf8($1);

         next unless (substr($line, 0, 1) eq ':');
         substr($line, 0, 1) = '';

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
               $$players{$info[1]}{name} = join('', @info[4..$#info]);

               unless ($info[3] eq 'bot')
               {
                  my $r = $gi->record_for_address($$players{$info[1]}{ip});
                  $$players{$info[1]}{geo} = $r->{country}{iso_code} ? lc($r->{country}{iso_code}) : 'white';

                  $msg = "has joined the game";
               }
            }
            when ( 'part' )
            {
               $delaydelete = $info[1];
               $msg = "has left the game" unless (exists $$players{$info[1]} && $$players{$info[1]}{ip} eq 'bot');
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
               $info[1] =~ /^([a-z]+)_(.+)$/;
               ($type, $map) = (uc($1), $2);
               $discord->status_update( { 'name' => "$type on $map @ twlz Xonotic", type => 0 } );
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
                         'value'  => "$map ",
                         'inline' => \1,
                      },
                      {
                         'name'   => 'Players',
                         'value'  => keys %$players,
                         'inline' => \1,
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
            when ( 'team' )
            {
               $$players{$info[1]}{team} = $info[2];
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
      family   => $$config{ipv6} ? 'inet6' : 'inet',
      socktype => 'dgram',
      port     => $$config{port},
      ip       => $$config{remip},
   },
   local_addr => {
      family   => $$config{ipv6} ? 'inet6' : 'inet',
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
         elsif ( $msg =~ /^!xon(?:stat)?s? (.+)/i && $channel ne $$config{chan} )
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
               eval { $stats = decode_json($json) };
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

sub duration
{
   my $sec = shift || return 0;

   my @gmt = gmtime($sec);

   $gmt[5] -= 70;
   return   ($gmt[5] ?                                                       $gmt[5].'y' : '').
            ($gmt[7] ? ($gmt[5]                                  ? ' ' : '').$gmt[7].'d' : '').
            ($gmt[2] ? ($gmt[5] || $gmt[7]                       ? ' ' : '').$gmt[2].'h' : '').
            ($gmt[1] ? ($gmt[5] || $gmt[7] || $gmt[2]            ? ' ' : '').$gmt[1].'m' : '');
}
