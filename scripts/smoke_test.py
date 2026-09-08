#!/usr/bin/env python3
"""Smoke test for reminders-mcp.

Spawns the server binary, speaks newline-delimited JSON-RPC on stdio, and
exercises the full acceptance path against the live Reminders store:

  initialize -> tools/list -> create_list -> create_reminder (with due date,
  priority, alarm, notes) -> list_reminders -> get_reminder ->
  update_reminder (complete via completed_at? no — update fields) ->
  complete_reminder -> list_reminders(completed_only) -> uncomplete_reminder ->
  delete_reminder -> delete_list -> ping -> bogus method

The test list and reminder carry unique suffixes so reruns are safe and any
stray rows left behind by a mid-run failure are identifiable (the server's
error output prints them).

Usage:
  swift build -c release          # first
  scripts/smoke_test.py [path-to-binary]

Exit code 0 = all checks passed.
"""

import json
import os
import subprocess
import sys
import time
import uuid

DEFAULT_BIN = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ".build", "release", "reminders-mcp",
)

SUFFIX = uuid.uuid4().hex[:8]
TEST_LIST = f"mcp-smoke {SUFFIX}"
TEST_TITLE = f"mcp smoke reminder {SUFFIX}"
TEST_NOTES = "created by scripts/smoke_test.py"
TEST_DUE = "2099-01-01"          # all-day, far future

FAILURES = []
CHECKS = 0


