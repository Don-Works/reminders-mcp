#!/usr/bin/env python3
"""Non-mutating JSON-RPC/MCP conformance checks for CI.

This starts the release binary but never calls an EventKit-backed tool, so it
needs neither Reminders access nor an interactive macOS session.
"""

import os
import sys

from smoke_test import DEFAULT_BIN, Server


CHECKS = 0
FAILURES = []


def check(name, condition, detail=""):
    global CHECKS
    CHECKS += 1
    status = "ok " if condition else "FAIL"
    print(f"  [{status}] {name}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(name)


def error_code(message):
    return message.get("error", {}).get("code")


def main():
    binpath = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BIN
    if not os.path.exists(binpath):
        print(f"binary not found at {binpath} — run `swift build -c release` first")
        return 2

    server = Server(binpath)
    try:
        message = server.call("initialize", {
            "protocolVersion": "2024-11-05",
            "clientInfo": {"name": "protocol-test", "version": "0"},
        })
        check("initialize succeeds", message.get("result", {}).get("protocolVersion") == "2024-11-05",
              str(message))

        message = server.call("ping")
        check("ping succeeds", message.get("result") == {}, str(message))

        message = server.request({"id": "missing-version", "method": "ping"}, "missing-version",
                                 "missing jsonrpc")
        check("missing jsonrpc is invalid request", error_code(message) == -32600, str(message))

        message = server.request({"jsonrpc": "1.0", "id": "old-version", "method": "ping"},
                                 "old-version", "wrong jsonrpc")
        check("wrong jsonrpc version is invalid request", error_code(message) == -32600, str(message))

        message = server.request([], None, "batch request")
        check("unsupported batch is invalid request, not parse error", error_code(message) == -32600,
              str(message))

        message = server.request(42, None, "scalar request")
        check("valid scalar JSON is invalid request, not parse error", error_code(message) == -32600,
              str(message))

        server.send_raw("this is not json")
        message = server.read_response(None, "malformed JSON")
        check("malformed JSON is parse error", error_code(message) == -32700, str(message))

        message = server.request({"jsonrpc": "2.0", "id": None, "method": "ping"}, None,
                                 "explicit null id")
        check("explicit null id still receives a response", message.get("result") == {}, str(message))

        message = server.request({"jsonrpc": "2.0", "id": True, "method": "ping"}, None,
                                 "boolean id")
        check("boolean id is invalid request", error_code(message) == -32600, str(message))

        message = server.request({
            "jsonrpc": "2.0", "id": "bad-params", "method": "tools/call", "params": [],
        }, "bad-params", "array params")
        check("positional params are rejected", error_code(message) == -32602, str(message))

        message = server.request({
            "jsonrpc": "2.0",
            "id": "bad-arguments",
            "method": "tools/call",
            "params": {"name": "list_lists", "arguments": []},
        }, "bad-arguments", "array tool arguments")
        check("non-object tool arguments are rejected before dispatch", error_code(message) == -32602,
              str(message))

        message = server.request({
            "jsonrpc": "2.0", "id": "missing-name", "method": "tools/call", "params": {},
        }, "missing-name", "missing tool name")
        check("missing tool name is invalid params", error_code(message) == -32602, str(message))

        result, data = server.tool("list_lists", {"unexpected": True}, expect_error=True)
        check("unknown tool arguments are rejected before EventKit dispatch",
              result.get("isError") is True and "unknown field" in str(data), str(data))

        message = server.call("definitely/not/a/method")
        check("unknown method is method not found", error_code(message) == -32601, str(message))

        message = server.call("tools/list")
        tools = {tool["name"]: tool for tool in message["result"]["tools"]}
        recurrence = tools["create_reminder"]["inputSchema"]["properties"]["recurrence"]
        check("tool schema omits unsupported recurrence frequency",
              "days" not in recurrence["properties"]["frequency"]["enum"], str(recurrence))
        check("tool schema bounds recurrence interval",
              recurrence["properties"]["interval"].get("maximum") == 2**31 - 1,
              str(recurrence["properties"]["interval"]))

        message = server.call("ping")
        check("server remains alive after protocol errors", message.get("result") == {}, str(message))
    except Exception as error:
        check("protocol run completed without an exception", False, repr(error))
    finally:
        server.close()

    print(f"\n{CHECKS} checks, {len(FAILURES)} failures")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
