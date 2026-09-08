// reminders-mcp — tool implementations (12 tools).
//
// Copyright (C) 2026 Revitt / Don Works. AGPL-3.0-or-later.

import Foundation
import EventKit
import RemindersCore

// MARK: - Resolution

/// Resolve a list by calendar id or (case-insensitive) title.
func resolveCalendar(_ ref: String) throws -> EKCalendar {
    let t = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = allReminderCalendars()
    if let byId = all.first(where: { $0.calendarIdentifier == t }) { return byId }
    let matches = all.filter { $0.title.caseInsensitiveCompare(t) == .orderedSame }
    switch matches.count {
    case 0: throw MCPErr("No list with name or id \"\(t)\"")
    case 1: return matches[0]
    default:
        throw MCPErr("Ambiguous list \"\(t)\" — matches: \(matches.map(\.title).joined(separator: ", "))")
    }
}

/// Resolve a reminder by identifier, or by exact (case/diacritic-insensitive)
/// title within an optional list. Ambiguous titles list up to 10 candidates.
func resolveReminder(_ args: [String: Any]) throws -> EKReminder {
    if let id = try optionalStringArg(args["identifier"], name: "identifier") {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw MCPErr("No reminder with identifier \(id)")
        }
        return r
    }
    guard let title = try optionalStringArg(args["title"], name: "title") else {
        throw MCPErr("Provide identifier, or title with optional list_name")
    }
    let cals: [EKCalendar]?
    let listName = try optionalStringArg(args["list_name"], name: "list_name")
    if let listName {
        cals = [try resolveCalendar(listName)]
    } else {
        cals = nil
    }
    let matches = try fetchReminders(store.predicateForReminders(in: cals))
        .filter { cdEqual($0.title, title) }
    switch matches.count {
    case 0:
        let scope = listName.map { " in list \"\($0)\"" } ?? ""
        throw MCPErr("No reminder titled \"\(title)\"\(scope)")
    case 1:
        return matches[0]
    default:
        let candidates = matches.prefix(10).map {
            "\($0.title ?? "") [list: \($0.calendar?.title ?? "?") id: \($0.calendarItemIdentifier)]"
        }
        throw MCPErr("Ambiguous title \"\(title)\" — candidates: \(candidates.joined(separator: " | ")); pass identifier to disambiguate")
    }
}

// MARK: - List serialization

/// Counts are computed from an already-fetched set so list_lists can do one
/// store fetch instead of one per list.
func listJSON(_ c: EKCalendar, reminders: [EKReminder]) -> [String: Any] {
    let open = reminders.filter { !$0.isCompleted }.count
    return [
        "id": c.calendarIdentifier,
        "name": c.title,
        "color": hexFromNSColor(c.color),
        "subscribed": c.isSubscribed,
        "allows_modifications": c.allowsContentModifications,
        "immutable": c.isImmutable,
        "source": c.source?.title ?? NSNull(),
        "open_count": open,
        "completed_count": reminders.count - open,
    ]
}

func listJSON(_ c: EKCalendar) throws -> [String: Any] {
    listJSON(c, reminders: try fetchReminders(store.predicateForReminders(in: [c])))
}

// MARK: - List tools

func toolListLists(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let includeEmpty = try boolArg(a["include_empty"], name: "include_empty", default: true)
    // One fetch for the whole store, grouped per list — this used to do one
    // fetch per list (N+1 sequential XPC round-trips).
    let all = try fetchReminders(store.predicateForReminders(in: nil))
    let byCalendar = Dictionary(grouping: all, by: { $0.calendar?.calendarIdentifier ?? "" })
    let lists: [Any] = allReminderCalendars().compactMap { c in
        let j = listJSON(c, reminders: byCalendar[c.calendarIdentifier] ?? [])
        let open = (j["open_count"] as? Int) ?? 0
        let done = (j["completed_count"] as? Int) ?? 0
        if !includeEmpty && open == 0 && done == 0 { return nil }
        return j
    }
    return ["count": lists.count, "lists": lists]
}

