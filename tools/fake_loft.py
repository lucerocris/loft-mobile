#!/usr/bin/env python3
"""A fake Loft server for testing Loft Mobile on the emulator. Never the real one.

Serves the flexible-organization contract (Loft docs/flex-contract.md):
snapshot with accounts, projects, groupBy and card.project, plus the project
routes. Binds 127.0.0.1 only; the emulator reaches it as 10.0.2.2:<port>.
Any bearer token is accepted.

    python3 tools/fake_loft.py --port 7731 --scenario freelancer
    curl -X POST 127.0.0.1:7731/__scenario/solo      # switch live (no auth, test only)
    curl 127.0.0.1:7731/__log                        # bodies the app sent
    python3 tools/fake_loft.py --dump freelancer     # print a snapshot (test fixture)

Scenarios: freelancer (2 accounts, 4 client projects, one on both accounts),
two-accounts (Work + Personal, grouped by account), solo (one account, no projects),
legacy (an older Loft: no accounts/projects/groupBy fields).
"""
import argparse
import copy
import json
import os
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NOW = datetime.now(timezone.utc)
HEX = {"blue": "#5B8DFF", "green": "#46C07D", "purple": "#A98BFF", "cyan": "#3EC1D3",
       "pink": "#F17DB8", "orange": "#F2924A", "yellow": "#E3CF5B", "red": "#F0685A"}


def ago(minutes):
    return (NOW - timedelta(minutes=minutes)).isoformat()


def acc(id, label, color, email="", default=False):
    return {"id": id, "label": label, "color": color, "hex": HEX[color], "email": email, "default": default}


def card(id, name, account, col, cwd, detail="", minutes=5, kind="agent", pinned=False, failed=False, result=""):
    return {"kind": kind, "id": id, "name": name, "account": account, "work": False, "col": col,
            "state": {"needs": "needs input", "running": "working", "todo": "todo", "done": "done"}[col],
            "detail": detail, "result": result, "cwd": cwd, "updated": ago(minutes), "live": col == "running",
            "pinned": pinned, "failed": failed, "links": []}


def usage(five, seven):
    return {"five": str(five), "seven": str(seven), "fiveReset": "", "sevenReset": "", "error": None}


