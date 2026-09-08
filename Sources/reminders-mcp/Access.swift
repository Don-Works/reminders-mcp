// reminders-mcp — EventKit access + fetch.
//
// Copyright (C) 2026 Revitt / Don Works. AGPL-3.0-or-later.

import Foundation
import EventKit
import RemindersCore

enum AccessState { case unknown, granted, denied(String, at: Date) }
var access: AccessState = .unknown

/// How long a denial is cached before we re-ask — long enough to flip the
/// switch in System Settings, without requiring a server restart.
let deniedRepromptAfter: TimeInterval = 120

func ensureAccess() throws {
    switch access {
    case .granted:
        return
    case .denied(let why, let at) where Date().timeIntervalSince(at) < deniedRepromptAfter:
        throw MCPErr("Reminders access denied: \(why). Grant it in System Settings → Privacy & Security → Reminders; this server re-asks on its own after a couple of minutes.")
    case .unknown, .denied:
        break   // re-ask (a denial older than deniedRepromptAfter falls through here)
    }

    let sem = DispatchSemaphore(value: 0)
    var granted = false
    var why = ""
    store.requestFullAccessToReminders { ok, err in
        granted = ok
        why = err?.localizedDescription ?? ""
        sem.signal()
    }
    if sem.wait(timeout: .now() + 10) == .timedOut {
        throw MCPErr("Timed out waiting for Reminders access")
    }
    if granted {
        access = .granted
    } else {
        let msg = why.isEmpty ? "unknown reason" : why
        access = .denied(msg, at: Date())
        throw MCPErr("Reminders access denied: \(msg)")
    }
}

/// fetchReminders(matching:) on this SDK is completion-based; block on a
/// semaphore (10 s timeout) to keep the stdio loop synchronous.
///
/// IMPORTANT — factory predicates only, verified by crash (see
/// docs/eventkit-surface.md "Predicate gotcha"):
///  1. `fetchReminders(matching:)` rejects predicates not created by the
///     store's own factory methods (raising "predicate is not a reminder
///     predicate created through EKEventStore") — so no NSCompoundPredicate
///     wrapping with KVC clauses.
///  2. `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)`
///     deterministically crashes the process on this machine.
///
/// So: always fetch with `predicateForReminders(in:)` (verified safe) and do
/// ALL narrowing — completed state, due range, has-due, title/notes/location
/// contains — in Swift after the fetch.
func fetchReminders(_ predicate: NSPredicate) throws -> [EKReminder] {
    var out: [EKReminder] = []
    let sem = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: predicate) { reminders in
        out = reminders ?? []
        sem.signal()
    }
    // A timeout here means the Reminders subsystem is wedged, not that there
    // are no reminders — returning an empty list would make callers conclude
    // data doesn't exist.
    if sem.wait(timeout: .now() + 10) == .timedOut {
        throw MCPErr("Timed out fetching reminders (10 s) — the Reminders subsystem may be wedged; check Reminders.app / CalendarAgent (or reboot), then retry")
    }
    return out
}

func allReminderCalendars() -> [EKCalendar] {
    store.calendars(for: .reminder)
}
