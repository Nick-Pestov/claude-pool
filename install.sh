#!/bin/bash
# claude-pool installer. Copies the tool into ~/.local/bin, writes a default config, and (optionally) builds the
# ClaudePool menu bar app. Everything it installs runs locally and reads only this Mac; nothing is sent anywhere.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="$HOME/.local/bin"
cfg="$HOME/.config/claude-pool"

say() { printf '  %s\n' "$1"; }

echo "claude-pool installer"
echo
echo "What this installs, all on this Mac:"
say "claude-pool   - a terminal monitor + the 'close what nobody is using' tool (~/.local/bin)"
say "ClaudePool.app  - an optional menu bar readout (~/Applications), only if you choose it below"
echo
echo "What it does: reads this Mac's CPU, memory and your Claude Code sessions (via the local 'claude' CLI)"
echo "and the processes they started. It never contacts the network and never sends anything anywhere."
echo

# prereqs
command -v python3 >/dev/null || { echo "error: python3 not found. Install it (e.g. 'xcode-select --install') and re-run."; exit 1; }
[ "$(uname)" = Darwin ] || { echo "error: claude-pool is macOS-only."; exit 1; }
if ! PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH" command -v claude >/dev/null; then
  echo "warning: the Claude Code CLI ('claude') isn't on PATH. The monitor still runs but won't list sessions"
  echo "         until Claude Code is installed. See https://docs.claude.com/claude-code"
  echo
fi

# install the scripts
mkdir -p "$bin"
install -m 0755 "$here/bin/claude-pool" "$bin/claude-pool"
install -m 0644 "$here/bin/monitor_tui.py" "$bin/monitor_tui.py"
say "installed $bin/claude-pool"

# default config, kept if it already exists
mkdir -p "$cfg"
if [ ! -f "$cfg/config.json" ]; then
  cat > "$cfg/config.json" <<'EOF'
{
  "close_idle_hours": 24,
  "leftover_min_minutes": 10,
  "protect": []
}
EOF
  say "wrote default config $cfg/config.json"
else
  say "kept your existing config $cfg/config.json"
fi

# PATH hint
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo; echo "note: $bin isn't on your PATH. Add this to your shell profile:"; echo "      export PATH=\"\$HOME/.local/bin:\$PATH\"";;
esac

# optional menu bar app
echo
read -r -p "Build the ClaudePool menu bar app too? [y/N] " yn
if [[ "${yn:-}" =~ ^[Yy]$ ]]; then
  if command -v swiftc >/dev/null; then
    bash "$here/menubar/build.sh"
    say "launch it now with: open ~/Applications/ClaudePool.app"
    say "to start it at login, add it in System Settings > General > Login Items"
  else
    echo "  swiftc not found (install Xcode command line tools: xcode-select --install), skipping ClaudePool."
  fi
fi

echo
echo "Done. Try it:"
say "claude-pool          # the live monitor"
say "claude-pool --once   # a one-shot snapshot"
say "claude-pool doctor   # check the setup"
