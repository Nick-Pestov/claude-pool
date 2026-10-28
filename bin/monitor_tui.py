"""The `claude-pool` live monitor (curses). Single Mac: per-core CPU, memory, Claude Code sessions, and the idle
sessions / leftover processes you can close. Kept separate from claude-pool so the CLI stays importable for tests."""
import curses
import locale
import os
import threading
import time

GB, MB = 1024 ** 3, 1024 ** 2
BLOCKS = "▁▂▃▄▅▆▇█"


def gb(n):
    return f"{n / GB:.1f} GB" if n >= GB else f"{n / MB:.0f} MB"


def coresf(n):
    return f"{n:.2f}" if n < 0.995 else f"{n:.1f}"


def ago(secs):
    if secs is None:
        return "?"
    if secs < 60:
        return "now"
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= size:
            return f"{int(secs // size)}{unit}"
    return "now"


def short(text, n):
    return text if len(text) <= n else text[: n - 1] + "…"


class Monitor:
    def __init__(self, scr, Sampler, cleanup, close):
        self.scr, self.cleanup, self.close = scr, cleanup, close
        self.sample = None
        self.sampler = Sampler()
        self.sampler.sample()
        self.sel, self.top = 0, 0
        self.confirm = None          # (prompt, run) waiting for y/n
        self.msg, self.msg_at = "", 0.0
        self.rows, self.row_y = [], {}
        threading.Thread(target=self.loop, daemon=True).start()
        self.colors()

    def loop(self):
        while True:
            try:
                self.sample = self.sampler.sample()
            except Exception:
                pass
            time.sleep(2)

    def colors(self):
        curses.start_color()
        try:
            curses.use_default_colors()
            bg = -1
        except curses.error:
            bg = curses.COLOR_BLACK
        many = curses.COLORS >= 256
        n = [0]

        def pair(fg, fallback):
            n[0] += 1
            curses.init_pair(n[0], fg if many else fallback, bg)
            return curses.color_pair(n[0])

        self.c = {"accent": pair(68, curses.COLOR_CYAN), "muted": pair(245, curses.COLOR_WHITE),
                  "faint": pair(240, curses.COLOR_WHITE), "ok": pair(71, curses.COLOR_GREEN),
                  "warn": pair(178, curses.COLOR_YELLOW), "bad": pair(167, curses.COLOR_RED)}
        if not many:
            self.c["faint"] |= curses.A_DIM
            self.c["muted"] |= curses.A_DIM

    def put(self, y, x, text, attr=0):
        h, w = self.scr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return x
        text = text[: max(0, w - x - (1 if y == h - 1 else 0))]
        try:
            self.scr.addstr(y, x, text, attr)
        except curses.error:
            pass
        return x + len(text)

    def say(self, m):
        self.msg, self.msg_at = m, time.time()

    def bar(self, y, x, frac, width, attr):
        filled = max(0, min(width, int(round(frac * width))))
        for i in range(width):
            self.put(y, x + i, "█" if i < filled else "░", attr if i < filled else self.c["faint"])
        return x + width

    def draw(self):
        s = self.sample
        self.scr.erase()
        H, W = self.scr.getmaxyx()
        if not s:
            self.put(0, 0, "starting…")
            self.scr.refresh()
            return
        x = self.put(0, 1, "claude-pool", curses.A_BOLD)
        self.put(0, x, f"  {s['chip'].replace('Apple ', '')} · {time.strftime('%H:%M:%S')}", self.c["muted"])
        right = "x close · X close all idle · q quit"
        self.put(0, max(x + 2, W - len(right) - 1), right, self.c["muted"])
        busy = sum(s["cores"]) / len(s["cores"]) if s["cores"] else 0
        mem = s["mem"]
        # CPU line
        y = 2
        x = self.put(y, 1, "CPU ", self.c["muted"])
        x = self.bar(y, x, busy, 28, self.c["bad"] if busy >= 0.85 else self.c["accent"])
        x = self.put(y, x + 1, f" {busy:>4.0%} busy", curses.A_BOLD)
        self.put(y, x, f" · {len(s['cores'])} cores · load {s['load'][0]:.1f}", self.c["muted"])
        y += 1
        # per-core blocks
        x, last = self.put(y, 1, "cores ", self.c["muted"]), None
        for name, idx in s["clusters"]:
            if name != last:
                x = self.put(y, x, f"{name[:4]} ", self.c["faint"])
                last = name
            for i in idx:
                c = s["cores"][i] if i < len(s["cores"]) else 0
                x = self.put(y, x, BLOCKS[min(7, int(c * 8))] if c >= 0.03 else "▁",
                             self.c["accent"] if c >= 0.03 else self.c["faint"])
            x += 1
        y += 1
        # memory
        x = self.put(y, 1, "RAM ", self.c["muted"])
        x = self.bar(y, x, mem["used"] / mem["total"], 28, self.c["accent"])
        x = self.put(y, x + 1, f" {mem['used'] / GB:.1f}/{mem['total'] / GB:.0f} GB", curses.A_BOLD)
        state, col = (("ok", "ok") if mem["level"] >= 30 else ("tight", "warn") if mem["level"] >= 15 else ("low", "bad"))
        x = self.put(y, x, f" · swap {mem['swap'] / GB:.1f} GB · ", self.c["muted"])
        x = self.put(y, x, "● ", self.c[col])
        self.put(y, x, f"memory {state} ({mem['level']}% free)", self.c["muted"])
        y += 2

        items = self.cleanup(s)
        self.rows = sorted(s["sessions"], key=lambda z: (z["status"] != "busy", -z["cpu"]))
        # sessions table
        name_w = max(16, W - 60)
        self.put(y, 0, f"   {'session':9}{'name':<{name_w}} {'state':9}{'CPU':>5}{'RAM':>9}{'idle':>6}",
                 self.c["muted"] | curses.A_UNDERLINE)
        y += 1
        avail = H - y - (len(items[:6]) + 5)
        height = max(3, min(len(self.rows), avail))
        self.sel = max(0, min(self.sel, len(self.rows) - 1))
        if self.sel < self.top:
            self.top = self.sel
        if self.sel >= self.top + height:
            self.top = self.sel - height + 1
        close_keys = {i["spec"].split("|")[1] if i["kind"] == "session" else None for i in items if i["closable"]}
        self.row_y = {}
        for i, z in enumerate(self.rows[self.top:self.top + height]):
            n = self.top + i
            self.row_y[y] = n
            sel = curses.A_REVERSE if n == self.sel else 0
            self.put(y, 0, " " * (W - 1), sel)
            self.put(y, 1, "›" if n == self.sel else " ", sel)
            x = self.put(y, 3, z["sid"][:8], self.c["muted"] | sel)
            x = self.put(y, x + 1, f"{short(z['name'] or '(unnamed)', name_w):<{name_w}} ", sel)
            st = {"busy": curses.A_BOLD, "waiting": self.c["warn"]}.get(z["status"], self.c["muted"])
            x = self.put(y, x, f"{z['status']:<9}", st | sel)
            self.put(y, x, f"{coresf(z['cpu']):>5}{gb(z['rss']):>9}{ago(z['idle']):>6}", sel)
            y += 1
        y += 1
        # cleanup
        x = self.put(y, 1, "Idle, nobody using it", curses.A_BOLD)
        self.put(y, x, "  · X closes all · select a session above and press x", self.c["muted"])
        y += 1
        if not items:
            self.put(y, 3, "nothing — every session is active and no process is left without one", self.c["muted"])
            y += 1
        for i in items[:6]:
            x = self.put(y, 2, "✕ " if i["closable"] else "· ", self.c["warn"] if i["closable"] else self.c["muted"])
            x = self.put(y, x, f"{short(i['label'], 40):<40} ")
            self.put(y, x, f"{i['detail']} · {i['note']}", self.c["muted"])
            y += 1
        self.idle_items = items
        # footer
        self.draw_footer(H - 1, W)
        self.scr.refresh()

    def draw_footer(self, y, W):
        if self.confirm:
            self.put(y, 1, short(self.confirm[0] + "  y / n", W - 2), self.c["warn"] | curses.A_BOLD)
        elif self.msg and time.time() - self.msg_at < 8:
            self.put(y, 1, short(self.msg, W - 2), curses.A_BOLD)
        else:
            self.put(y, 1, "↑↓ select · x close selected · X close all idle · q quit", self.c["muted"])

    def selected(self):
        return self.rows[self.sel] if self.rows and 0 <= self.sel < len(self.rows) else None

    def key(self, k):
        if self.confirm:
            prompt, run = self.confirm
            self.confirm = None
            if k in (ord("y"), ord("Y")):
                threading.Thread(target=run, daemon=True).start()
            else:
                self.say("left it as it is")
            return True
        if k in (ord("q"), ord("Q")):
            return False
        if k in (curses.KEY_DOWN, ord("j")):
            self.sel += 1
        elif k in (curses.KEY_UP, ord("k")):
            self.sel = max(0, self.sel - 1)
        elif k == ord("x"):
            self.ask_close()
        elif k == ord("X"):
            self.ask_close_all()
        return True

    def ask_close(self):
        z = self.selected()
        if not z:
            return
        if z["status"] != "idle" or (z["idle"] or 0) < 86400:
            self.say("only sessions idle for a day are offered; this one is in use")
            return
        if z["kind"] != "background":
            self.say("interactive session — close its terminal tab to end it (its conversation is kept)")
            return
        spec = "|".join(["session", z["sid"], str(z["pid"]), z["kind"], z.get("id") or ""])
        self.confirm = (f"Close {z['sid'][:8]} “{short(z['name'], 36)}”? Its conversation is kept.",
                        lambda: self.run_close([spec], z["sid"][:8]))

    def ask_close_all(self):
        items = [i for i in getattr(self, "idle_items", []) if i["closable"]]
        if not items:
            self.say("nothing idle to close")
            return
        self.confirm = (f"Close {len(items)} idle things holding {gb(sum(i['rss'] for i in items))}? Conversations kept.",
                        lambda: self.run_close([i["spec"] for i in items], f"{len(items)} things"))

    def run_close(self, specs, label):
        ok, msg = self.close(specs)
        self.say(("" if ok else "some didn't close: ") + (msg or f"closed {label}"))

    def run(self):
        curses.curs_set(0)
        self.scr.keypad(True)
        self.scr.timeout(200)
        last = 0.0
        while True:
            if time.time() - last >= 1:
                self.draw()
                last = time.time()
            k = self.scr.getch()
            if k == -1:
                continue
            if k == curses.KEY_RESIZE:
                last = 0
                continue
            if not self.key(k):
                return
            self.draw()
            last = time.time()


def run(Sampler, cleanup, close):
    locale.setlocale(locale.LC_ALL, "")
    try:
        curses.wrapper(lambda scr: Monitor(scr, Sampler, cleanup, close).run())
    except KeyboardInterrupt:
        pass
