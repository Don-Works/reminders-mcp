#!/usr/bin/env python3
"""Smoke test for reminders-mcp.

Spawns the server binary, speaks newline-delimited JSON-RPC on stdio, and
exercises the full acceptance path against the live Reminders store:

  initialize -> tools/list -> create_list -> create_reminder (with due date,
  priority, alarm, notes) -> list_reminders -> get_reminder ->
  update_reminder (notes, priority, alarms, clears) ->
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
import queue
import subprocess
import sys
import threading
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
        self.stdout_q: "queue.Queue[str]" = queue.Queue()
        self._stdout_thread = threading.Thread(target=self._drain_stdout, daemon=True)
        self._stdout_thread.start()
        # Drain stderr on a background thread so mid-run error messages carry
        # the server's actual stderr (reading it inline would block on a pipe
        # that fills up while the process is wedged).
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()

    def _drain_stdout(self):
        for line in self.proc.stdout:
            self.stdout_q.put(line)
        self.stdout_q.put("")

    def _drain_stderr(self):
        for line in self.proc.stderr:
            self.stderr_lines.append(line.rstrip("\n"))

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
            # From the reader thread, not proc.stdout directly: readline() blocks with no
            # regard for the deadline, so a server that never answers hung the harness
            # forever instead of failing the call — the exact failure a timeout is for.
            try:
                line = self.stdout_q.get(timeout=max(0.05, deadline - time.time()))
            except queue.Empty:
                break
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
        if result.get("isError") and not expect_error:
            raise RuntimeError(f"{name} returned isError: {str(data)[:300]}")
        if expect_error and not result.get("isError"):
            raise RuntimeError(f"{name} was expected to fail and did not: {str(data)[:300]}")
        return result, data

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc.stderr.close()   # EOF for the drain thread
        self._stderr_thread.join(timeout=2)


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

        # AppleScript `make new list` does not dedupe by name — the server must
        # not create a duplicate when the list already exists.
        _, lst2 = s.tool("create_list", {"name": TEST_LIST})
        check("create_list on an existing name is a no-op (no duplicate)",
              lst2.get("created") is False and lst2.get("id") == lst.get("id"), str(lst2))

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

        # A summer all-day date and a summer wall-clock time. TEST_DUE is in January, when
        # this machine's zone is UTC, so it passes whether or not floating components are
        # serialized correctly; under BST an all-day 1 July used to read back as 30 June.
        _, dst = s.tool("create_reminder", {"title": "dst probe", "list_name": TEST_LIST, "due": "2099-07-01"})
        check("summer all-day due round-trips to the date it was set",
              str(dst.get("due_date")) == "2099-07-01", str(dst.get("due_date")))
        _, dstt = s.tool("create_reminder", {"title": "dst probe timed", "list_name": TEST_LIST, "due": "2099-07-01T14:00"})
        check("summer timed due keeps the wall-clock time it was set",
              str(dstt.get("due_date")).startswith("2099-07-01T14:00:00"), str(dstt.get("due_date")))
        for probe in (dst, dstt):
            s.tool("delete_reminder", {"identifier": probe.get("identifier")})

        # Fractional seconds must parse (agents paste ISO strings from other tools).
        _, frac = s.tool("create_reminder", {"title": "frac probe", "list_name": TEST_LIST, "due": "2099-07-02T09:30:00.5"})
        check("fractional-second due parses to the wall clock",
              str(frac.get("due_date", "")).startswith("2099-07-02T09:30"), str(frac.get("due_date")))
        s.tool("delete_reminder", {"identifier": frac.get("identifier")})

        # A2 regression: a bare-date due_until spans the whole day, so a timed
        # reminder due 23:59 on the boundary day is still included.
        _, bd = s.tool("create_reminder", {"title": "boundary probe", "list_name": TEST_LIST, "due": "2099-12-31T23:59"})
        _, bdq = s.tool("list_reminders", {"list": TEST_LIST, "due_from": "2099-12-31", "due_until": "2099-12-31"})
        check("bare-date due_until spans the whole boundary day",
              any(x["identifier"] == bd.get("identifier") for x in bdq.get("reminders", [])),
              f"count={bdq.get('count')}")
        s.tool("delete_reminder", {"identifier": bd.get("identifier")})

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

        # A4 regression: an unparseable boundary must be an error, not a
        # silently-dropped filter (which would make a wrong query look right).
        res, data = s.tool("list_reminders", {"list": TEST_LIST, "due_from": "tomorrow"}, expect_error=True)
        check("unparseable due_from is an error, not a silent no-op",
              res.get("isError") is True, str(data))
        res, data = s.tool("list_reminders", {"list": TEST_LIST, "due_until": "2024/06/01"}, expect_error=True)
        check("unparseable due_until is an error, not a silent no-op",
              res.get("isError") is True, str(data))

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

        # -- validation: bad inputs must be tool errors, not crashes ----------
        # Runs BEFORE the test list is deleted. It used to run after, so every check here
        # was satisfied by "list not found" rather than by the validation it names.
        print("validation")
        # B4: out-of-range recurrence fields used to reach EKRecurrenceRule and
        # raise an uncatchable ObjC exception — a dead server process. They
        # must now come back as isError.
        for label, rec in [("recurrence frequency 8 (days) rejected", {"frequency": 8}),
                           ("recurrence days_of_week [0] rejected", {"frequency": "weekly", "days_of_week": [0]}),
                           ("recurrence days_of_month [32] rejected", {"frequency": "monthly", "days_of_month": [32]})]:
            res, data = s.tool("create_reminder", {"title": "rec probe", "list_name": TEST_LIST,
                                                   "recurrence": rec}, expect_error=True)
            check(label, res.get("isError") is True, str(data))
            check(f"{label}: rejected by validation, not by a missing list",
                  "list" not in str(data).lower() or "recurrence" in str(data).lower(), str(data)[:120])
        # Swift traps on overflow and a trap cannot be caught: these killed the process.
        for label, args in [("alarm minutes Int.max rejected", {"alarms": [{"minutes": 2**63 - 1}]}),
                            ("alarm minutes Int.min rejected", {"alarms": [{"minutes": -2**63}]}),
                            ("set_positions Int.min rejected",
                             {"recurrence": {"frequency": "weekly", "set_positions": [-2**63]}})]:
            res, data = s.tool("create_reminder", dict({"title": "overflow probe", "list_name": TEST_LIST}, **args),
                               expect_error=True)
            check(label, res.get("isError") is True, str(data))
        # the server must still be alive
        msg = s.call("ping")
        check("server alive after bad recurrence input", msg.get("result") == {}, str(msg))

        # -- delete reminder, then list -----------------------------------------
        print("delete")
        _, delr = s.tool("delete_reminder", {"identifier": rid})
        check("delete_reminder ack", delr.get("deleted") is True, str(delr))
        res, data = s.tool("get_reminder", {"identifier": rid}, expect_error=True)
        check("deleted reminder not found", res.get("isError") is True, str(data)[:120])

        _, dl = s.tool("delete_list", {"list": TEST_LIST})
        check("delete_list ack", dl.get("deleted") is True, str(dl))
        res, data = s.tool("list_reminders", {"list": TEST_LIST}, expect_error=True)
        check("deleted list not found", res.get("isError") is True, str(data)[:120])

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
