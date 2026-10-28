"""Per-setup config for the two-Mac pool: which two Macs, their labels/ssh aliases/speed/ceilings, the synced project
root, which Mac runs tests, the folders that never move, and an optional always-on service to protect. pool and
pool-top read everything here, so the same code runs for anyone — a user drops in their own ~/.config/pool/pool.json
(written by `pool setup`) and nothing in the code changes.

The DEFAULT below is a neutral example used when no pool.json exists; `pool setup` replaces it with your two Macs.

Roles, not product names: one Mac "travels" (it goes home with you — work tagged to stay with you runs here) and one
"stays" (always on, e.g. at an office; it can host an always-on service and runs the test databases). Internally the
travel Mac is still called M5 and the stay Mac OLD, but those are only keys; the labels you see come from config.
"""
import json
import os
from pathlib import Path

HOME = str(Path.home())
CONFIG = Path(HOME, ".config/pool/pool.json")

# A neutral example, and the default when there is no pool.json. Replace it by running `pool setup`.
REFERENCE = {
    "travel": {"host": "travel-mac", "label": "Laptop", "name": "the laptop", "short": "laptop", "alias": "laptop",
               "color": "blue", "speed": [1.0, 0.5], "ceiling": 0.85},
    "stay": {"host": "stay-mac", "label": "Desktop", "name": "the desktop", "short": "desktop", "alias": "desktop",
             "color": "orange", "speed": [1.0, 0.5], "ceiling": 0.75},
    "sync_root": "~/code",
    "tests_on": "stay",
    "pinned": [],
    "always_on": None,
}


def _expand(p):
    return os.path.expanduser(p) if isinstance(p, str) else p


def load():
    """The full config as a flat dict of what pool/pool-top need, merging pool.json over the reference defaults."""
    try:
        user = json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        user = {}
    c = dict(REFERENCE)
    for side in ("travel", "stay"):
        c[side] = {**REFERENCE[side], **(user.get(side) or {})}
    for k in ("sync_root", "tests_on", "pinned"):
        if k in user:
            c[k] = user[k]
    c["always_on"] = user["always_on"] if "always_on" in user else REFERENCE["always_on"]

    t, s = c["travel"], c["stay"]
    root = _expand(c["sync_root"])
    conf = {
        "travel_host": t["host"], "stay_host": s["host"],
        "sync_root": root,
        "names": {t["host"]: t["name"], s["host"]: s["name"]},
        "labels": {t["host"]: t["label"], s["host"]: s["label"]},
        "colors": {t["label"]: t.get("color", "blue"), s["label"]: s.get("color", "orange")},
        "short": {t["short"]: t["host"], s["short"]: s["host"]},
        "short_of": {t["host"]: t["short"], s["host"]: s["short"]},
        "alias": {t["host"]: t["alias"], s["host"]: s["alias"]},
        "speed": {t["host"]: tuple(t["speed"]), s["host"]: tuple(s["speed"])},
        "ceiling": {t["host"]: t["ceiling"], s["host"]: s["ceiling"]},
        "tests_on": {s["host"] if c["tests_on"] == "stay" else t["host"]},
        "pinned": [root + "/" + d for d in c["pinned"]],
        "always_on": None,
    }
    if c["always_on"]:
        a = c["always_on"]
        conf["always_on"] = {"label": a["label"], "state": _expand(a.get("state") or ""), "name": a.get("name", "the service"),
                             "log": _expand(a["log"]) if a.get("log") else None}
        # the always-on service's own folder is pinned too, if it lives under the sync root
    return conf


CONF = load()
