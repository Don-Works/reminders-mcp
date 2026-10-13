// reminders-mcp — reminder → JSON serialization.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import Foundation
import EventKit

public func reminderJSON(_ r: EKReminder) -> [String: Any] {
    var o: [String: Any] = [
        "identifier": r.calendarItemIdentifier,
        "title": r.title ?? NSNull(),
        "list": r.calendar?.title ?? NSNull(),
        "list_id": r.calendar?.calendarIdentifier ?? NSNull(),
        "notes": r.notes ?? NSNull(),
        "url": r.url?.absoluteString ?? NSNull(),
        "location": reminderLocation(r) ?? NSNull(),
        "is_completed": r.isCompleted,
        "completed_date": r.completionDate.map { iso8601($0) } ?? NSNull(),
        "due_date": isoFromComponents(r.dueDateComponents) ?? NSNull(),
        "all_day": isAllDay(r.dueDateComponents),
        "start_date": isoFromComponents(r.startDateComponents) ?? NSNull(),
        "priority": priorityName(r.priority),
        "priority_raw": r.priority,
        "creation_date": r.creationDate.map { iso8601($0) } ?? NSNull(),
        "last_modified_date": r.lastModifiedDate.map { iso8601($0) } ?? NSNull(),
    ]
    if let al = r.alarms, !al.isEmpty { o["alarms"] = al.map(alarmJSON) }
    if let rules = r.recurrenceRules, let first = rules.first { o["recurrence"] = recurrenceJSON(first) }
    return o
}

/// EventKit does not persist EKReminder.location: Reminders keeps a place only as
/// a structured-location alarm. Read the plain field if some other client set it,
/// otherwise the first location alarm's title.
public func reminderLocation(_ r: EKReminder) -> String? {
    if let l = r.location, !l.isEmpty { return l }
    return r.alarms?.lazy.compactMap { $0.structuredLocation?.title }.first { !$0.isEmpty }
}

/// A relative alarm on a reminder fires relative to its due date; without one
/// it never fires.
public func hasRelativeAlarm(_ alarms: [EKAlarm]) -> Bool {
    alarms.contains { $0.structuredLocation == nil && $0.absoluteDate == nil }
}
