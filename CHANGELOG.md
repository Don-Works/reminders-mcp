# Changelog

All notable changes to `reminders-mcp` are documented here.

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
