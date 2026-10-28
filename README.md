# claude-pool

See what every Claude Code session costs on your Mac, and close what nobody is using.

If you run several Claude Code sessions at once, it's hard to tell which ones are busy, how much memory they're
holding, or what they've left running in the background. `claude-pool` shows all of that in one place and lets you
reclaim what's idle — without losing any conversations.

```
 claude-pool  M1 Pro · 17:06:14                                    x close · X close all idle · q quit

 CPU ████████░░░░░░░░░░░░░░░░░░░░   29% busy · 10 cores · load 17.2
 cores Perf ▄▃▂▂ ▂▁▁▁ Effi ▆▆
 RAM ████████████████████████░░░░  27.1/32 GB · swap 3.4 GB · ● memory ok (54% free)

   session  name                                       state    CPU      RAM   idle
 › 1dc36b00 [Machine monitor] - Packaging for sharing  busy    0.05   1.0 GB    now
   201d303d [Sales assistant] - Nit pass on PR 170     busy    0.02   237 MB    49m
   7413cbde [Account notes] - Failed PR checks         idle    0.01   204 MB     1d

 Idle, nobody using it  · X closes all · select a session and press x
  ✕ [Account notes] - Failed PR checks       idle 1d, 204 MB · conversation kept: claude attach 7413cbde
  ✕ node apiserver.cjs, chrome-headless-shell  no session, running 2d, 118 MB · in ~/dev/app
```

## What it shows

- **Per-core CPU and memory** for this Mac, read straight from the kernel (no admin rights).
- **Every Claude Code session** with its real cost: the CPU and RAM of the whole process tree it started — its tools,
  MCP servers and shells — plus how long it's been idle.
- **What nobody is using**, ready to close:
  - **Idle sessions** — untouched for a day (24h by default). Closing one keeps its conversation; resume it later with
    `claude --resume` (or `claude attach` for background sessions).
  - **Leftover processes** — dev servers, test browsers, MCP servers and tool shells that macOS kept alive after the
    Claude session that started them ended.

## Privacy

Everything runs on your Mac and reads only your Mac. `claude-pool` makes no network connections and sends nothing
anywhere. It never reads the contents of your conversations — only their process stats and the last-modified time of
each session's transcript (to tell idle from active).

## Install

```sh
./install.sh
```

It copies `claude-pool` into `~/.local/bin`, writes a default config, and offers to build the optional **ClaudePool**
menu bar app. Then:

```sh
claude-pool          # the live monitor
claude-pool --once   # a one-shot snapshot
claude-pool doctor   # check the setup
```

Requires macOS and the [Claude Code CLI](https://docs.claude.com/claude-code). The monitor runs without it but won't
list sessions.

## The menu bar app (optional)

ClaudePool puts a small CPU/RAM readout in your menu bar, with a count of idle things you can close and a menu to close
them. Build it during install, or later with `menubar/build.sh`, then launch `~/Applications/ClaudePool.app` (add it to
Login Items to start it automatically).

## Keys in the monitor

| key | does |
|-----|------|
| `↑` `↓` | select a session |
| `x` | close the selected session (idle only; conversation kept) |
| `X` | close everything listed as idle |
| `q` | quit |

## Config

Optional, at `~/.config/claude-pool/config.json`:

```json
{
  "close_idle_hours": 24,
  "leftover_min_minutes": 10,
  "protect": ["my-always-on-server"]
}
```

- **close_idle_hours** — how long a session must be idle before it's offered for closing.
- **leftover_min_minutes** — how long a leftover process must have run before it's offered.
- **protect** — substrings; any process whose command line or working folder contains one is never offered for
  closing. Use it for long-running things you keep on purpose.

## What it never touches

Claude Code's own background machinery (the daemon, spare workers, PTY hosts), anything managed by `launchd`, and
anything matching a `protect` substring are never offered for closing.

---

## Two Macs: the pool

If you have a second Mac (an old laptop, a Mac mini at the office), the **two-Mac pool** in [`two-mac/`](two-mac/)
goes further: it moves Claude Code sessions between your two Macs for **more RAM and compute**, keeps a **shared
filespace** so a session runs on either, prefers a **Thunderbolt cable** when plugged in (Wi-Fi otherwise), and shows
both Macs in one menu bar. One Mac travels with you; the other stays put.

Set it up with [`two-mac/setup.sh`](two-mac/setup.sh) on both Macs, then follow the four steps in
[`two-mac/SETUP.md`](two-mac/SETUP.md) (SSH, file sync, launchd — the parts that need both Macs and your sign-in).
`pool doctor` checks it. It's config-driven: your two Macs, their labels, ssh aliases and roles live in
`~/.config/pool/pool.json`, so the same code runs for anyone.

More involved than the single-Mac tool, and it needs a second Mac — but it's the part that actually gives you extra
RAM and usage.
