# Two-Mac pool — setup

This pools **two of your Macs**: it moves Claude Code sessions between them for more RAM and compute, keeps a shared
filespace so a session can run on either, prefers a Thunderbolt cable when one is plugged in (Wi-Fi otherwise), and
shows both Macs in one menu bar. One Mac **travels** with you; the other **stays** put (always on).

Everything runs on your Macs and over SSH between them. Nothing is sent anywhere else.

Run `./setup.sh` on **both** Macs with the same answers, then do the four steps below once. `pool doctor` tells you
what's still missing at any point.

## 1. SSH between the Macs

Each Mac needs to reach the other by an SSH alias with key auth. In `~/.ssh/config` on **each** Mac, add both hosts
(use the aliases you chose in setup):

```
Host studio
  HostName <stay-LocalHostName>.local
  User <you>
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
  ServerAliveInterval 5
  ServerAliveCountMax 3

Host laptop
  HostName <travel-LocalHostName>.local
  User <you>
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
  ServerAliveInterval 5
  ServerAliveCountMax 3
```

Turn on **Remote Login** (System Settings → General → Sharing) on both Macs, then exchange keys:

```sh
ssh-keygen -t ed25519        # if you don't have a key yet
ssh-copy-id studio           # from the travel Mac
ssh-copy-id laptop           # from the stay Mac
ssh studio echo ok           # should print ok with no password
```

**Thunderbolt cable (optional, recommended):** connect the two Macs with a cable and enable **Thunderbolt Bridge**
(System Settings → Network). `peer-route` (the SSH `ProxyCommand`, installed for you) then uses the cable's
link-local address when it's plugged in and falls back to the LAN otherwise. ~145 MB/s and 0.5 ms on the cable vs a
few MB/s on Wi-Fi.

## 2. File sync (Mutagen)

Sessions move by restarting on the other Mac, so both Macs need the same files. Install Mutagen and create one
two-way sync of your project root (and, if you like, your Claude history so moved sessions keep their transcripts):

```sh
brew install mutagen-io/mutagen/mutagen
mutagen sync create --name=project --sync-mode=two-way-resolved \
  --ignore-vcs --ignore='node_modules/' --ignore='.venv/' --ignore='__pycache__/' \
  --ignore='.next/' --ignore='.turbo/' --ignore='dist/' --ignore='build/' --ignore='.DS_Store' \
  <your-sync-root> studio:<your-sync-root>
```

Run that **on the travel Mac** (its Mutagen daemon drives the sync). `mutagen sync list` shows health;
`mutagen daemon start` after a reboot. Keep build output and caches in the ignores — syncing them is most of the
cost. Don't work in the same checkout from both Macs at once.

When the cable is plugged in or pulled, the pool daemon moves the syncs to the new route **one at a time**: each
reconnect starts a fresh Mutagen agent on the stay Mac, which re-scans its whole folder, and doing them all at once
can peg that Mac. On a pull the syncs are paused and come back smallest first, each once the previous one has
settled; `pool` shows which are still waiting. Mutagen's agents (stay Mac) and daemon (travel Mac) also run at
lowered priority, so a re-scan gives way to your own work.

## 3. Background agents (launchd)

On the **travel Mac**, keep the pool daemon running (it measures both Macs, rebalances, and settles sync conflicts).
Save as `~/Library/LaunchAgents/pool.daemon.plist` and `launchctl load` it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>pool.daemon</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>REPLACE_HOME/.local/bin/pool</string><string>daemon</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>REPLACE_HOME</string>
    <key>PATH</key><string>REPLACE_HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>REPLACE_HOME/.local/state/pool/daemon.log</string>
  <key>StandardErrorPath</key><string>REPLACE_HOME/.local/state/pool/daemon.log</string>
</dict></plist>
```

```sh
sed -i '' "s#REPLACE_HOME#$HOME#g" ~/Library/LaunchAgents/pool.daemon.plist
launchctl load ~/Library/LaunchAgents/pool.daemon.plist
```

On the **stay Mac**, moving sessions onto it needs a tmux server started from its login session (so resumed sessions
can read the keychain). Start one once per boot from a Terminal window on that Mac:

```sh
tmux -L pool new -d -s pool-home
```

(or a launchd agent that runs `tmux -L pool -D`). The menu bar app starts one too when it's running.

## 4. Check it

```sh
pool doctor        # on each Mac: config, ssh, cable, sync, services
pool               # a status line for both Macs
pool top           # the live monitor
pool route         # which connection uses the cable vs Wi-Fi
```

## Tiers

Tag a session so it runs where you want (menu bar, the monitor's `t` key, or `pool tier <id> home|float|stay`):

- **home** — keep it on the **travel** Mac (it goes home with you).
- **stay** — run it on the **stay** Mac (low-priority / always-on work).
- **float** — wherever there's room (the default).

Everything else is automatic: when a Mac passes its ceiling or the two drift more than ~35 points apart, float work
moves to the other; idle sessions and leftover processes are offered for closing; a busy task that the other Mac
would run faster is offered to move "for more power".

## Benchmark (optional)

Setup writes a neutral speed of 1.0 for both Macs. If they differ a lot (e.g. an M1 vs an M4), measure real per-core
speed so balancing weighs cores correctly — edit the `"speed"` values in `~/.config/pool/pool.json` (first number =
per-core speed relative to the other Mac; second = how fast the efficiency cores are relative to the performance
cores). A quick proxy: `sysctl -n machdep.cpu.brand_string` and a single-core timing of `python3 -c 'import time;t=time.time();sum(range(50_000_000));print(time.time()-t)'` on each Mac.