/// This SDK has no createCalendar on EKEventStore — new lists go through
/// AppleScript to Reminders.app, then re-fetch via EventKit.
func toolCreateList(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let name = try requiredStringArg(a["name"], name: "name")
    let colorText = try optionalStringArg(a["color"], name: "color")
    let requestedColor = try colorText.map(nsColorFromHex)
    // AppleScript `make new list` does not dedupe by name: if the list already
    // exists, calling it would create a duplicate. Check first, and fail closed
    // if the store already contains ambiguous duplicate names.
    let existingMatches = allReminderCalendars().filter { cdEqual($0.title, name) }
    if existingMatches.count > 1 {
        throw MCPErr("Multiple lists are already named \"\(name)\"; refusing to create another duplicate")
    }
    if let existing = existingMatches.first {
        var out = try listJSON(existing)
        out["created"] = false
        out["note"] = "list already existed; not created again"
        return out
    }
    let escaped = name
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "tell application \"Reminders\" to make new list with properties {name:\"\(escaped)\"}"

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = FileHandle.nullDevice   // keep our stdout clean
    p.standardInput = FileHandle.nullDevice
    try p.run()

    // waitUntilExit() has no deadline: a hung Reminders.app — or an automation
    // TCC prompt that can't be delivered to a daemon-spawned process — would
    // hang this server forever. Poll with a 30 s deadline instead.
    let deadline = Date().addingTimeInterval(30)
    while p.isRunning {
        if Date() >= deadline {
            p.terminate()
            let grace = Date().addingTimeInterval(2)
            while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            let msg = errText(errPipe)
            throw MCPErr("Reminders.app did not respond within 30 s (automation permission prompt pending, or the app is hung)\(msg.isEmpty ? "" : ": " + msg)")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if p.terminationStatus != 0 {
        let msg = errText(errPipe)
        throw MCPErr("AppleScript list creation failed:\(msg.isEmpty ? "" : " ")\(msg)")
    }

    // The EventKit store can lag a second or two behind the AppleScript
    // create; retry the lookup rather than erroring about a list we made.
    var cal: EKCalendar?
    for _ in 0..<10 {
        if let c = try? resolveCalendar(name) { cal = c; break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard let c = cal else {
        throw MCPErr("AppleScript reported success but EventKit does not see list \"\(name)\" yet — check list_lists")
    }
    if let requestedColor {
        c.color = requestedColor
        do { try store.saveCalendar(c, commit: true) }
        catch { throw MCPErr("List created, but saving its color failed: \(error.localizedDescription)") }
    }
    var out = try listJSON(c)
    out["created"] = true
    return out
}

func toolRenameList(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let ref = try requiredStringArg(a["list"], name: "list")
    let newName = try requiredStringArg(a["new_name"], name: "new_name")
    let cal = try resolveCalendar(ref)
    cal.title = newName
    do { try store.saveCalendar(cal, commit: true) }
    catch { throw MCPErr("saveCalendar failed: \(error.localizedDescription)") }
    return try listJSON(cal)
}

func toolSetListColor(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let ref = try requiredStringArg(a["list"], name: "list")
    let color = try requiredStringArg(a["color"], name: "color")
    let cal = try resolveCalendar(ref)
    cal.color = try nsColorFromHex(color)
    do { try store.saveCalendar(cal, commit: true) }
    catch { throw MCPErr("saveCalendar failed: \(error.localizedDescription)") }
    return try listJSON(cal)
}

func toolDeleteList(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let ref = try requiredStringArg(a["list"], name: "list")
    let targetRef = try optionalStringArg(a["move_to"], name: "move_to")
    let cal = try resolveCalendar(ref)
    let sourceName = cal.title
    if let targetRef {
        let target = try resolveCalendar(targetRef)
        guard target.calendarIdentifier != cal.calendarIdentifier else {
            throw MCPErr("move_to must be a different list")
        }
        guard target.allowsContentModifications else {
            throw MCPErr("Target list \"\(target.title)\" does not allow modifications")
        }
        let targetName = target.title
        let reminders = try fetchReminders(store.predicateForReminders(in: [cal]))

        // Stage every move and the list removal, then commit once. Committing
        // each reminder separately could leave a half-moved list when a later
        // save failed. reset() discards uncommitted EventKit changes on error.
        do {
            for reminder in reminders {
                reminder.calendar = target
                try store.save(reminder, commit: false)
            }
            try store.removeCalendar(cal, commit: false)
            try store.commit()
        } catch {
            store.reset()
            throw MCPErr("delete_list could not move all reminders and remove \"\(sourceName)\": \(error.localizedDescription)")
        }
        return [
            "deleted": true,
            "name": sourceName,
            "moved_count": reminders.count,
            "moved_to": targetName,
        ]
    }
    do { try store.removeCalendar(cal, commit: true) }
    catch {
        store.reset()
        throw MCPErr("removeCalendar failed: \(error.localizedDescription)")
    }
    return ["deleted": true, "name": sourceName, "moved_count": 0]
}

// MARK: - Reminder tools

func toolListReminders(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let includeCompleted = try boolArg(a["include_completed"], name: "include_completed", default: false)
    let completedOnly = try boolArg(a["completed_only"], name: "completed_only", default: false)
    let hasDue = try boolArg(a["has_due_date"], name: "has_due_date", default: false)
    let query = try optionalStringArg(a["query"], name: "query")
    let notesQuery = try optionalStringArg(a["notes_query"], name: "notes_query")
    let locationLike = try optionalStringArg(a["location_like"], name: "location_like")
    // Unparseable bounds are a hard error, not a silently-dropped filter: a
    // wrong query that quietly degrades to "no filter" looks like a right one.
    let from: Date?
    if let s = try optionalStringArg(a["due_from"], name: "due_from") {
        from = try parseBoundary(s, upperBoundDateOnlySpansDay: false)
    } else {
        from = nil
    }
    let to: Date?
    if let s = try optionalStringArg(a["due_until"], name: "due_until") {
        to = try parseBoundary(s, upperBoundDateOnlySpansDay: true)
    } else {
        to = nil
    }
    let limit = try optionalIntegerArg(a["limit"], name: "limit") ?? 50
    guard (1...500).contains(limit) else { throw MCPErr("limit must be 1-500") }

    // Single safe factory (see fetchReminders:) — all narrowing in Swift.
    let cals: [EKCalendar]?
    if let list = try optionalStringArg(a["list"], name: "list") {
        cals = [try resolveCalendar(list)]
    } else {
        cals = nil
    }

    var out = try fetchReminders(store.predicateForReminders(in: cals))
    if completedOnly {
        out = out.filter { $0.isCompleted }
        if let from { out = out.filter { ($0.completionDate ?? .distantPast) >= from } }
        if let to { out = out.filter { ($0.completionDate ?? .distantPast) <= to } }
    } else {
        if !includeCompleted { out = out.filter { !$0.isCompleted } }
        if from != nil || to != nil {
            out = out.filter { r in
                guard let dc = r.dueDateComponents, let d = gregorian.date(from: dc) else { return false }
                if let from, d < from { return false }
                if let to, d > to { return false }
                return true
            }
        }
    }
    if hasDue { out = out.filter { $0.dueDateComponents != nil } }
    if let q = query { out = out.filter { cdContains($0.title, q) } }
    if let nq = notesQuery { out = out.filter { cdContains($0.notes, nq) } }
    if let ll = locationLike { out = out.filter { cdContains($0.location, ll) } }

    // dueDateComponents is NSDateComponents — sort in Swift.
    let sorted = out.sorted { (l: EKReminder, r: EKReminder) -> Bool in
        let dl = l.dueDateComponents.flatMap { gregorian.date(from: $0) }
        let dr = r.dueDateComponents.flatMap { gregorian.date(from: $0) }
        switch (dl, dr) {
        case let (x?, y?):
            if x != y { return x < y }
            return (l.title ?? "").localizedCaseInsensitiveCompare(r.title ?? "") == .orderedAscending
        case (nil, nil):
            // deterministic order among no-due reminders (Swift sort isn't stable)
            return (l.title ?? "").localizedCaseInsensitiveCompare(r.title ?? "") == .orderedAscending
        case (nil, _):
            return false   // no due date sorts last
        case (_, nil):
            return true
        }
    }
    let page = Array(sorted.prefix(limit))
    return [
        "count": page.count,
        "total": sorted.count,
        "truncated": sorted.count > limit,
        "reminders": page.map(reminderJSON),
    ]
}

func toolGetReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    return reminderJSON(try resolveReminder(a))
}

func toolCreateReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let title = try requiredStringArg(a["title"], name: "title")
    let listName = try optionalStringArg(a["list_name"], name: "list_name")
    let notes = try optionalStringArg(a["notes"], name: "notes", allowEmpty: true)
    let urlText = try optionalStringArg(a["url"], name: "url", allowEmpty: true)
    let location = try optionalStringArg(a["location"], name: "location", allowEmpty: true)
    let dueText = try optionalStringArg(a["due"], name: "due")
    let startText = try optionalStringArg(a["start"], name: "start")
    let alarmInputs = try optionalObjectArrayArg(a["alarms"], name: "alarms")
    let recurrenceInput = try optionalObjectArg(a["recurrence"], name: "recurrence")

    let priority: Int?
    if a.keys.contains("priority") { priority = try parsePriority(a["priority"]) }
    else { priority = nil }
    let due = try dueText.map(dueComponents)
    let start = try startText.map(dueComponents)
    let alarms = try alarmInputs?.map(alarmFrom)
    let recurrence = try recurrenceInput.map(recurrenceFrom)
    let parsedURL: URL?
    if let urlText, !urlText.isEmpty {
        guard let url = URL(string: urlText) else { throw MCPErr("Invalid url: \(urlText)") }
        parsedURL = url
    } else {
        parsedURL = nil
    }

    let list: EKCalendar
    if let listName {
        list = try resolveCalendar(listName)
    } else if let d = store.defaultCalendarForNewReminders() {
        list = d
    } else {
        throw MCPErr("No default list for new reminders — pass list_name")
    }

    var r = EKReminder(eventStore: store)
    r.calendar = list
    r.title = title
    if let notes { r.notes = notes.isEmpty ? nil : notes }
    if urlText != nil { r.url = parsedURL }
    if let location { r.location = location.isEmpty ? nil : location }
    if let priority { r.priority = priority }
    if let due { r.dueDateComponents = due }
    if let start { r.startDateComponents = start }
    if let alarms { r.alarms = alarms }
    if let recurrence { r.recurrenceRules = [recurrence] }

    do { try store.save(r, commit: true) }
    catch {
        store.reset()
        throw MCPErr("save failed: \(error.localizedDescription)")
    }
    if r.calendarItemIdentifier.isEmpty {
        // Some backends assign the identifier only after a re-fetch. Among
        // title matches the one we just created is the newest by creation
        // date — fetch order is unspecified, so an unordered `last` could
        // hand back the id of an older reminder with the same title.
        let fetched = try fetchReminders(store.predicateForReminders(in: [list]))
            .filter { cdEqual($0.title, title) }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        if let newest = fetched.last { r = newest }
    }
    if r.calendarItemIdentifier.isEmpty {
        throw MCPErr("Reminder saved, but EventKit has not exposed its identifier yet — fetch it with get_reminder (title + list_name)")
    }
    var out = reminderJSON(r)
    out["created"] = true
    return out
}

func toolUpdateReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let r = try resolveReminder(a)

    // Validate and construct every requested value before mutating the EventKit
    // object. A malformed later field must not leave earlier changes pending in
    // the shared store, where a future commit could persist them accidentally.
    let newTitle = try optionalStringArg(a["title"], name: "title")
    let notes = try optionalStringArg(a["notes"], name: "notes", allowEmpty: true)
    let urlText = try optionalStringArg(a["url"], name: "url", allowEmpty: true)
    let location = try optionalStringArg(a["location"], name: "location", allowEmpty: true)
    let dueText = try optionalStringArg(a["due"], name: "due")
    let startText = try optionalStringArg(a["start"], name: "start")
    let alarmInputs = try optionalObjectArrayArg(a["alarms"], name: "alarms")
    let recurrenceInput = try optionalObjectArg(a["recurrence"], name: "recurrence")
    let move = try optionalStringArg(a["move_to_list"], name: "move_to_list")
    let removeDue = try boolArg(a["remove_due"], name: "remove_due", default: false)
    let removeStart = try boolArg(a["remove_start"], name: "remove_start", default: false)
    let clearAlarm = try boolArg(a["clear_alarm"], name: "clear_alarm", default: false)
    let clearRecurrence = try boolArg(a["clear_recurrence"], name: "clear_recurrence", default: false)

    if dueText != nil && removeDue { throw MCPErr("due and remove_due cannot be used together") }
    if startText != nil && removeStart { throw MCPErr("start and remove_start cannot be used together") }
    if alarmInputs != nil && clearAlarm { throw MCPErr("alarms and clear_alarm cannot be used together") }
    if recurrenceInput != nil && clearRecurrence {
        throw MCPErr("recurrence and clear_recurrence cannot be used together")
    }

    let priority: Int?
    if a.keys.contains("priority") { priority = try parsePriority(a["priority"]) }
    else { priority = nil }
    let due = try dueText.map(dueComponents)
    let start = try startText.map(dueComponents)
    let alarms = try alarmInputs?.map(alarmFrom)
    let recurrence = try recurrenceInput.map(recurrenceFrom)
    let target = try move.map(resolveCalendar)
    let parsedURL: URL?
    if let urlText, !urlText.isEmpty {
        guard let url = URL(string: urlText) else { throw MCPErr("Invalid url: \(urlText)") }
        parsedURL = url
    } else {
        parsedURL = nil
    }

    if let newTitle { r.title = newTitle }
    if let notes { r.notes = notes.isEmpty ? nil : notes }
    if urlText != nil { r.url = parsedURL }
    if let location { r.location = location.isEmpty ? nil : location }
    if let priority { r.priority = priority }
    if let due { r.dueDateComponents = due }
    if let start { r.startDateComponents = start }
    if removeDue { r.dueDateComponents = nil }
    if removeStart { r.startDateComponents = nil }
    if let alarms { r.alarms = alarms }
    if clearAlarm { r.alarms = [] }
    if let recurrence { r.recurrenceRules = [recurrence] }
    if clearRecurrence { r.recurrenceRules = [] }
    if let target { r.calendar = target }

    do { try store.save(r, commit: true) }
    catch {
        store.reset()
        throw MCPErr("save failed: \(error.localizedDescription)")
    }
    return reminderJSON(r)
}

func toolCompleteReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let r = try resolveReminder(a)
    if let at = try optionalStringArg(a["completed_at"], name: "completed_at") {
        guard let d = parseDue(at)?.date else { throw MCPErr("Bad completed_at date \"\(at)\"") }
        r.completionDate = d   // implies completed
    } else {
        r.isCompleted = true    // sets completionDate to now automatically
    }
    do { try store.save(r, commit: true) }
    catch { throw MCPErr("save failed: \(error.localizedDescription)") }
    return reminderJSON(r)
}

func toolUncompleteReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let r = try resolveReminder(a)
    r.isCompleted = false
    do { try store.save(r, commit: true) }
    catch { throw MCPErr("save failed: \(error.localizedDescription)") }
    return reminderJSON(r)
}

func toolDeleteReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let r = try resolveReminder(a)
    do { try store.remove(r, commit: true) }
    catch { throw MCPErr("remove failed: \(error.localizedDescription)") }
    return ["deleted": true, "identifier": r.calendarItemIdentifier, "title": r.title ?? NSNull()]
}

/// Drain a child process's stderr pipe (safe once the process has exited).
func errText(_ pipe: Pipe) -> String {
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
