![Erebus](https://i.imgur.com/atLvzgy.png "Erebus")

# Erebus
Discord <-> Xonotic
## Features
- Link a Discord channel to a Xonotic server
- Bi-directional chat relaying
- End-Match scoreboard
- Commands
  - `!status`
  - `!xonstat <id>`
  - `!rcon <cmd>` (for owner only)
## Advanced Features
- Adding tracks from YouTube in-game to SMB Mod Radio (needs `web/radio.cgi` & more, look for yourself in `erebus.pl`)
## Caveats
Using `rcon changelevel` or `rcon restart` from the Xonotic client (or any client?) causes the server not to send UDP logs to Erebus for a short while, making it miss required log lines and thus breaking most features until the next automatic match end/restart, see https://gitlab.com/xonotic/darkplaces/-/issues/208
To work around that, don't use those 2 commands from the client and if you should need them, create aliases **in the server** (`server.cfg`) so that the server locally execs those commands:
```cfg
alias chlvl "sv_cmd changelevel ${* ?}"
alias rr "sv_cmd restart"
```
Then, only use the aliases via rcon.

---
![lol](https://i.imgur.com/n43mzor.png "lol")
![scores](https://i.imgur.com/Prg4JeL.png "scores")
[![Video](https://i.imgur.com/bkdsDpu.jpg)](https://www.youtube.com/watch?v=ZO4JE9pNcAk)
