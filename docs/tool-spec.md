# Tool surface specified for reminders-mcp

12 tools, sized to what the SDK on this machine exposes (see `eventkit-surface.md`).

| Tool | Arguments |
|---|---|
| `list_lists` | `include_empty` (default true). Returns id, name, colour hex, subscribed, allows_modifications, immutable, source, open/completed counts |
| `create_list` | `name`, optional `color`. Refuses to duplicate an existing list; AppleScript to Reminders.app, then retry-lookup in EventKit (the store lags a beat) |
| `rename_list` | `list` (name or id), `new_name` → set `title`, `saveCalendar` |
| `set_list_color` | `list`, `color` `#RRGGBB` → `NSColor`, `saveCalendar` |
| `delete_list` | `list`, optional `move_to` (must be a different, writable list). Re-homing stages every move and the source-list removal, then commits the batch once |
| `list_reminders` | `list`, `include_completed` (default false), `completed_only`, `due_from`, `due_until`, `query`, `notes_query`, `location_like`, `has_due_date`, `limit` (default 50, max 500). Returns `{count, total, truncated, reminders[]}` |
| `get_reminder` | `identifier`, or `title` + optional `list_name`; ambiguous titles return up to 10 candidates |
| `create_reminder` | `title` (required), `list_name`, `notes`, `url`, `location`, `priority` (`none\|high\|medium\|low` or 0/1/5/9), `due`, `start`, `alarms: [{minutes} \| {date}]`, `recurrence` |
| `update_reminder` | lookup by `identifier` or `title`+`list_name`; same settable fields as create, plus `remove_due`, `remove_start`, `clear_alarm`, `clear_recurrence`, `move_to_list` |
| `complete_reminder` | lookup + optional `completed_at` |
| `uncomplete_reminder` | lookup |
| `delete_reminder` | lookup |

`recurrence`: `{frequency, interval (default 1), days_of_week[], days_of_month[],
months_of_year[], weeks_of_year[], days_of_year[], set_positions[], until | count}`.
`frequency` is daily/weekly/monthly/yearly/workdays/months/weeks — "days" is rejected
(this SDK corrupts it, see `eventkit-surface.md`). All list fields are range-validated
before reaching `EKRecurrenceRule`; `interval` and `count` are limited to
`1...2147483647`. Relative alarm minutes are limited to ±52,560,000 (about a
century). Out-of-range or wrong-typed input is a tool error, not a crash.

Every supplied argument is type-checked at the tool boundary. In particular,
wrong-typed update fields are rejected without changing the reminder; they are
never interpreted as an empty value. Empty strings intentionally clear only
`notes`, `url`, and `location`. Conflicting set/clear pairs such as `due` plus
`remove_due` are rejected.

Dates in: ISO-8601 (Z/offset, naive local, fractional seconds) or naive
`YYYY-MM-DD[THH:MM[:SS[.SSS]]]`; `YYYY-MM-DD` alone means all-day. Time zone left
unset (floating) for stored due/start components.

Dates out, on `due_date` and `start_date`: an all-day reminder serializes as the bare
`YYYY-MM-DD` it was set to, a timed one as ISO-8601 with this machine's offset
(`2026-07-01T14:00:00+01:00`). Both round-trip: what goes in comes back. Absolute
instants — `completed_date`, `creation_date`, `last_modified_date`, alarm and
recurrence-end dates — are UTC, because those are real instants rather than
wall-clock components.

MCP: `initialize` (echoes the client's protocolVersion if known, otherwise answers
with the latest supported — `2025-06-18`; serverInfo `reminders-mcp` 0.1.0), `ping`,
`tools/list`, `tools/call` returning `{content:[{type:"text",text}], isError}`,
`-32600` for invalid request envelopes, `-32601` for unknown methods with an id,
`-32602` for invalid params, and no response for notifications. Malformed JSON
is `-32700`; valid non-object JSON is `-32600`.
A `tools/call` sent as a notification (no `id`) is refused rather than executed,
because a mutation whose result can't be reported is worse than a refusal.

Boundary semantics for `due_from`/`due_until`: naive values and bare dates are local
wall-clock (the same footing stored due dates are compared on); Z/offset-suffixed
values are absolute instants. A bare date used as `due_until` spans the whole day
(through 23:59:59). Unparseable boundaries are a hard error — silently dropping the
filter would make a wrong query look like a right one.

`list_reminders` returns `{count, total, truncated, reminders[]}` — `total` is the match
count before `limit` is applied.

Implementation: pure helpers (date parsing/serialization, priority, colour, recurrence
and alarm construction, reminder→JSON) live in the `RemindersCore` library target and are
unit-tested (`swift test`, no store access); the executable target
(`Sources/reminders-mcp/`: main, Access, Tools, Protocol) is the stdio server. Live-store
behaviour is covered by `scripts/smoke_test.py`; non-mutating protocol behaviour
is covered in CI by `scripts/protocol_test.py`.