SCENARIOS = {
    "freelancer": {
        "accounts": [acc("studio", "Studio", "blue", "me@studio.dev", True), acc("overflow", "Overflow", "purple", "overflow@studio.dev")],
        "usage": {"studio": usage(31, 22), "overflow": usage(64, 48)},
        "defaultAccount": "studio",
        "groupBy": "project",
        "projects": [
            {"id": "acme", "name": "Acme · website", "color": "cyan", "accounts": ["studio"], "defaultAccount": "studio", "folders": ["~/clients/acme-web"]},
            {"id": "northwind", "name": "Northwind · app", "color": "orange", "accounts": ["studio", "overflow"], "defaultAccount": "auto",
             "folders": ["~/clients/northwind-app", "~/clients/northwind-api"]},
            {"id": "bloom", "name": "Bloom · shop", "color": "pink", "accounts": ["overflow"], "defaultAccount": "overflow", "folders": ["~/clients/bloom-shop"]},
            {"id": "harbor", "name": "Harbor · API", "color": "green", "accounts": ["studio"], "defaultAccount": "studio", "folders": ["~/clients/harbor-api"]},
        ],
        "cards": [
            card("a0000001", "Checkout copy · review", "studio", "needs", "~/clients/acme-web", "Two headline options are ready. Which one?", 12),
            card("a0000002", "Hero images · compress", "studio", "running", "~/clients/acme-web", "Converting 48 images to AVIF", 0),
            card("a0000003", "Offline sync · tests", "overflow", "running", "~/clients/northwind-app", "Running the sync suite", 3),
            card("a0000004", "Push alerts · Android", "studio", "running", "~/clients/northwind-app", "Wiring the notification channel", 8),
            card("t0000005", "Release notes 2.4", "studio", "todo", "~/clients/northwind-api", "(no prompt yet)", 60, kind="todo"),
            card("a0000006", "Stripe webhooks · retry", "overflow", "needs", "~/clients/bloom-shop",
                 "Both retry schedules fit Stripe's limits. 3 tries clears most network blips; 5 also covers a short outage. Should failed webhooks retry 3 or 5 times?", 25),
            card("t0000007", "Rate limits · docs", "studio", "todo", "~/clients/harbor-api", "(no prompt yet)", 120, kind="todo"),
            card("a0000008", "Dotfiles · cleanup", "studio", "running", "~/dotfiles", "Sorting shell aliases", 5),
            card("a0000009", "Acme · sitemap", "studio", "done", "~/clients/acme-web", "", 600, result="Sitemap regenerated"),
        ],
        "assignments": {},
        "dirs": ["~/clients/northwind-app", "~/clients/acme-web", "~/clients/bloom-shop", "~/clients/harbor-api", "~/dotfiles"],
    },
    "two-accounts": {
        "accounts": [acc("work", "Work", "blue", "work@example.com"), acc("personal", "Personal", "green", "me@example.com", True)],
        "usage": {"work": usage(42, 15), "personal": usage(12, 78)},
        "defaultAccount": "personal",
        "groupBy": "account",
        "projects": [
            {"id": "dayjob", "name": "Day job", "color": "blue", "accounts": ["work"], "defaultAccount": "work", "folders": ["~/work"]},
        ],
        "cards": [
            card("b0000001", "Invoices · export diff", "work", "needs", "~/work/ops-tools", "I found why the totals don't match. Fix both?", 47),
            card("b0000002", "Search · ranking weights", "work", "needs", "~/work/ops-tools", "Token expired: pick route a, b or c", 1),
            card("b0000003", "Reports · weekly board", "work", "running", "~/work/ops-tools", "Writing the board layout into the automation", 0, pinned=True),
            card("b0000004", "Notes · course outline", "personal", "needs", "~/notes", "Start the outline for weeks 3–5?", 12),
            card("b0000005", "Reader · long-press lookup", "personal", "running", "~/reader", "Running the emulator tests", 3),
            card("t0000006", "System · default model", "personal", "todo", "~/loft", "(no prompt yet)", 55, kind="todo"),
            card("b0000007", "Loft · board view", "personal", "done", "~/loft", "", 900, result="Board view merged"),
        ],
        "assignments": {},
        "dirs": ["~/work/ops-tools", "~/notes", "~/reader", "~/loft"],
    },
    "solo": {
        "accounts": [acc("main", "Main", "blue", "me@example.com", True)],
        "usage": {"main": usage(18, 9)},
        "defaultAccount": "main",
        "groupBy": "status",
        "projects": [],
        "cards": [
            card("c0000001", "Blog · RSS feed", "main", "needs", "~/code/blog", "The feed has 2 date formats. Keep RFC 822?", 6),
            card("c0000002", "Portfolio · dark mode", "main", "running", "~/code/portfolio", "Checking contrast on the cards", 0),
            card("c0000003", "CLI · release script", "main", "running", "~/code/cli", "Tagging v0.4.1", 4),
            card("t0000004", "Resume · update", "main", "todo", "~/docs/resume", "(no prompt yet)", 1440, kind="todo"),
            card("c0000005", "Blog · images", "main", "done", "~/code/blog", "", 2000, result="Images resized"),
        ],
        "assignments": {},
        "dirs": ["~/code/blog", "~/code/portfolio", "~/code/cli"],
    },
}
SCENARIOS["legacy"] = {"legacy": True, **copy.deepcopy(SCENARIOS["two-accounts"])}

LOCK = threading.Lock()
STATE = {"name": "", "s": None, "version": 0}
LOG = []


def load(name):
    with LOCK:
        STATE["name"] = name
        STATE["s"] = copy.deepcopy(SCENARIOS[name])
        STATE["version"] += 1


