"""Tests for how two-mac/pool brings Mutagen's syncs back after a link change: one at a time, at lowered priority."""
import importlib.machinery
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
pool = importlib.machinery.SourceFileLoader("pool", os.path.join(HERE, "..", "two-mac", "pool")).load_module()
results = []


def check(name, cond):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name)


tmp = Path(tempfile.mkdtemp())
pool.STATE, pool.REROUTE_STATE, pool.HOLD = tmp, tmp / "reroute.json", tmp / "sync-hold.json"
pool.SELF, pool.PEER = pool.M5, pool.OLD
pool.log = lambda m: None
calls, killed, live = [], [], {"sessions": []}
pool.os.kill = lambda pid, sig: killed.append(pid)
pool.sync_sessions = lambda: live["sessions"]


def sess(name, n, status="watching", paused=False):
    return {"name": name, "status": status, "paused": paused,
            "alpha": {"connected": True, "files": n, "directories": 0}, "beta": {"connected": True}}


def run(a, **k):
    """Records each command; pausing and resuming change the fake session list the way Mutagen would."""
    calls.append(a)
    if a[:3] == ["mutagen", "sync", "pause"]:
        live["sessions"] = [{**x, "paused": True} if x["name"] in a[3:] else x for x in live["sessions"]]
    if a[:3] == ["mutagen", "sync", "resume"]:
        live["sessions"] = [{**x, "paused": False, "status": "connecting-alpha"} if x["name"] in a[3:] else x
                            for x in live["sessions"]]
    return type("R", (), {"returncode": 0, "stdout": ""})()


pool.subprocess = type("S", (), {"run": staticmethod(run), "PIPE": None})


def reset():
    calls.clear()
    killed.clear()
    for f in (pool.REROUTE_STATE, pool.HOLD):
        if f.exists():
            f.unlink()


# Two syncs, each over its own ssh, both on the cable.
PS = """ 200 100 /usr/bin/ssh -oConnectTimeout=5 desktop .mutagen/agents/0.18.1/mutagen-agent synchronizer
 201 200 nc 169.254.181.120 22
 210 100 /usr/bin/ssh -oConnectTimeout=5 desktop .mutagen/agents/0.18.1/mutagen-agent synchronizer
 211 210 nc 169.254.181.120 22
"""
on_cable = pool.peer_links(PS)
on_wifi = pool.peer_links(PS.replace("169.254.181.120", "192.168.1.20"))

# --- the cable pulled: pause them all, bring them back one by one, smallest first
reset()
live["sessions"] = [sess("project", 900000), sess("notes", 300), sess("scripts", 30000), sess("project-seed", 10)]
done = pool.reroute(links=on_cable, plugged=False, now=1000.0, sessions=live["sessions"])
pauses = [c for c in calls if c[:3] == ["mutagen", "sync", "pause"]]
resumes = [c for c in calls if c[:3] == ["mutagen", "sync", "resume"]]
check("pulled: every sync is paused, smallest first, but not a seeding one",
      pauses == [["mutagen", "sync", "pause", "notes", "scripts", "project"]])
check("pulled: the dead connections are dropped", sorted(killed) == [200, 210])
check("pulled: the smallest comes back at once, the rest wait",
      resumes == [["mutagen", "sync", "resume", "notes"]] and pool.held_syncs()["held"] == ["scripts", "project"])
check("pulled: says what it did", any("one at a time" in d for d in done) and any("notes comes back" in d for d in done))

calls.clear()
check("release: nothing while the last one is still re-scanning", pool.release_held(now=1100.0) == [] and not calls)
live["sessions"] = [{**x, "status": "watching"} if x["name"] == "notes" else x for x in live["sessions"]]
check("release: the next once it's back to watching",
      pool.release_held(now=1200.0) and calls[-1] == ["mutagen", "sync", "resume", "scripts"])
calls.clear()
check("release: never waits more than SETTLE_MAX on one",
      pool.release_held(now=1200.0 + pool.SETTLE_MAX + 1) and calls[-1] == ["mutagen", "sync", "resume", "project"]
      and pool.held_syncs()["held"] == [])
calls.clear()
check("release: nothing to do once all are back", pool.release_held(now=9000.0) == [] and not calls)

