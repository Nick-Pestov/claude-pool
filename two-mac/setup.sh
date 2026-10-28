#!/bin/bash
# Two-Mac pool setup. Writes your ~/.config/pool/pool.json, installs the tools into ~/.local/bin, and builds the menu
# bar app. The parts that need both Macs and your sign-in - SSH keys, Mutagen file sync, the launchd agents - are
# guided at the end with the exact commands, because they can't be done safely without you. Run this on BOTH Macs.
#
# Everything here runs on your machines and over SSH between them. Nothing is sent anywhere else.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="$HOME/.local/bin"
cfg="$HOME/.config/pool"

ask() { local p="$1" d="$2" v; read -r -p "$p [$d]: " v; echo "${v:-$d}"; }

echo "Two-Mac pool setup"
echo
echo "This pools two of your Macs: it moves Claude Code sessions between them (for more RAM and compute), keeps a shared"
echo "filespace, and shows both in one menu bar. Run it on both Macs with the SAME answers."
echo

self="$(scutil --get LocalHostName)"
echo "This Mac's network name (LocalHostName) is: $self"
echo
echo "Which Mac travels with you (your laptop), and which stays put (always on, e.g. at an office)?"
travel_host="$(ask "  Travel Mac's LocalHostName" "$self")"
travel_label="$(ask "  Travel Mac's short label (shown in the menu bar)" "Laptop")"
travel_alias="$(ask "  SSH alias to reach the travel Mac" "laptop")"
travel_color="$(ask "  Travel Mac's colour (blue/orange/aqua/green/violet/red/yellow/magenta)" "blue")"
stay_host="$(ask "  Stay Mac's LocalHostName" "")"
[ -n "$stay_host" ] || { echo "The stay Mac's LocalHostName is required (run 'scutil --get LocalHostName' on it)."; exit 1; }
stay_label="$(ask "  Stay Mac's short label" "Studio")"
stay_alias="$(ask "  SSH alias to reach the stay Mac" "studio")"
stay_color="$(ask "  Stay Mac's colour" "orange")"
echo
sync_root="$(ask "Folder to keep in sync between the Macs (your code lives here)" "$HOME/dev")"
echo "Pinned folders never move off the stay Mac (always-on work, data that only lives there)."
pinned="$(ask "  Pinned folders under that root, comma-separated (blank for none)" "")"
echo
echo "Optional: an always-on service on the stay Mac to protect and keep room for (e.g. a bot). Blank to skip."
svc_label="$(ask "  Its launchd label" "")"

# build pinned JSON array
pinned_json="[]"
if [ -n "$pinned" ]; then
  pinned_json="[$(echo "$pinned" | sed 's/[[:space:]]//g; s/\([^,][^,]*\)/"\1"/g')]"
fi
always_json="null"
if [ -n "$svc_label" ]; then
  svc_state="$(ask "  Its state file (JSON of its sessions), blank if none" "")"
  svc_name="$(ask "  A name for it" "the service")"
  always_json="{\"label\": \"$svc_label\", \"state\": \"${svc_state}\", \"name\": \"$svc_name\"}"
fi

mkdir -p "$cfg"
cat > "$cfg/pool.json" <<EOF
{
  "travel": {"host": "$travel_host", "label": "$travel_label", "name": "the $travel_label", "short": "$(echo "$travel_label" | tr '[:upper:]' '[:lower:]')", "alias": "$travel_alias", "color": "$travel_color", "speed": [1.0, 0.5], "ceiling": 0.85},
  "stay":   {"host": "$stay_host", "label": "$stay_label", "name": "the $stay_label", "short": "$(echo "$stay_label" | tr '[:upper:]' '[:lower:]')", "alias": "$stay_alias", "color": "$stay_color", "speed": [1.0, 0.5], "ceiling": 0.75},
  "sync_root": "$sync_root",
  "tests_on": "stay",
  "pinned": $pinned_json,
  "always_on": $always_json
}
EOF
echo
echo "Wrote $cfg/pool.json"
echo "  (speed is set to a neutral 1.0 for both Macs; run 'pool bench' later to measure real per-core speed)"

# install the tools
mkdir -p "$bin"
for f in pool pool-top pool_config.py peer-route; do install -m 0755 "$here/$f" "$bin/$f"; done
echo "Installed pool, pool-top, pool_config.py, peer-route into $bin"

# menu bar app
if command -v swiftc >/dev/null; then
  read -r -p "Build the PoolBar menu bar app? [Y/n] " yn
  [[ "${yn:-y}" =~ ^[Nn]$ ]] || bash "$here/build-poolbar.sh"
fi

cat <<EOF

Done on this Mac. Now the steps that need both Macs (do them once, the SETUP.md has details):

  1. SSH between the Macs. Add to ~/.ssh/config on THIS Mac (and the mirror on the other):
       Host $stay_alias
         HostName $stay_host.local
         User $USER
       Host $travel_alias
         HostName $travel_host.local
         User $USER
     Then exchange keys:  ssh-keygen (if needed) and ssh-copy-id $stay_alias  /  $travel_alias
     Check:  ssh $stay_alias echo ok

  2. File sync (Mutagen). Install it ('brew install mutagen-io/mutagen/mutagen') and create one sync of your
     project root between the Macs. See SETUP.md for the exact 'mutagen sync create' command and the ignores.

  3. Background services. On the travel Mac, load the pool daemon launchd agent (SETUP.md has the plist).

  4. Run 'pool doctor' on each Mac - it tells you what's still missing.
EOF
