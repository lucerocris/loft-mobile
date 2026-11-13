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
legacy (an older Loft: no accounts/projects/groupBy fields, no chat messages),
pickers (a pending AskUserQuestion with two questions, a permission prompt, a plan
approval, and a plain-text question).

GET /api/cards/<id>/messages serves a made-up session per card (the chat view);
running cards grow by one step every few seconds, and a reply is appended.
POST /api/cards/<id>/answer answers a picker (409 when the tool id is stale).

Folder picker: GET /api/fs?path=~/x[&hidden=1] lists a made-up home folder (Loft's
loft/fs.py shape; 403 outside home, 404 for a missing folder; Recent = the scenario's dirs).
Browser: running cards carry a `browser` badge; GET /api/sites lists signed-in sites per
account (Loft docs/browser-protocol.md: {accounts: [{account, label, hex, sites, browser}], agents,
chrome}); WebSocket /ws/browser/<card id> and /ws/sites/<account> stream generated JPEG frames
(needs Pillow) and answer mouse, key, nav, site, sites, back, reload and viewport like
loft/browser.py's Viewer. The legacy scenario 404s all of these.

Titles and the Loft Assistant (loft-plans/assistant-contract.md): cards carry `summary`;
a started task gets a title + summary ~2 s later; POST /api/cards/<id>/rename {title?, summary?}
and /describe {keepTitle?}. POST /api/bulk {action: archive|stop, filter: done|idle|all, ids?}.
GET/POST /api/assistant and POST /api/assistant/reset: a fake assistant (its card is in the
snapshot with `assistant: true`) that answers in the messages format after ~1.5 s and really
does the work: "archive ... done", "stop ..." (asks to confirm with a picker first),
"what needs me", "start a task: <prompt>". The legacy scenario 404s these too.
"""
import argparse
import base64
import copy
import hashlib
import io
import struct
import json
import os
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

NOW = datetime.now(timezone.utc)
HEX = {"blue": "#5B8DFF", "green": "#46C07D", "purple": "#A98BFF", "cyan": "#3EC1D3",
       "pink": "#F17DB8", "orange": "#F2924A", "yellow": "#E3CF5B", "red": "#F0685A"}


def ago(minutes):
    return (NOW - timedelta(minutes=minutes)).isoformat()


def acc(id, label, color, email="", default=False):
    return {"id": id, "label": label, "color": color, "hex": HEX[color], "email": email, "default": default}


def card(id, name, account, col, cwd, detail="", minutes=5, kind="agent", pinned=False, failed=False, result="", summary=None):
    return {"kind": kind, "id": id, "name": name, "summary": summary or SUMMARIES.get(id), "account": account, "work": False, "col": col,
            "state": {"needs": "needs input", "running": "working", "todo": "todo", "done": "done"}[col],
            "detail": detail, "result": result, "cwd": cwd, "updated": ago(minutes), "live": col == "running",
            "pinned": pinned, "failed": failed, "links": []}


SUMMARIES = {   # what Loft's small model writes on start (contract §1); some cards have none
    "a0000001": "Pick the checkout headline for the Acme site before launch.",
    "a0000002": "Shrink the hero images so the home page loads faster.",
    "a0000003": "Get the offline sync tests passing on Northwind's app.",
    "a0000004": "Wire Android push notifications for order updates.",
    "a0000006": "Make Bloom's Stripe webhooks retry instead of dropping orders.",
    "a0000009": "Regenerate the Acme sitemap after the new pages.",
    "b0000001": "Find why the invoice export totals don't match the ledger.",
    "b0000003": "Build the weekly reports board from the ticket data.",
    "b0000005": "Long-press a word in the reader to look it up.",
    "b0000007": "Add a board view to Loft next to the inbox.",
    "c0000001": "Fix the blog's RSS feed so readers stop showing wrong dates.",
    "c0000002": "Add a dark mode to the portfolio site.",
    "c0000005": "Resize the blog's images for faster pages.",
}


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
            {**card("a0000002", "Hero images · compress", "studio", "running", "~/clients/acme-web", "Converting 48 images to AVIF", 0),
             "browser": {"mcp": True, "running": False, "url": "http://localhost:5173/", "live": True,
                         "checks": {"ok": True, "passed": 3, "total": 3}}},
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
            {**card("b0000003", "Reports · weekly board", "work", "running", "~/work/ops-tools", "Writing the board layout into the automation", 0, pinned=True),
             "browser": {"mcp": True, "running": False, "url": "https://tickets.example.com/board", "live": True, "account": "work", "sites": 1}},
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
            {**card("c0000002", "Portfolio · dark mode", "main", "running", "~/code/portfolio", "Checking contrast on the cards", 0),
             "browser": {"mcp": True, "running": False}},
            card("c0000003", "CLI · release script", "main", "running", "~/code/cli", "Tagging v0.4.1", 4),
            card("t0000004", "Resume · update", "main", "todo", "~/docs/resume", "(no prompt yet)", 1440, kind="todo"),
            card("c0000005", "Blog · images", "main", "done", "~/code/blog", "", 2000, result="Images resized"),
        ],
        "assignments": {},
        "dirs": ["~/code/blog", "~/code/portfolio", "~/code/cli"],
    },
}
SCENARIOS["legacy"] = {"legacy": True, **copy.deepcopy(SCENARIOS["two-accounts"])}
SCENARIOS["pickers"] = {
    "accounts": [acc("work", "Work", "blue", "work@example.com"), acc("personal", "Personal", "green", "me@example.com", True)],
    "usage": {"work": usage(42, 15), "personal": usage(12, 30)},
    "defaultAccount": "personal",
    "groupBy": "status",
    "projects": [],
    "cards": [
        card("p0000001", "Pizza night · order", "personal", "needs", "~/errands", "Pick a crust", 2),
        card("p0000002", "Notes · export", "work", "needs", "~/work/notes", "approve Bash: npm run export -- --all", 4),
        card("p0000003", "Search · reindex plan", "work", "needs", "~/work/search", "approve plan", 6),
        card("p0000004", "Blog · RSS feed", "personal", "needs", "~/code/blog", "The feed has 2 date formats. Keep RFC 822?", 9),
        card("p0000005", "Reader · tests", "personal", "running", "~/reader", "Running the emulator tests", 0),
    ],
    "assignments": {},
    "dirs": ["~/errands", "~/work/notes", "~/code/blog"],
}

# ------------------------------------------------------------------ chat messages
# Same item shapes as Loft's loft/transcript.py. Cursors here are item counts.
QUESTIONS = {
    "a0000006": [{"question": "Should failed webhooks retry 3 or 5 times?", "header": "Retries", "multi": False,
                  "options": [{"label": "3 tries", "description": "Clears most network blips"},
                              {"label": "5 tries", "description": "Also covers a short outage"}]}],
    "b0000001": [{"question": "Fix both?", "header": "Fix", "multi": False,
                  "options": [{"label": "Fix both", "description": "Rounding and the missing refund rows"},
                              {"label": "Rounding only", "description": "Leave refunds for later"}]}],
}
QUESTIONS["p0000001"] = [
    {"question": "Pick a crust", "header": "Crust", "multi": False,
     "options": [{"label": "Thin", "description": "Crisp, bakes fast"}, {"label": "Thick", "description": "Soft and filling"}]},
    {"question": "Pick toppings", "header": "Toppings", "multi": True,
     "options": [{"label": "Cheese", "description": "Extra mozzarella"}, {"label": "Olives", "description": "Black olives"},
                 {"label": "Basil", "description": "Fresh leaves"}]},
]
PERMS = {   # card id -> the permission / plan prompt it waits on (what Loft reads off the attach screen)
    "p0000002": {"tool": ("Bash", "Export every notebook", "npm run export -- --all"), "title": "Do you want to proceed?",
                 "options": ["Yes", "Yes, and don't ask again for npm run export commands", "No"]},
    "p0000003": {"tool": ("Plan", "Ready to code?", ""), "title": "Claude wants to exit plan mode",
                 "plan": "## Reindex plan\n\n1. Snapshot the current index\n2. Rebuild with the new analyzer\n3. Swap the alias, keep the old index for a day",
                 "options": ["Yes, and auto-accept edits", "Yes, and manually approve edits", "No, keep planning"]},
}
LIVE_STEPS = [
    ("tool", "Bash", "Run the test suite", "npm test"),
    ("result", True, "Tests: 41 passed, 41 total\nTime: 6.2 s"),
    ("assistant", "All green. Moving on to the next part."),
    ("tool", "Read", "settings.ts", "~/project/src/settings.ts"),
    ("result", True, "1\texport const settings = {\n2\t  retries: 3,\n3\t  timeoutMs: 8000,\n4\t};"),
    ("tool", "Edit", "settings.ts", "~/project/src/settings.ts"),
    ("result", True, "The file ~/project/src/settings.ts has been updated successfully.", {"add": 4, "del": 1}),
    ("assistant", "Updated the defaults. Running the checks again."),
]
MSGS = {}   # card id -> {"items": [...], "t0": time}


def _it(cid, n, kind, now=False, **kw):
    at = datetime.now(timezone.utc).isoformat() if now else ago(max(0, 30 - n))
    return {"id": f"{cid}-{n:04d}", "kind": kind, "at": at, **kw}


def _step(cid, n, step, tool_ids, now=False):
    kind = step[0]
    if kind == "tool":
        tid = f"toolu_{cid}_{n}"
        tool_ids.append(tid)
        return _it(cid, n, "tool", now, tool=tid, name=step[1], title=step[2], detail=step[3])
    if kind == "result":
        text = step[2]
        lines = text.splitlines()
        it = _it(cid, n, "result", now, ok=step[1], preview="\n".join(lines[:4]), lines=len(lines), text=text, cut=False)
        it["for"] = tool_ids[-1] if tool_ids else ""
        if len(step) > 3:
            it["diff"] = step[3]
        return it
    return _it(cid, n, "assistant", now, text=step[1])


def build_messages(c):
    if c.get("assistant"):
        return {"items": [], "t0": time.time(), "tools": [], "live": 0}
    cid, prompt = c["id"], c.get("detail") or c["name"]
    items, tools, n = [], [], 0

    def add(kind, **kw):
        nonlocal n
        items.append(_it(cid, n, kind, **kw))
        n += 1

    def step(st):
        nonlocal n
        items.append(_step(cid, n, st, tools))
        n += 1

    add("user", text=f"{c['name']}: take a look and get it done. Ask me before anything risky.")
    add("assistant", text="I'll start by reading the project and running the tests so I know where things stand.")
    step(("tool", "Bash", "Run the tests", "npm test"))
    step(("result", False, "FAIL src/format.test.ts\n  rounds totals\n    expected 10.05 got 10.04\n\nTests: 1 failed, 40 passed"))
    step(("tool", "Grep", "roundTotal", "roundTotal in ~/project/src"))
    step(("result", True, "src/format.ts:12\nsrc/report.ts:40\nsrc/report.ts:88"))
    step(("tool", "Read", "format.ts", "~/project/src/format.ts"))
    step(("result", True, "10\texport function roundTotal(x: number) {\n11\t  // floors instead of rounding\n12\t  return Math.floor(x * 100) / 100;\n13\t}"))
    add("assistant", text=(
        "Found it. `roundTotal` **floors** instead of rounding, so some totals come out one cent low.\n\n"
        "```ts\nexport function roundTotal(x: number) {\n  return Math.round(x * 100) / 100;\n}\n```\n\n"
        "- `format.ts` is the only place that needs the change\n- two reports call it, both are covered by tests"))
    if c["col"] == "needs":
        if cid in QUESTIONS:
            add("question", tool=f"toolu_{cid}_ask", questions=QUESTIONS[cid])
        elif cid in PERMS:
            name, title, detail = PERMS[cid]["tool"]
            extra = {"plan": PERMS[cid]["plan"]} if "plan" in PERMS[cid] else {}
            add("tool", tool=f"toolu_{cid}_perm", name=name, title=title, detail=detail, **extra)
        else:
            add("assistant", text=prompt)
    elif c["col"] == "done":
        step(("tool", "Edit", "format.ts", "~/project/src/format.ts"))
        step(("result", True, "The file ~/project/src/format.ts has been updated successfully.", {"add": 1, "del": 1}))
        add("assistant", text=(c.get("result") or "Done.") + ". All 41 tests pass.")
    elif c["col"] == "running":
        add("user", text="Looks right. Go ahead and fix it, then run everything again.")
        step(("tool", "Edit", "format.ts", "~/project/src/format.ts"))
        step(("result", True, "The file ~/project/src/format.ts has been updated successfully.", {"add": 1, "del": 1}))
    return {"items": items, "t0": time.time(), "tools": tools, "live": 0}


def messages(c, q):
    m = MSGS.get(c["id"])
    if m is None:
        m = MSGS[c["id"]] = build_messages(c)
    if c["col"] == "running" and not c.get("assistant"):   # one live step every 4 s while it works
        due = int((time.time() - m["t0"]) / 4)
        while m["live"] < due:
            st = LIVE_STEPS[m["live"] % len(LIVE_STEPS)]
            m["items"].append(_step(c["id"], len(m["items"]), st, m["tools"], now=True))
            m["live"] += 1
    items = m["items"]
    limit = int(q.get("limit") or 60)
    out = {"id": c["id"], "state": c["col"], "working": c["col"] == "running", "detail": c.get("detail") or "",
           "session": "fake-" + c["id"], "size": len(items), "cursor": len(items), "gap": False, "pending": None}
    if q.get("after", "").isdigit() and q.get("session") == out["session"]:
        a = min(int(q["after"]), len(items))
        page, start = items[a:], a
    else:
        b = int(q["before"]) if q.get("before", "").isdigit() else len(items)
        start = max(0, b - limit)
        page = items[start:b]
    if c["col"] == "needs":
        out["pending"] = {"text": c.get("detail") or "", "question": None, "prompt": pending_prompt(c, items)}
        if out["pending"]["prompt"] and out["pending"]["prompt"]["kind"] == "question":
            out["pending"]["question"] = items[-1]
    return {**out, "items": page, "start": start, "more": start > 0}


def pending_prompt(c, items):
    last = items[-1] if items else None
    if not last:
        return None
    if last["kind"] == "question":
        return {"kind": "question", "tool": last["tool"], "questions": last["questions"]}
    if last["kind"] == "tool" and c["id"] in PERMS:
        p = PERMS[c["id"]]
        return {"kind": "permission", "tool": last["tool"], "title": p["title"], "action": c.get("detail") or "",
                "options": [{"n": i + 1, "label": o} for i, o in enumerate(p["options"])]}
    return None


def answer(c, body):
    """POST /api/cards/<id>/answer, the same contract as Loft's answer_route."""
    m = MSGS.get(c["id"]) or build_messages(c)
    MSGS[c["id"]] = m
    pend = pending_prompt(c, m["items"]) if c["col"] == "needs" else None
    if not pend or pend["tool"] != body.get("tool"):
        return 409, {"message": "The question changed. Here is the current one.", "pending": pend}
    if pend["kind"] == "question":
        ans = body.get("answers")
        if not isinstance(ans, list) or len(ans) != len(pend["questions"]):
            return 400, {"message": f"Expected {len(pend['questions'])} answer(s)."}
        parts = []
        for q, a in zip(pend["questions"], ans):
            labels = [q["options"][i]["label"] for i in (a.get("choices") or ([a["choice"]] if isinstance(a.get("choice"), int) else []))
                      if isinstance(i, int) and 0 <= i < len(q["options"])]
            if a.get("other"):
                labels.append(a["other"])
            if not labels:
                return 400, {"message": "Pick one of the options."}
            parts.append(f'"{q["question"]}"="{", ".join(labels)}"')
        text = "Your questions have been answered: " + ", ".join(parts)
    else:
        n = body.get("permission")
        if not isinstance(n, int) or not 1 <= n <= len(pend["options"]):
            return 400, {"message": "That option isn't on the prompt."}
        text = "Approved: " + pend["options"][n - 1]["label"] if n < len(pend["options"]) else "The user said no."
    m["items"].append(_it(c["id"], len(m["items"]), "result", now=True, ok=True, preview=text, lines=1, text=text, cut=False, **{"for": pend["tool"]}))
    m["t0"], m["live"] = time.time(), 0
    c["col"], c["state"], c["detail"], c["live"] = "running", "working", "Carrying on", True
    return 200, {"message": "Answered", "confirmed": True}


def reply_message(c, text):
    m = MSGS.get(c["id"])
    if m is None:
        m = MSGS[c["id"]] = build_messages(c)
    m["items"].append(_it(c["id"], len(m["items"]), "user", now=True, text=text))
    m["t0"], m["live"] = time.time(), 0
    c["col"], c["state"], c["detail"], c["live"] = "running", "working", "Working on your reply", True


# ------------------------------------------------------------------ titles, bulk, assistant
def derive_title(prompt):
    first = prompt.strip().split(". ")[0]
    words = [w for w in first.replace(":", " ").split() if w]
    while words and words[0].lower() in ("please", "can", "you", "could", "start", "a", "task"):
        words.pop(0)
    words = words[:6]
    while len(words) > 2 and words[-1].lower() in ("the", "a", "an", "to", "of", "for", "and", "with", "in", "on"):
        words.pop()
    t = " ".join(words).rstrip(".!?,")
    return (t[:1].upper() + t[1:]) if t else "New task"


def describe_prompt(prompt):
    """The fake 'small model': {title, summary} from a prompt (contract §1)."""
    first = (prompt or "").strip().split(".")[0]
    words = first.split()
    summary = " ".join(words[:14]).rstrip(",;:") + ("." if words else "")
    return {"title": derive_title(prompt or ""), "summary": (summary[:1].upper() + summary[1:]) if summary else None}


def bulk(s, body):
    """POST /api/bulk: {action: archive|stop, filter: done|idle|all, ids?} -> {message, count, ids}."""
    action, flt, ids = body.get("action"), body.get("filter") or "done", body.get("ids")
    if action not in ("archive", "stop"):
        return 400, {"message": "action must be archive or stop"}
    agents = [c for c in s["cards"] if c["kind"] == "agent"]
    if isinstance(ids, list):
        pick = [c for c in agents if c["id"] in ids]
    elif flt == "done":
        pick = [c for c in agents if c["col"] == "done"]
    elif flt == "idle":
        pick = [c for c in agents if c["col"] in ("done", "needs")]
    else:
        pick = list(agents)
    if action == "archive":
        pick = [c for c in pick if c["col"] != "running"]
        for c in pick:
            s["cards"].remove(c)
        msg = f"Archived {len(pick)} agent{'s' if len(pick) != 1 else ''}"
    else:
        pick = [c for c in pick if c["col"] == "running"]
        for c in pick:
            c.update(col="done", state="stopped", live=False, result="Stopped from the phone", updated=datetime.now(timezone.utc).isoformat())
        msg = f"Stopped {len(pick)} agent{'s' if len(pick) != 1 else ''}"
    return 200, {"message": msg, "count": len(pick), "ids": [c["id"] for c in pick]}


def assistant_card(s):
    a = s.get("assistant")
    if a is None:
        aid = "as" + secrets.token_hex(3)
        a = s["assistant"] = card(aid, "Loft Assistant", s["defaultAccount"], "done", "~/.loft/assistant", "", 0)
        a.update(state="idle", summary="Operates Loft for you.", assistant=True)
    return a


def _asay(a, kind, **kw):
    m = MSGS.setdefault(a["id"], build_messages({**a, "assistant": True}))
    m["items"].append(_it(a["id"], len(m["items"]), kind, now=True, **kw))
    return m


def _atool(a, name, title, detail, result, ok=True):
    m = MSGS.setdefault(a["id"], build_messages({**a, "assistant": True}))
    tid = f"toolu_{a['id']}_{len(m['items'])}"
    _asay(a, "tool", tool=tid, name=name, title=title, detail=detail)
    lines = result.splitlines() or [""]
    _asay(a, "result", ok=ok, preview="\n".join(lines[:4]), lines=len(lines), text=result, cut=False, **{"for": tid})


def _aidle(a, needs_detail=None):
    a.update(col="needs" if needs_detail else "done", state="needs input" if needs_detail else "idle",
             detail=needs_detail or "", live=bool(needs_detail), updated=datetime.now(timezone.utc).isoformat())


def assistant_think(text):
    """The fake assistant: does what the message asks with Loft's tools, then says so."""
    with LOCK:
        s = STATE["s"]
        a = s.get("assistant")
        if a is None:
            return
        t = text.lower()
        agents = [c for c in s["cards"] if c["kind"] == "agent"]
        if "archive" in t:
            code, r = bulk(s, {"action": "archive", "filter": "all" if "everything" in t and "done" not in t else "done"})
            _atool(a, "mcp__loft__bulk", "Archive everything that's done", "bulk archive, filter=done", r["message"])
            _asay(a, "assistant", text=(f"Archived **{r['count']}** done agent{'s' if r['count'] != 1 else ''}. Their sessions are kept."
                                        if r["count"] else "Nothing was done, so there was nothing to archive."))
            _aidle(a)
        elif "stop" in t:
            running = [c for c in agents if c["col"] == "running"]
            _atool(a, "mcp__loft__list_cards", "Running agents", "list_cards col=running",
                   "\n".join(f"{c['id']}  {c['name']}" for c in running) or "(none)")
            if not running:
                _asay(a, "assistant", text="Nothing is running right now.")
                _aidle(a)
            else:
                q = f"Stop {len(running)} running agent{'s' if len(running) != 1 else ''}?"
                _asay(a, "assistant", text="These are working now:\n\n" + "\n".join(f"- {c['name']}" for c in running))
                _asay(a, "question", tool=f"toolu_{a['id']}_ask{len(MSGS[a['id']]['items'])}", questions=[
                    {"question": q, "header": "Stop", "multi": False,
                     "options": [{"label": "Stop them", "description": "They keep their sessions; reply later to resume"},
                                 {"label": "Cancel", "description": "Leave them running"}]}])
                _aidle(a, q)
        elif "need" in t:
            needs = [c for c in agents if c["col"] == "needs"]
            _atool(a, "mcp__loft__list_cards", "Cards that need you", "list_cards col=needs",
                   "\n".join(f"{c['id']}  {c['name']}" for c in needs) or "(none)")
            if needs:
                body = "\n".join(f"- **{c['name']}**: {c['detail']}" for c in needs)
                _asay(a, "assistant", text=f"{len(needs)} need{'s' if len(needs) == 1 else ''} you:\n\n{body}")
            else:
                _asay(a, "assistant", text="Nothing needs you right now.")
            _aidle(a)
        elif t.startswith("start") or "start a task" in t or t.startswith("new task"):
            prompt = text.split(":", 1)[1].strip() if ":" in text else text
            if not prompt or prompt.lower() in ("start a task", "start a task…"):
                _asay(a, "assistant", text="Sure. What should it do, and in which folder?")
                _aidle(a)
                return
            d = describe_prompt(prompt)
            cid = secrets.token_hex(4)
            low = prompt.lower()
            cwd = next((d for d in s["dirs"] if os.path.basename(d).split("-")[0] in low), (s["dirs"] or ["~"])[0])
            s["cards"].append(card(cid, d["title"], s["defaultAccount"], "running", cwd, prompt, 0, summary=d["summary"]))
            label = next(x["label"] for x in s["accounts"] if x["id"] == s["defaultAccount"])
            _atool(a, "mcp__loft__start_task", d["title"], f"start_task cwd={cwd}", f"started {cid} on {label}")
            _asay(a, "assistant", text=f"Started **{d['title']}** in `{cwd}` on {label}.\n\n{d['summary'] or ''}")
            _aidle(a)
        else:
            _asay(a, "assistant", text=("I run Loft for you. I can start tasks, stop or archive agents, rename them, "
                                        "and tell you what needs you. What should I do?"))
            _aidle(a)
        bump()


def describe_later(cid, keep_title):
    """Loft asks a small model for {title, summary} a few seconds after start."""
    with LOCK:
        c = find_card(STATE["s"], cid)
        if c is None or STATE["s"].get("legacy"):
            return
        d = describe_prompt(c.get("detail") or c["name"])
        if not keep_title:
            c["name"] = d["title"]
        c["summary"] = d["summary"]
        bump()


def assistant_answered(a, choice_text):
    """After the stop confirmation is answered."""
    time.sleep(1.0)
    with LOCK:
        s = STATE["s"]
        if s.get("assistant") is not a:
            return
        if "Stop them" in choice_text:
            code, r = bulk(s, {"action": "stop", "filter": "all"})
            _atool(a, "mcp__loft__bulk", "Stop all running agents", "bulk stop, filter=all", r["message"])
            _asay(a, "assistant", text=f"Stopped **{r['count']}**. Reply to any of them later to pick it up again.")
        else:
            _asay(a, "assistant", text="OK, I left them running.")
        _aidle(a)
        bump()


LOCK = threading.Lock()
STATE = {"name": "", "s": None, "version": 0}
LOG = []


def load(name):
    with LOCK:
        STATE["name"] = name
        STATE["s"] = copy.deepcopy(SCENARIOS[name])
        STATE["version"] += 1
        MSGS.clear()


def bump():
    STATE["version"] += 1


def find_card(s, cid):
    c = next((c for c in s["cards"] if c["id"] == cid), None)
    a = s.get("assistant")
    if c is None and a is not None and a["id"] == cid:
        return a
    return c


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
            c2 = {k: v for k, v in c.items() if k not in ("account", "summary")}
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
    a = s.get("assistant")
    if a is not None:
        cards.append({**a, "assistant": True, "work": False, "project": None, "folder": a["cwd"]})
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


# ------------------------------------------------------------------ folder picker
HOME = "/home/me"
TREE = {   # a made-up home folder: name -> subtree; "@git" / "@web" mark a folder
    "clients": {n: {"@git": True, "@web": True, "src": {}, "public": {}} for n in
                ("acme-web", "northwind-app", "northwind-api", "bloom-shop", "harbor-api")},
    "code": {"blog": {"@git": True, "@web": True, "posts": {}}, "portfolio": {"@git": True, "@web": True},
             "cli": {"@git": True, "src": {}}, "scratch": {}},
    "work": {"ops-tools": {"@git": True, "scripts": {}}, "notes": {}, "search": {"@git": True}},
    "loft": {"@git": True, "@web": True, "app": {}, "docs": {}}, "reader": {"@git": True}, "notes": {"2026": {}},
    "errands": {}, "docs": {"resume": {}}, "dotfiles": {"@git": True}, "Downloads": {}, "Music": {},
    ".config": {"loft": {}}, ".cache": {},
}
TREE["clients"]["archive"] = {f"old-{i:03d}": {} for i in range(520)}   # long folder: truncated at 500


def fs_display(p):
    return "~" if p == HOME else "~" + p[len(HOME):] if p.startswith(HOME + "/") else p


def fs_resolve(path):
    raw = (path or "~").strip() or "~"
    if raw == "~" or raw.startswith("~/"):
        raw = HOME + raw[1:]
    raw = os.path.normpath(raw)
    if not raw.startswith("/"):
        return 400, "Give a full path or one starting with ~."
    if raw != HOME and not raw.startswith(HOME + "/"):
        return 403, "Only folders inside your home folder can be browsed."
    node = TREE
    for part in [x for x in raw[len(HOME):].split("/") if x]:
        if part.startswith("@") or part not in node:
            return 404, f"No such folder: {fs_display(raw)}"
        node = node[part]
    return raw, node


def fs_item(p, node):
    return {"name": os.path.basename(p), "path": p, "display": fs_display(p),
            "git": bool(node.get("@git")), "web": bool(node.get("@web"))}


def fs_list(query, dirs):
    q = parse_qs(query)
    p, node = fs_resolve((q.get("path") or ["~"])[0])
    if isinstance(p, int):
        return p, {"error": node, "message": node}
    hidden = (q.get("hidden") or [""])[0] in ("1", "true")
    names = sorted((n for n in node if not n.startswith("@") and (hidden or not n.startswith("."))), key=lambda n: (n.lower(), n))
    out = [fs_item(f"{p}/{n}", node[n]) for n in names[:500]]
    recent = []
    if p == HOME:
        for d in dirs:
            rp, rn = fs_resolve(d)
            if not isinstance(rp, int):
                recent.append(fs_item(rp, rn))
    return 200, {"path": p, "display": fs_display(p), "parent": None if p == HOME else os.path.dirname(p),
                 "dirs": out, "recent": recent, "truncated": len(names) > 500}


# ------------------------------------------------------------------ browser
SITES = {   # per scenario: account -> sites (Loft's loft/sites.py sites.json shape)
    "freelancer": {"studio": [{"id": "s1a2b3c4", "name": "Helpdesk", "url": "https://help.example.com"},
                              {"id": "s5d6e7f8", "name": "Analytics", "url": "https://analytics.example.com/dash"}],
                   "overflow": [{"id": "s9a8b7c6", "name": "Shop admin", "url": "https://admin.bloom.example.com"}]},
    "two-accounts": {"work": [{"id": "w1", "name": "Tickets", "url": "https://tickets.example.com"}]},
    "solo": {}, "pickers": {},
}

def sites_account(a):
    """One entry of GET /api/sites accounts (loft/sites.py public())."""
    sites = [{**x, "cookies": 3 if i % 2 == 0 else 0, "signedIn": i % 2 == 0}
             for i, x in enumerate(SITES.get(STATE["name"], {}).get(a["id"], []))]
    running = any(k == ("site", a["id"]) for k in PAGES)
    return {"account": a["id"], "label": a["label"], "hex": a.get("hex", ""), "sites": sites,
            "browser": {"running": running, "window": False}, "profile": bool(sites)}


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_send(wfile, op, data):
    n = len(data)
    head = bytes([0x80 | op]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack(">H", n) if n < 65536
                                 else bytes([127]) + struct.pack(">Q", n))
    wfile.write(head + data)
    wfile.flush()


def ws_read(rfile):
    h = rfile.read(2)
    if len(h) < 2:
        return None, b""
    op, n = h[0] & 0x0F, h[1] & 0x7F
    if n == 126:
        n = struct.unpack(">H", rfile.read(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", rfile.read(8))[0]
    mask = rfile.read(4) if h[1] & 0x80 else b"\0\0\0\0"
    data = bytes(b ^ mask[i % 4] for i, b in enumerate(rfile.read(n)))
    return op, data


class FakePage:
    """What the fake browser shows: a made-up page that scrolls, takes clicks and typing."""

    def __init__(self, url, title, account=None):
        self.url, self.title = url, title
        self.account = account   # sites browser: the account entry ({account, label, sites, ...})
        self.sites = (account or {}).get("sites", [])
        self.history = [url]
        self.mobile, self.scroll, self.typed = False, 0, ""
        self.clicks = []   # (x, y) in 0..1 of the picture, last few
        self.lock = threading.Lock()
        self.dirty = True

    @property
    def size(self):
        return (780, 1688) if self.mobile else (1280, 800)   # mobile = 390x844 CSS at 2x, like Loft

    def handle(self, m):
        t = m.get("type")
        if t == "site":   # sites browser: open one of the account's sites
            site = next((x for x in self.sites if x["id"] == m.get("id")), None)
            if not site:
                return {"type": "toast", "err": True, "text": "No such site."}
            m, t = {"type": "nav", "url": site["url"]}, "nav"
        if t == "sites":
            return {"type": "sites", **self.account} if self.account else None
        with self.lock:
            if t == "mouse":
                k = m.get("kind")
                if k == "mousePressed":
                    self.clicks = (self.clicks + [(m.get("x", 0), m.get("y", 0))])[-5:]
                elif k == "mouseWheel":
                    self.scroll = max(0, min(4000, self.scroll + int(m.get("dy", 0))))
            elif t == "key":
                if m.get("text"):
                    self.typed = (self.typed + m["text"])[-60:]
                elif m.get("key") == "Backspace":
                    self.typed = self.typed[:-1]
                elif m.get("key") == "Enter":
                    self.typed += " ⏎ "
            elif t == "nav":
                u = (m.get("url") or "").strip()
                if u:
                    self.url = u if "://" in u or u.startswith("about:") else "http://" + u
                    self.history.append(self.url)
                    self.scroll = 0
                    return {"type": "url", "url": self.url}
            elif t == "back" and len(self.history) > 1:
                self.history.pop()
                self.url, self.scroll = self.history[-1], 0
                return {"type": "url", "url": self.url}
            elif t == "reload":
                self.scroll = 0
                return {"type": "toast", "text": "Reloaded"}
            elif t == "viewport":
                self.mobile = bool(m.get("mobile"))
            self.dirty = True
        return None

    def jpeg(self, tick):
        from PIL import Image, ImageDraw, ImageFont
        with self.lock:
            w, h = self.size
            k = 2 if self.mobile else 1
            img = Image.new("RGB", (w, h), (246, 247, 249))
            d = ImageDraw.Draw(img)
            try:
                big, mid, small = (ImageFont.load_default(size=s * k) for s in (28, 18, 14))
            except TypeError:   # old Pillow
                big = mid = small = ImageFont.load_default()
            top = 64 * k
            d.rectangle([0, 0, w, top], fill=(24, 26, 31))
            d.text((20 * k, 20 * k), self.title, font=mid, fill=(237, 238, 240))
            d.text((w - 140 * k, 24 * k), time.strftime("%H:%M:%S"), font=small, fill=(164, 168, 175))
            y = top + 24 * k - self.scroll
            d.text((20 * k, y), self.url, font=big, fill=(20, 22, 26))
            y += 48 * k
            for i in range(40):
                if y > h:
                    break
                if y > top - 40 * k:
                    d.rounded_rectangle([20 * k, y, w - 20 * k, y + 64 * k], radius=10 * k, fill=(255, 255, 255), outline=(222, 225, 230))
                    d.text((36 * k, y + 12 * k), f"Row {i + 1}" + ("  ·  " + self.typed if i == 0 and self.typed else ""), font=mid, fill=(30, 32, 36))
                    d.text((36 * k, y + 38 * k), "Scroll, tap and type from the phone", font=small, fill=(110, 115, 123))
                y += 76 * k
            for (cx, cy) in self.clicks:
                x, yy = cx * w, cy * h
                d.ellipse([x - 12 * k, yy - 12 * k, x + 12 * k, yy + 12 * k], outline=(91, 141, 255), width=3 * k)
            d.rectangle([0, h - 6 * k, int(w * ((tick % 30) / 30)), h], fill=(91, 141, 255))   # it's live
            self.dirty = False
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=70)
        return buf.getvalue()


def browser_session(handler, page, hello):
    """Run one fake browser socket: frames out, input in."""
    key = handler.headers.get("Sec-WebSocket-Key", "")
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    handler.send_response(101, "Switching Protocols")
    handler.send_header("Upgrade", "websocket")
    handler.send_header("Connection", "Upgrade")
    handler.send_header("Sec-WebSocket-Accept", accept)
    handler.end_headers()
    handler.wfile.flush()
    lock, alive = threading.Lock(), [True]

    def out(op, data):
        with lock:
            ws_send(handler.wfile, op, data)

    def ev(d):
        out(1, json.dumps(d).encode())

    def pump():
        tick = 0
        try:
            while alive[0]:
                out(2, page.jpeg(tick))
                tick += 1
                if tick % 40 == 7:
                    ev({"type": "err", "text": f"404 {page.url.rstrip('/')}/favicon.ico"})
                time.sleep(0.25)
        except (OSError, ValueError):
            alive[0] = False

    ev(hello)
    ev({"type": "url", "url": page.url})
    threading.Thread(target=pump, daemon=True).start()
    try:
        while alive[0]:
            op, data = ws_read(handler.rfile)
            if op is None or op == 8:
                break
            if op == 9:
                out(10, data)
                continue
            if op != 1:
                continue
            try:
                m = json.loads(data)
            except ValueError:
                continue
            LOG.append({"method": "WS", "path": handler.path, "body": m})
            r = page.handle(m)
            if r:
                ev(r)
    except (OSError, ValueError):
        pass
    finally:
        alive[0] = False
        handler.close_connection = True


PAGES = {}   # ("agent"|"site", id) -> FakePage: the page stays where you left it, like the real one


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

    def _legacy_404_quiet(self):
        return bool(STATE["s"].get("legacy"))

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
        url = urlparse(self.path)
        parts = url.path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["api", "cards"] and parts[3] == "messages":
            with LOCK:
                if self._legacy_404():
                    return
                c = find_card(STATE["s"], parts[2])
                if c is None:
                    return self._json(404, {"error": "not found"})
                if c["kind"] == "todo":
                    return self._json(200, {"id": c["id"], "state": "todo", "working": False, "detail": "", "session": None,
                                            "cursor": 0, "start": 0, "more": False, "gap": False, "items": [], "pending": None})
                return self._json(200, messages(c, {k: v[-1] for k, v in parse_qs(url.query).items()}))
        if self.path == "/__log":
            return self._json(200, LOG[-50:])
        if url.path == "/api/assistant":
            with LOCK:
                if self._legacy_404():
                    return
                a = STATE["s"].get("assistant")
                return self._json(200, {"id": a["id"] if a else None, "card": {**a, "assistant": True} if a else None,
                                        "account": STATE["s"]["defaultAccount"], "running": bool(a and a["col"] == "running")})
        if url.path == "/api/fs":
            with LOCK:
                if self._legacy_404():
                    return
                dirs = list(STATE["s"]["dirs"])
            return self._json(*fs_list(url.query, dirs))
        if url.path == "/api/sites":
            with LOCK:
                if self._legacy_404():
                    return
                s = STATE["s"]
                agents = [{"id": c["id"], "name": c["name"], "account": c["account"], "col": c["col"],
                           "url": c["browser"].get("url", ""), "live": c["browser"].get("live", False),
                           "sitesAccount": c["browser"].get("account")} for c in s["cards"] if c.get("browser")]
                return self._json(200, {"chrome": True, "accounts": [sites_account(a) for a in s["accounts"]], "agents": agents})
        if len(parts) == 3 and parts[0] == "ws" and parts[1] in ("browser", "sites"):
            with LOCK:
                if self._legacy_404():
                    return
                s = STATE["s"]
                if parts[1] == "browser":
                    c = next((c for c in s["cards"] if c["id"] == parts[2]), None)
                    if c is None or not c.get("browser"):
                        return self._json(404, {"error": "no such agent"})
                    key, title, url0 = ("agent", c["id"]), c["name"], "http://localhost:5173/"
                    hello = {"type": "hello", "mcp": True, "ports": [5173], "login": False, "recording": None}
                else:
                    a = next((a for a in s["accounts"] if a["id"] == parts[2]), None)
                    if a is None:
                        return self._json(404, {"error": "no such account"})
                    entry = sites_account(a)
                    key, title, url0 = ("site", parts[2]), f"{a['label']} · signed-in browser", "about:blank"
                    hello = {"type": "hello", **entry}
                page = PAGES.setdefault(key, FakePage(url0, title, hello if parts[1] == "sites" else None))
            if not self.headers.get("Sec-WebSocket-Key"):
                return self._json(400, {"error": "websocket only"})
            return browser_session(self, page, hello)
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
            if self.path in ("/api/bulk", "/api/assistant", "/api/assistant/reset") and self._legacy_404():
                return
            if self.path == "/api/bulk":
                code, r = bulk(s, body)
                if code == 200:
                    bump()
                return self._json(code, r)
            if self.path == "/api/assistant":
                msg = (body.get("message") or "").strip()
                if not msg:
                    return self._json(400, {"message": "Say what Loft should do."})
                a = assistant_card(s)
                MSGS.setdefault(a["id"], build_messages(a))
                _asay(a, "user", text=msg)
                a.update(col="running", state="working", detail="Working on it", live=True, updated=datetime.now(timezone.utc).isoformat())
                bump()
                threading.Timer(1.5, assistant_think, args=(msg,)).start()
                return self._json(200, {"id": a["id"], "message": "Sent"})
            if self.path == "/api/assistant/reset":
                a = s.pop("assistant", None)
                if a is not None:
                    MSGS.pop(a["id"], None)
                s["assistant"] = None
                bump()
                return self._json(200, {"message": "New conversation"})
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
                if start:
                    threading.Timer(2.0, describe_later, args=(cid, bool(body.get("title")))).start()
                if project:
                    s["assignments"][cid] = project["id"]
                bump()
                label = next(a["label"] for a in s["accounts"] if a["id"] == account)
                return self._json(200, {"message": f"{'started ' + cid if start else 'Added to Todo'} on {label}", "account": account})
            if len(parts) == 4 and parts[:2] == ["api", "cards"]:
                cid, action = parts[2], parts[3]
                c = find_card(s, cid)
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
                    if c in s["cards"]:
                        s["cards"].remove(c)
                    bump()
                if action == "answer":
                    if self._legacy_404():
                        return
                    code, payload = answer(c, body)
                    if code == 200:
                        bump()
                        if c.get("assistant"):
                            said = MSGS[c["id"]]["items"][-1]["text"]
                            c["detail"] = "Working on it"
                            threading.Thread(target=assistant_answered, args=(c, said), daemon=True).start()
                    return self._json(code, payload)
                if action == "rename":
                    title = (body.get("title") or body.get("name") or "").strip()
                    if "summary" in body and not self._legacy_404_quiet():
                        c["summary"] = (body.get("summary") or "").strip() or None
                    if title:
                        c["name"] = title
                    if not title and "summary" not in body:
                        return self._json(400, {"message": "A name can't be empty."})
                    bump()
                    return self._json(200, {"message": "renamed"})
                if action == "describe":
                    if self._legacy_404():
                        return
                    d = describe_prompt(c.get("detail") if c.get("detail") not in ("", "(no prompt yet)") else c["name"])
                    if not body.get("keepTitle"):
                        c["name"] = d["title"]
                    c["summary"] = d["summary"]
                    bump()
                    return self._json(200, {"title": c["name"], "summary": c["summary"], "message": "described"})
                if action == "reply" and (body.get("text") or "").strip():
                    reply_message(c, body["text"].strip())
                    bump()
                    return self._json(200, {"message": "Sent"})
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