# --- a sync resumed by hand is no longer pool's to bring back
reset()
pool.HOLD.write_text(json.dumps({"held": ["notes", "project"], "at": 0}))
live["sessions"] = [sess("notes", 300), sess("project", 900000, paused=True)]
pool.release_held(now=2000.0)
check("release: skips a sync resumed by hand and brings back the next",
      calls == [["mutagen", "sync", "resume", "project"]])

# --- an interrupted pause still gets resumed: the held list is written before pausing
reset()


def interrupted(a, **k):
    calls.append(a)
    if a[:3] == ["mutagen", "sync", "pause"]:
        raise KeyboardInterrupt
    return type("R", (), {"returncode": 0, "stdout": ""})()


pool.subprocess = type("S", (), {"run": staticmethod(interrupted), "PIPE": None})
try:
    pool.hold_syncs([sess("notes", 300), sess("project", 900000)])
except KeyboardInterrupt:
    pass
check("hold: the list is saved before the pause, so the daemon can resume them",
      pool.held_syncs()["held"] == ["notes", "project"])
pool.subprocess = type("S", (), {"run": staticmethod(run), "PIPE": None})

# --- the cable plugged back in: one sync moves per pass, only once nothing is settling
reset()
live["sessions"] = [sess("notes", 300), sess("project", 900000)]
done = pool.reroute(links=on_wifi, cable="169.254.181.120", plugged=True, now=3000.0, sessions=live["sessions"])
check("plugged: exactly one sync moves", len(killed) == 1 and any("1 more to follow" in d for d in done))
check("plugged: nothing is paused (the rest keep syncing over Wi-Fi)",
      not any(c[:3] == ["mutagen", "sync", "pause"] for c in calls))
reset()
pool.reroute(links=on_wifi, cable="169.254.181.120", plugged=True, now=4000.0,
             sessions=[sess("notes", 300, status="scanning"), sess("project", 900000)])
check("plugged: none moves while a sync is still settling", killed == [])
reset()
pool.HOLD.write_text(json.dumps({"held": ["project"], "at": 0}))
pool.reroute(links=on_wifi, cable="169.254.181.120", plugged=True, now=5000.0, sessions=live["sessions"])
check("plugged: none moves while held syncs are still coming back (they come back on the cable)", killed == [])
reset()

# --- agents start at lowered priority: the binary is wrapped once, atomically, and running ones are reniced
home = Path(tempfile.mkdtemp())
agent = home / ".mutagen/agents/0.18.1/mutagen-agent"
agent.parent.mkdir(parents=True)
agent.write_bytes(b"\xcf\xfa\xed\xfeBINARY")
pool.HOME = str(home)
PSP = """  123   0 .mutagen/agents/0.18.1/mutagen-agent synchronizer --log-level=info
  124  10 /x/.mutagen/agents/0.18.1/mutagen-agent.bin synchronizer --log-level=info
  125   0 /opt/homebrew/bin/mutagen daemon run
  126   0 /usr/bin/ssh -oConnectTimeout=5 desktop .mutagen/agents/0.18.1/mutagen-agent synchronizer
"""


def run_ps(a, **k):
    calls.append(a)
    return type("R", (), {"returncode": 0, "stdout": PSP if a[0] == "ps" else ""})()


pool.subprocess = type("S", (), {"run": staticmethod(run_ps), "PIPE": None})
pool.sync_priority()
script = agent.read_text()
check("priority: the agent becomes a wrapper that runs the real binary at utility QoS and nice 10",
      script.startswith("#!/bin/sh") and "taskpolicy -c utility" in script and "nice -n 10" in script
      and str(agent.with_name("mutagen-agent.bin")) in script and os.access(agent, os.X_OK))
check("priority: the real binary is kept as mutagen-agent.bin",
      agent.with_name("mutagen-agent.bin").read_bytes().startswith(b"\xcf\xfa"))
check("priority: running agents and the daemon are reniced, not ssh's command line or ones already low",
      sorted(c[3] for c in calls if c[0] == "renice") == ["123", "125"])
pool.sync_priority()
check("priority: a wrapped agent isn't wrapped again", agent.read_text() == script
      and agent.with_name("mutagen-agent.bin").read_bytes().startswith(b"\xcf\xfa"))

failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