def bump():
    STATE["version"] += 1


def card_project(s, c):
    if c["id"] in s["assignments"]:
        return s["assignments"][c["id"]]
    best, best_len = None, -1
    for p in s["projects"]:
        for f in p["folders"]:
            f = f.rstrip("/")
            if (c["cwd"] == f or c["cwd"].startswith(f + "/")) and len(f) > best_len:
                best, best_len = p["id"], len(f)
    return best


def snapshot():
    s = STATE["s"]
    if s.get("legacy"):
        # Older Loft: work flag, usage keyed work/personal, project = folder name.
        cards = []
        for c in s["cards"]:
            c2 = {k: v for k, v in c.items() if k != "account"}
            c2["work"] = c["account"] == "work"
            c2["project"] = os.path.basename(c["cwd"]) or "~"
            cards.append(c2)
        return {"cards": cards, "usage": s["usage"], "dirs": s["dirs"], "doneDays": 3, "voice": False}
    cards = []
    for c in s["cards"]:
        c2 = dict(c)
        c2["work"] = c["account"] != s["defaultAccount"]
        c2["project"] = card_project(s, c)
        c2["folder"] = c["cwd"]
        cards.append(c2)
    projects = []
    for p in s["projects"]:
        n = sum(1 for c in cards if c["project"] == p["id"] and c["col"] != "done")
        projects.append({**p, "hex": HEX.get(p["color"], p["color"]), "count": n})
    return {"cards": cards, "usage": s["usage"], "accounts": s["accounts"], "defaultAccount": s["defaultAccount"],
            "setup": False, "dirs": s["dirs"], "doneDays": 3, "voice": False, "projects": projects, "groupBy": s["groupBy"]}


