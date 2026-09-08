# reminders-mcp

Apple Reminders for agents.

Open source by [Revitt](https://revitt.co/?utm_source=reminders-mcp&utm_medium=readme&utm_campaign=donworks_oss), via [Don Works](https://donworks.co.uk/?utm_source=reminders-mcp&utm_medium=readme&utm_campaign=donworks_oss).

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-7c5cff.svg)](LICENSE)
[![Part of Don Works](https://img.shields.io/badge/part%20of-Don%20Works-c6ff1a.svg)](https://donworks.co.uk/?utm_source=reminders-mcp&utm_medium=readme&utm_campaign=donworks_oss)
[![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-7c5cff.svg)](#requirements)

`reminders-mcp` is a single Swift binary that puts the macOS Reminders store
behind MCP. Twelve tools over EventKit — lists and reminders, due dates, alarms,
recurrence rules, priorities, notes, URLs, locations — spoken as newline-delimited
JSON-RPC on stdio. No runtime dependencies beyond the macOS SDK.

## Requirements

macOS 14 or later, and a Swift 5.9+ toolchain (Xcode command line tools).

## Build and run

```sh
swift build -c release
.build/release/reminders-mcp     # speaks MCP 2024-11-05 on stdio
```

Register it with any MCP client as a stdio server pointing at that binary.

## Permissions

The first tool call triggers the macOS Reminders permission prompt, and
`create_list` goes through AppleScript to Reminders.app, which triggers an
Automation prompt.

Both prompts need a process that can show UI. A binary spawned by a `launchd`
daemon cannot display them — the request times out silently and every store call
then blocks. Run the binary once from a terminal to grant access before wiring it
into a daemon-hosted gateway.

## Tools

| Tool | What it does |
|---|---|
| `list_lists` | Every list with id, name, colour, flags, source, open/completed counts |
| `create_list` | New list via AppleScript (this SDK has no EventKit calendar-creation API) |
| `rename_list` | Rename by id or name |
| `set_list_color` | Set a list colour from `#RRGGBB` |
| `delete_list` | Delete, optionally re-homing its reminders first |
| `list_reminders` | Query with list, completion, due range, text, and limit filters |
| `get_reminder` | By identifier, or by exact title scoped to a list |
| `create_reminder` | Title plus notes, url, location, priority, due, start, alarms, recurrence |
| `update_reminder` | Same fields, plus clearing them and moving between lists |
| `complete_reminder` | Optionally with an explicit completion date |
| `uncomplete_reminder` | Reopen a completed reminder |
| `delete_reminder` | Delete by identifier or title |

Dates are ISO-8601, or `YYYY-MM-DD` for an all-day reminder in a floating time
zone, and they round-trip: an all-day reminder reads back as the bare date it was
set to, a timed one as ISO-8601 with this machine's offset. Absolute instants —
completion, creation, alarms, recurrence ends — are UTC. Full argument tables are
in [`docs/tool-spec.md`](docs/tool-spec.md).

## Smoke test

```sh
python3 scripts/smoke_test.py
```

Spawns the release binary and exercises the whole handshake and all twelve
tools, create through single-commit list re-homing and delete, in uniquely
named scratch lists. It also probes summer all-day dates, whole-day
`due_until`, strict argument types, bounded recurrence/alarm input, and server
survival after bad requests. A fresh process removes any scratch lists even
when the test run fails. It needs a live Reminders store, so it cannot run in
CI.

`swift test` covers the store-independent logic. CI additionally runs
`python3 scripts/protocol_test.py .build/release/reminders-mcp`, a non-mutating
JSON-RPC/MCP conformance suite that needs no Reminders permission.

## Notes on EventKit

[`docs/eventkit-surface.md`](docs/eventkit-surface.md) records what this SDK
actually exposes, verified by compile probe and by runtime crash. Two findings
worth knowing before you write against it: `predicateForIncompleteReminders`
with nil bounds takes the process down, KVC-composed predicates crash the
fetch — only store-factory predicates survive, so all query narrowing here
happens in Swift — and `EKWeekday`/`EKRecurrenceFrequency`'s failable inits
are not actually failable, so recurrence input is range-checked before it
reaches `EKRecurrenceRule`. There is no calendar-creation API and no
sub-reminders.

## License

AGPL-3.0. See [LICENSE](LICENSE).