def check(name, cond, detail=""):
    global CHECKS
    CHECKS += 1
    status = "ok " if cond else "FAIL"
    print(f"  [{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


class Server:
    def __init__(self, binpath):
        self.proc = subprocess.Popen(
            [binpath],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 0
        self.stderr_lines = []

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def call(self, method, params=None, timeout=30):
        self.next_id += 1
        req = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            req["params"] = params
        self._send(req)
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == self.next_id:
                return msg
        raise RuntimeError(f"no response to {method} (stderr: {self.stderr()})")

    def notify(self, method, params=None):
        obj = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            obj["params"] = params
        self._send(obj)

    def stderr(self):
        return "".join(self.stderr_lines)

    def tool(self, name, args=None, expect_error=False):
        """Call a tool, unwrap {content:[{text}], isError}."""
        msg = self.call("tools/call", {"name": name, "arguments": args or {}})
        if "error" in msg:
            raise RuntimeError(f"protocol error on tools/call {name}: {msg['error']}")
        result = msg["result"]
        text = result["content"][0]["text"]
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            data = text
        if expect_error:
            return result, data
        return result, data

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.stderr_lines = (self.proc.stderr.read() or "").splitlines()


def main():
    binpath = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BIN
    if not os.path.exists(binpath):
        print(f"binary not found at {binpath} — run `swift build -c release` first")
        return 2

    print(f"reminders-mcp smoke test (list: {TEST_LIST})")
    print("NOTE: the first tool call may trigger a macOS Reminders-permission")
    print("prompt — approve it. If access is denied, the test fails on list_lists.\n")

    s = Server(binpath)
    try:
        # -- handshake -------------------------------------------------------
        print("handshake")
        msg = s.call("initialize", {"protocolVersion": "2024-11-05",
                                    "clientInfo": {"name": "smoke", "version": "0"}})
        r = msg["result"]
        check("initialize echoes protocolVersion", r["protocolVersion"] == "2024-11-05", str(r))
        check("initialize serverInfo", r["serverInfo"]["name"] == "reminders-mcp")
        check("initialize capabilities.tools", "tools" in r.get("capabilities", {}))

        s.notify("notifications/initialized")

        msg = s.call("tools/list")
        tools = {t["name"]: t for t in msg["result"]["tools"]}
        check("tools/list returns 12 tools", len(tools) == 12, f"got {len(tools)}")
        for t in ["list_lists", "create_list", "rename_list", "set_list_color",
                  "delete_list", "list_reminders", "get_reminder", "create_reminder",
                  "update_reminder", "complete_reminder", "uncomplete_reminder",
                  "delete_reminder"]:
            check(f"tool present: {t}", t in tools)
            if t in tools:
                check(f"  {t} schema type=object", tools[t]["inputSchema"]["type"] == "object")

        # -- list lifecycle --------------------------------------------------
        print("list lifecycle")
        _, lst = s.tool("create_list", {"name": TEST_LIST, "color": "#FF8800"})
        check("create_list returns id", bool(lst.get("id")), str(lst))
        check("create_list returns name", lst.get("name") == TEST_LIST, str(lst))
        check("create_list color applied", (lst.get("color") or "").upper() == "#FF8800", str(lst.get("color")))

        _, ren = s.tool("rename_list", {"list": TEST_LIST, "new_name": TEST_LIST})
        check("rename_list round-trip", ren.get("name") == TEST_LIST, str(ren))

        _, clr = s.tool("set_list_color", {"list": TEST_LIST, "color": "#00AAFF"})
        check("set_list_color", (clr.get("color") or "").upper() == "#00AAFF", str(clr.get("color")))

        _, ll = s.tool("list_lists")
        names = [x["name"] for x in ll["lists"]]
        check("list_lists finds the test list", TEST_LIST in names, str(names[:10]))

        # -- reminder lifecycle ----------------------------------------------
        print("reminder lifecycle")
        _, rem = s.tool("create_reminder", {
            "title": TEST_TITLE,
            "list_name": TEST_LIST,
            "notes": TEST_NOTES,
            "priority": "high",
            "due": TEST_DUE,
            "alarms": [{"minutes": 10}],
            "recurrence": {"frequency": "weekly", "days_of_week": [2], "count": 3},
        })
        check("create_reminder returns identifier", bool(rem.get("identifier")), str(rem))
        check("create_reminder in test list", rem.get("list") == TEST_LIST, str(rem.get("list")))
        check("create_reminder priority=high (1)", rem.get("priority_raw") == 1, str(rem.get("priority")))
        check("create_reminder all-day due 2099-01-01", rem.get("all_day") is True and str(rem.get("due_date", "")).startswith("2099-01-01"), str(rem.get("due_date")))
        check("create_reminder alarm", any(a.get("type") == "relative" for a in rem.get("alarms", [])), str(rem.get("alarms")))
        check("create_reminder recurrence weekly", (rem.get("recurrence") or {}).get("frequency") == "weekly", str(rem.get("recurrence")))
        rid = rem["identifier"]

        _, found = s.tool("get_reminder", {"identifier": rid})
        check("get_reminder by identifier", found.get("title") == TEST_TITLE, str(found.get("title")))

        _, by_title = s.tool("get_reminder", {"title": TEST_TITLE, "list_name": TEST_LIST})
        check("get_reminder by title+list", by_title.get("identifier") == rid)

        _, lrem = s.tool("list_reminders", {"list": TEST_LIST})
        ids = [x["identifier"] for x in lrem["reminders"]]
        check("list_reminders finds the reminder", rid in ids, str(ids))
        check("list_reminders count field", lrem.get("count") == 1, str(lrem.get("count")))

        # filters: query + has_due_date + notes_query
        _, q = s.tool("list_reminders", {"list": TEST_LIST, "query": "smoke"})
        check("list_reminders query=smoke", q.get("count") == 1, str(q.get("count")))
        _, q0 = s.tool("list_reminders", {"list": TEST_LIST, "query": "definitely-not-there"})
        check("list_reminders query no-match", q0.get("count") == 0, str(q0.get("count")))
        _, nd = s.tool("list_reminders", {"list": TEST_LIST, "has_due_date": True})
        check("list_reminders has_due_date", nd.get("count") == 1, str(nd.get("count")))
        _, nq = s.tool("list_reminders", {"list": TEST_LIST, "notes_query": "smoke_test"})
        check("list_reminders notes_query", nq.get("count") == 1, str(nq.get("count")))
        _, dr = s.tool("list_reminders", {"list": TEST_LIST, "due_from": "2099-01-01", "due_until": "2099-12-31"})
        check("list_reminders due range", dr.get("count") == 1, str(dr.get("count")))

        # -- update ------------------------------------------------------------
        print("update")
        _, up = s.tool("update_reminder", {
            "identifier": rid,
            "notes": TEST_NOTES + " (edited)",
            "priority": "low",
            "alarms": [{"date": "2099-01-01T09:00:00"}],
        })
        check("update_reminder notes", up.get("notes") == TEST_NOTES + " (edited)", str(up.get("notes")))
        check("update_reminder priority low (9)", up.get("priority_raw") == 9, str(up.get("priority_raw")))
        check("update_reminder absolute alarm", any(a.get("type") == "absolute" for a in up.get("alarms", [])), str(up.get("alarms")))
        check("update_reminder recurrence preserved", (up.get("recurrence") or {}).get("frequency") == "weekly", str(up.get("recurrence")))

        _, up2 = s.tool("update_reminder", {
            "identifier": rid,
            "notes": "",
            "clear_alarm": True,
            "clear_recurrence": True,
            "remove_due": True,
        })
        check("update clears notes", up2.get("notes") in (None, ""), str(up2.get("notes")))
        check("update clears alarms", not up2.get("alarms"), str(up2.get("alarms")))
        check("update clears recurrence", not up2.get("recurrence"), str(up2.get("recurrence")))
        check("update removes due", up2.get("due_date") is None, str(up2.get("due_date")))

        # -- complete / uncomplete --------------------------------------------
        print("complete / uncomplete")
        _, comp = s.tool("complete_reminder", {"identifier": rid})
        check("complete_reminder", comp.get("is_completed") is True and comp.get("completed_date"), str(comp.get("is_completed")))

        _, cl = s.tool("list_reminders", {"list": TEST_LIST, "include_completed": False})
        check("completed hidden by default", cl.get("count") == 0, str(cl.get("count")))
        _, cl2 = s.tool("list_reminders", {"list": TEST_LIST, "completed_only": True})
        check("completed_only finds it", cl2.get("count") == 1, str(cl2.get("count")))

        _, un = s.tool("uncomplete_reminder", {"identifier": rid})
        check("uncomplete_reminder", un.get("is_completed") is False, str(un.get("is_completed")))

        # -- delete reminder, then list -----------------------------------------
        print("delete")
        _, delr = s.tool("delete_reminder", {"identifier": rid})
        check("delete_reminder ack", delr.get("deleted") is True, str(delr))
        try:
            s.tool("get_reminder", {"identifier": rid}, expect_error=True)
            gone = True
        except Exception:
            gone = False
        check("deleted reminder not found", gone)

        _, dl = s.tool("delete_list", {"list": TEST_LIST})
        check("delete_list ack", dl.get("deleted") is True, str(dl))
        try:
            s.tool("list_reminders", {"list": TEST_LIST}, expect_error=True)
            gone = True
        except Exception:
            gone = False
        check("deleted list not found", gone)

        # -- protocol edge cases -----------------------------------------------
        print("protocol edges")
        msg = s.call("ping")
        check("ping -> {}", msg.get("result") == {}, str(msg))
        msg = s.call("definitely/not/a/method")
        check("unknown method -> -32601", msg.get("error", {}).get("code") == -32601, str(msg.get("error")))
        # a malformed line must not kill the loop
        s.proc.stdin.write("this is not json\n")
        s.proc.stdin.flush()
        msg = s.call("ping")
        check("server survives malformed line", msg.get("result") == {}, str(msg))

    finally:
        s.close()

    print(f"\n{CHECKS} checks, {len(FAILURES)} failures")
    if s.stderr_lines:
        print("server stderr:")
        for line in s.stderr_lines[-10:]:
            print(f"  {line}")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        print(f"cleanup hint: delete list '{TEST_LIST}' by hand if it still exists")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