def resolve_account(s, body, project):
    want = (body.get("account") or "").strip()
    ids = [a["id"] for a in s["accounts"]]
    allowed = (project or {}).get("accounts") or ids
    if want and want != "auto" and want in ids:
        return want
    rule = want if want == "auto" else ((project or {}).get("defaultAccount") or "")
    if rule == "auto":
        def five(a):
            try:
                return int(s["usage"].get(a, {}).get("five"))
            except (TypeError, ValueError):
                return 1000
        return min(allowed, key=five)
    if rule in ids:
        return rule
    return s["defaultAccount"]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except Exception:
            return {}

    def _authed(self):
        if self.path.startswith("/__"):
            return True
        a = self.headers.get("Authorization") or ""
        if a.startswith("Bearer ") and len(a) > 8:
            return True
        self._json(401, {"error": "not paired"})
        return False

    def _legacy_404(self):
        if STATE["s"].get("legacy"):
            self._json(404, {"error": "not found"})
            return True
        return False

    def do_GET(self):
        if not self._authed():
            return
        if self.path == "/api/ping":
            return self._json(200, {"host": "fake-loft", "version": "test", "voice": False})
        if self.path == "/api/state":
            with LOCK:
                return self._json(200, snapshot())
        if self.path.startswith("/api/timeline/"):
            return self._json(200, [])
        if self.path == "/__log":
            return self._json(200, LOG[-50:])
        if self.path == "/api/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            seen = -1
            try:
                while True:
                    with LOCK:
                        v = STATE["version"]
                        snap = snapshot() if v != seen else None
                    if snap is not None:
                        seen = v
                        self.wfile.write(b"data: " + json.dumps(snap).encode() + b"\n\n")
                    else:
                        self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                return
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authed():
            return
        body = self._body()
        LOG.append({"method": "POST", "path": self.path, "body": body})
        parts = self.path.strip("/").split("/")
        if parts[0] == "__scenario":
            load(parts[1])
            return self._json(200, {"scenario": parts[1]})
        with LOCK:
            s = STATE["s"]
            if self.path == "/api/projects":
                if self._legacy_404():
                    return
                p = {"id": secrets.token_hex(3), "name": body.get("name") or "Untitled", "color": body.get("color") or "blue",
                     "accounts": body.get("accounts") or [], "defaultAccount": body.get("defaultAccount") or "auto",
                     "folders": body.get("folders") or []}
                s["projects"].append(p)
                bump()
                return self._json(200, p)
            if self.path == "/api/cards":
                project = next((p for p in s.get("projects", []) if p["id"] == body.get("project")), None)
                account = resolve_account(s, body, project)
                cwd = body.get("cwd") or (project["folders"][0] if project and project["folders"] else "")
                start = bool(body.get("start"))
                cid = secrets.token_hex(4) if start else "t" + secrets.token_hex(3)
                title = body.get("title") or (body.get("prompt") or "").split(".")[0][:40]
                s["cards"].append(card(cid, title, account, "running" if start else "todo", cwd, body.get("prompt") or "", 0,
                                       kind="agent" if start else "todo"))
                if project:
                    s["assignments"][cid] = project["id"]
                bump()
                label = next(a["label"] for a in s["accounts"] if a["id"] == account)
                return self._json(200, {"message": f"{'started ' + cid if start else 'Added to Todo'} on {label}", "account": account})
            if len(parts) == 4 and parts[:2] == ["api", "cards"]:
                cid, action = parts[2], parts[3]
                c = next((c for c in s["cards"] if c["id"] == cid), None)
                if c is None:
                    return self._json(404, {"message": "That card is gone"})
                if action == "project":
                    if self._legacy_404():
                        return
                    pid = body.get("project")
                    if pid is None:
                        s["assignments"].pop(cid, None)
                        msg = "Follows its folder again"
                    else:
                        s["assignments"][cid] = pid
                        msg = "Moved to " + next((p["name"] for p in s["projects"] if p["id"] == pid), pid)
                    bump()
                    return self._json(200, {"message": msg})
                if action == "account" and body.get("account"):
                    if c["col"] == "running":  # queued until the turn ends, like the real server
                        c["pendingAccount"] = body["account"]
                        bump()
                        return self._json(200, {"message": "Switches after this turn"})
                    c["account"] = body["account"]
                    bump()
                if action == "archive":
                    s["cards"].remove(c)
                    bump()
                if action == "pin":
                    c["pinned"] = not c["pinned"]
                    bump()
                return self._json(200, {"message": f"{action} ok"})
        return self._json(404, {"error": "not found"})

    def do_PATCH(self):
        if not self._authed():
            return
        body = self._body()
        LOG.append({"method": "PATCH", "path": self.path, "body": body})
        with LOCK:
            if self._legacy_404():
                return
            pid = self.path.rsplit("/", 1)[-1]
            p = next((p for p in STATE["s"]["projects"] if p["id"] == pid), None)
            if p is None:
                return self._json(404, {"message": "No such project"})
            p.update({k: v for k, v in body.items() if k in ("name", "color", "accounts", "defaultAccount", "folders", "emoji")})
            bump()
            return self._json(200, p)

    def do_DELETE(self):
        if not self._authed():
            return
        LOG.append({"method": "DELETE", "path": self.path})
        with LOCK:
            if self._legacy_404():
                return
            pid = self.path.rsplit("/", 1)[-1]
            s = STATE["s"]
            s["projects"] = [p for p in s["projects"] if p["id"] != pid]
            s["assignments"] = {k: v for k, v in s["assignments"].items() if v != pid}
            bump()
            return self._json(200, {"message": "deleted"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7731)
    ap.add_argument("--scenario", default="freelancer", choices=sorted(SCENARIOS))
    ap.add_argument("--dump", choices=sorted(SCENARIOS))
    a = ap.parse_args()
    if a.dump:
        load(a.dump)
        print(json.dumps(snapshot(), indent=1))
        return
    load(a.scenario)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    srv.daemon_threads = True
    print(f"fake Loft on 127.0.0.1:{a.port} ({a.scenario}); emulator: 10.0.2.2:{a.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
