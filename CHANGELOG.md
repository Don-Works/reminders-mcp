# Changelog

All notable changes to `reminders-mcp` are documented here.

## Unreleased

- Fixed: recurrence frequencies were off by one. "weekly" was saved as monthly,
  "monthly" as yearly, and "yearly", "workdays", "months" and "weeks" as daily, and
  each read back under the requested name. Frequencies are now daily, weekly, monthly
  and yearly. Reminders created by earlier builds keep their stored rule and now read
  back as what EventKit actually holds.
- `location` was accepted and silently dropped (EventKit does not persist it). It is
  now rejected with a pointer to location alarms, and `location` reads back from the
  first location alarm.
- Alarms: `{relative_minutes: N}` (alias `minutes`) and
  `{location: {title, lat, lon, radius_m?}, proximity: "arrive"|"leave"}`. Relative
  alarms need a due date. Location alarms read back as `type: "location"`, and an
  at-due-time alarm reads back as relative 0 instead of "unknown".
- Unknown-field errors list the accepted fields.
- `complete_reminder` returns `completed` and `recurring`; for a recurring reminder
  also `next_due` and `completed_occurrence`.

## 0.1.0 — 2026-09-08

Initial public release.

- Twelve MCP tools for Apple Reminders lists and reminders, including dates,
  priorities, alarms, recurrence, completion, filtering, and list re-homing.
- Strict JSON-RPC envelopes and argument types, with bounded EventKit numeric
  inputs so malformed calls return errors without terminating the server.
- Batched list re-homing and removal in one EventKit commit, with pending-change
  reset on failure.
- Store-independent Swift tests, non-mutating protocol checks in CI, and a
  live-store smoke suite with timeout enforcement and failure cleanup.
- macOS 14+ support, no third-party runtime or Swift package dependencies.
