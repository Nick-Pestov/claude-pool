"""Tests for claude-pool's logic: what counts as a leftover, the cleanup list, close-spec parsing, formatting."""
import importlib.machinery
import os
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cp = importlib.machinery.SourceFileLoader("claude_pool", os.path.join(HERE, "bin", "claude-pool")).load_module()
GB, MB = cp.GB, cp.MB
results = []


def check(name, cond):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name)


# --- formatting
check("gb: under a gig in MB", cp.gb(300 * MB) == "300 MB" and cp.gb(int(1.5 * GB)) == "1.5 GB")
check("cores: two decimals under one, one above", cp.cores(0.04) == "0.04" and cp.cores(1.6) == "1.6")
check("ago: scales", cp.ago(30) == "now" and cp.ago(3600) == "1h" and cp.ago(90000) == "1d" and cp.ago(None) == "?")
check("short: truncates with an ellipsis", cp.short("abcdefgh", 5) == "abcd…" and cp.short("ab", 5) == "ab")

# --- describe: names what runs, not the shell around it
snap = "/bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'pnpm dev'"
check("describe: lists the real runtimes",
      cp.describe([1, 2, 3], {1: snap, 2: "node lib/apiserver.cjs x.json", 3: "/x/chrome-headless-shell --headless"})
      == "node apiserver.cjs, chrome-headless-shell")
check("describe: a bare loop", cp.describe([1, 2], {1: snap, 2: "sleep 2"}) == "a shell loop left by a Claude session")

# --- find_leftovers: which adopted processes are offered
cp.config = lambda: {"close_idle_hours": 24, "leftover_min_minutes": 10, "protect": ["keep-me"]}
s = cp.Sampler.__new__(cp.Sampler)
s.cfg = cp.config()
now = 1_000_000.0
# procs: pid -> (ppid, cpu_s, rss, exe, age_s)
procs = {
    1: (0, 0, 0, "/sbin/launchd", 10 ** 7),
    100: (1, 5.0, 200 * MB, "node", 3600),                 # adopted dev server, 1h old -> leftover
    101: (100, 1.0, 50 * MB, "node", 3600),                #   its child
    200: (1, 0.0, 10 * MB, "zsh", 3600),                   # adopted shell, but not a Claude snapshot -> skip
    300: (1, 0.0, 10 * MB, "zsh", 3600),                   # Claude Bash-tool shell loop -> leftover
    400: (1, 0.0, 30 * MB, "claude", 3600),                # Claude's own machinery -> never
    500: (1, 2.0, 80 * MB, "python3", 3600),               # protected by substring -> never
    600: (1, 9.0, 300 * MB, "node", 60),                   # too young (60s < 10min) -> skip
}
args = {100: "node /app/server.js", 101: "esbuild", 200: "/bin/zsh -il", 300: snap,
        400: "claude bg-spare --bg-spare x", 500: "python3 keep-me/run.py", 600: "node fresh.js"}
launchd = {1}
cp.sh = lambda cmd, timeout=30: (
    "\n".join(f"{p} {args.get(p,'')}" for p in sorted({100, 101, 200, 300, 400, 500, 600})) if "ps -o pid=,args=" in cmd
    else "")  # no lsof cwd in the test
# patch processes() inside find_leftovers via the passed procs; build tree/rate here
rate = {p: procs[p][1] / 3600 for p in procs}


def tree(root):
    kids = {}
    for pid, pp in ((p, procs[p][0]) for p in procs):
        kids.setdefault(pp, []).append(pid)
    out, todo = [], [root]
    while todo:
        p = todo.pop(); out.append(p); todo += kids.get(p, [])
    return out


found = {o["pid"]: o for o in s.find_leftovers(procs, rate, tree, launchd, now)}
check("leftover: an adopted dev server with its child", 100 in found and found[100]["n"] == 2)
check("leftover: a Claude Bash-tool shell loop", 300 in found)
check("leftover: not a plain adopted shell", 200 not in found)
check("leftover: never Claude's own machinery", 400 not in found)
check("leftover: never a protected process", 500 not in found)
check("leftover: not one younger than the floor", 600 not in found)
check("leftover: describe names the runtime", found[100]["what"].startswith("node server.js"))

# --- cleanup: idle sessions + leftovers, with specs
sample = {
    "sessions": [
        {"sid": "aaaa1111-x", "pid": 10, "id": "aaaa1111", "name": "old bg", "kind": "background", "status": "idle",
         "cwd": "/x", "cpu": 0.0, "rss": 300 * MB, "idle": 200000},
        {"sid": "bbbb2222-x", "pid": 11, "id": "", "name": "busy", "kind": "interactive", "status": "busy",
         "cwd": "/x", "cpu": 1.0, "rss": 2 * GB, "idle": 200000},
        {"sid": "cccc3333-x", "pid": 12, "id": "", "name": "idle tab", "kind": "interactive", "status": "idle",
         "cwd": "/x", "cpu": 0.0, "rss": 500 * MB, "idle": 100000},
        {"sid": "dddd4444-x", "pid": 13, "id": "dddd4444", "name": "fresh", "kind": "background", "status": "idle",
         "cwd": "/x", "cpu": 0.0, "rss": 100 * MB, "idle": 3600},
    ],
    "leftovers": [{"pid": 100, "start": 50, "age": 3600, "cpu": 0.5, "rss": GB, "cwd": "/x", "n": 2, "what": "node server.js"}],
}
items = cp.cleanup(sample)
labels = [i["label"] for i in items]
check("cleanup: day-idle sessions and leftovers, never busy or fresh ones",
      set(labels) == {"old bg", "idle tab", "node server.js"})
check("cleanup: biggest first", labels[0] == "node server.js")   # 1 GB
by = {i["label"]: i for i in items}
check("cleanup: a background session closes with claude stop (its short id rides along)",
      by["old bg"]["spec"] == "session|aaaa1111-x|10|background|aaaa1111" and by["old bg"]["closable"])
check("cleanup: an interactive idle session is listed but not closable from here",
      not by["idle tab"]["closable"] and "close its tab" in by["idle tab"]["note"])
check("cleanup: a leftover closes by pid and start time", by["node server.js"]["spec"] == "procs|100|50")

# --- close_one: refuses a reused pid, stops the right thing
cp.processes = lambda: {100: (1, 0.0, 0, "node", 3600)}
ok, msg = cp.close_one("procs|100|9999")   # start time mismatches -> treat as gone
check("close: refuses a pid whose start time doesn't match", ok and "already gone" in msg)
cp.sh = lambda cmd, timeout=30: "[]"        # claude agents returns nothing -> session already ended
ok, msg = cp.close_one("session|zzzz-x|10|background|zzzz")
check("close: a session that isn't live is reported as already ended", ok and "already ended" in msg)

# --- menu_state shape
msample = dict(sample, ts=now, chip="Apple M1", ncpu=10, clusters=[["P", [0]]], cores=[0.3] * 10,
               load=(2.0, 1.0, 1.0), mem={"total": 32 * GB, "used": 16 * GB, "swap": 0, "level": 50}, apps=[])
st = cp.menu_state(msample)
check("menu_state: title has cpu, mem and an idle count", st["title"]["pct"] == 30 and st["title"]["mem"] == 50
      and st["title"]["idle"] == 2)   # old bg + leftover are closable; idle tab isn't
check("menu_state: closeAll lists only the closable specs",
      st["closeAll"] == ["--close", "procs|100|50", "session|aaaa1111-x|10|background|aaaa1111"])

failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
