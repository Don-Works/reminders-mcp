// reminders-mcp — a standalone MCP server for Apple Reminders.
//
// Swift + EventKit, JSON-RPC 2.0 over stdio (newline-delimited JSON, no
// Content-Length header). See docs/tool-spec.md and docs/eventkit-surface.md.
//
// AGPL-3.0.

import Foundation
import AppKit
import EventKit

// MARK: - Errors

struct MCPErr: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Globals

let store = EKEventStore()

enum AccessState { case unknown, granted, denied(String) }
var access: AccessState = .unknown

let serverName = "reminders-mcp"
let serverVersion = "0.1.0"
let knownProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

// MARK: - JSON helpers

func jsonString(_ object: Any) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: []),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return String(describing: object)
}

/// Extract a non-empty trimmed string from an argument value.
func argString(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func argBool(_ value: Any?, default def: Bool) -> Bool {
    (value as? Bool) ?? def
}

// MARK: - Dates

let gregorian = Calendar(identifier: .gregorian)
let isoFormatter = ISO8601DateFormatter()

/// Floating components rendered with this machine's current offset, so a reminder set for
/// 14:00 reads back as 14:00 and not as its UTC equivalent.
let localISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

func iso8601(_ date: Date) -> String {
    isoFormatter.string(from: date)
}

struct ParsedDue {
    let date: Date
    let dateOnly: Bool
}

/// Accepts full ISO-8601 (with Z/offset or local time) and bare YYYY-MM-DD
/// (all-day). Local forms are interpreted in the current time zone.
func parseDue(_ s: String) -> ParsedDue? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Current zone, not UTC: a bare date is compared against reminder due dates, which
        // EventKit materialises as local wall-clock. Parsing the boundary in UTC put the two
        // an offset apart and moved which reminders a due_from/due_until range caught.
        if let d = f.date(from: t) { return ParsedDue(date: d, dateOnly: true) }
    }
    if let d = isoFormatter.date(from: t) { return ParsedDue(date: d, dateOnly: false) }
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        let f = DateFormatter()
        f.dateFormat = fmt
        f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: t) { return ParsedDue(date: d, dateOnly: false) }
    }
    return nil
}

/// Build dueDateComponents / startDateComponents from a user date string.
/// Year/month/day only ⇒ all-day. Time zone left unset (floating).
func dueComponents(_ s: String) throws -> DateComponents {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let ymd = bareDateComponents(t) { return ymd }
    guard let p = parseDue(t) else {
        throw MCPErr("Unparseable date \"\(s)\" — use ISO-8601 or YYYY-MM-DD")
    }
    var c = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.date)
    c.timeZone = nil
    return c
}

/// Year/month/day taken straight from the string. A bare date carries no time zone, so
/// routing it through a Date — parsed in one zone, decomposed in another — is what made
/// "2026-07-01" arrive as 30 June wherever the two zones disagree.
func bareDateComponents(_ s: String) -> DateComponents? {
    guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
    let parts = s.split(separator: "-")
    guard let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
          (1...12).contains(m), (1...31).contains(d) else { return nil }
    var c = DateComponents()
    c.year = y
    c.month = m
    c.day = d
    return c
}

/// All-day reminders serialize as the bare date they were set to. Rendering floating
/// components as an absolute instant is what turned an all-day 1 July into
/// "2026-06-30T23:00:00Z" under BST — the previous day, every summer date, silently.
func isoFromComponents(_ c: DateComponents?) -> String? {
    guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
    if isAllDay(c) { return String(format: "%04d-%02d-%02d", y, m, d) }
    guard let date = gregorian.date(from: c) else { return nil }
    return localISOFormatter.string(from: date)
}

func isAllDay(_ c: DateComponents?) -> Bool {
    guard let c else { return false }
    return c.hour == nil && c.minute == nil && c.second == nil
}

// MARK: - Priority

/// EventKit on this SDK only accepts 0, 1, 5, 9 — other values fail the save.
func parsePriority(_ v: Any?) throws -> Int {
    if let i = v as? Int {
        guard [0, 1, 5, 9].contains(i) else { throw MCPErr("priority must be 0, 1, 5 or 9") }
        return i
    }
    switch (v as? String)?.lowercased() {
    case "none", "0": return 0
    case "high", "1": return 1
    case "medium", "5": return 5
    case "low", "9": return 9
    default: throw MCPErr("priority must be none/high/medium/low or one of 0, 1, 5, 9")
    }
}

func priorityName(_ p: Int) -> String {
    switch p {
    case 1: return "high"
    case 5: return "medium"
    case 9: return "low"
    default: return "none"
    }
}

// MARK: - Colors

func hexFromNSColor(_ c: NSColor) -> String {
    guard let rgb = c.usingColorSpace(.sRGB) else { return "#000000" }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", min(r, 255), min(g, 255), min(b, 255))
}

func nsColorFromHex(_ hex: String) throws -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else {
        throw MCPErr("color must be #RRGGBB")
    }
    return NSColor(
        red: CGFloat((v >> 16) & 0xFF) / 255.0,
        green: CGFloat((v >> 8) & 0xFF) / 255.0,
        blue: CGFloat(v & 0xFF) / 255.0,
        alpha: 1.0
    )
}

// MARK: - EventKit access + fetch

func ensureAccess() throws {
    switch access {
    case .granted: return
    case .denied(let why): throw MCPErr("Reminders access denied: \(why)")
    case .unknown:
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
            access = .denied(why.isEmpty ? "unknown reason" : why)
            throw MCPErr("Reminders access denied: \(why)")
        }
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
func fetchReminders(_ predicate: NSPredicate) -> [EKReminder] {
    var out: [EKReminder] = []
    let sem = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: predicate) { reminders in
        out = reminders ?? []
        sem.signal()
    }
    if sem.wait(timeout: .now() + 10) == .timedOut {
        FileHandle.standardError.write("reminders-mcp: fetchReminders timed out\n".data(using: .utf8)!)
    }
    return out
}

func allReminderCalendars() -> [EKCalendar] {
    store.calendars(for: .reminder)
}

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

/// Case- and diacritic-insensitive comparison (the "[cd]" semantics).
func cdEqual(_ a: String?, _ b: String) -> Bool {
    guard let a else { return false }
    return a.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        == b.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
}
func cdContains(_ a: String?, _ needle: String) -> Bool {
    guard let a, !needle.isEmpty else { return false }
    let hay = a.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    let n = needle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    return hay.range(of: n) != nil
}

/// Resolve a reminder by identifier, or by exact (case/diacritic-insensitive)
/// title within an optional list. Ambiguous titles list up to 10 candidates.
func resolveReminder(_ args: [String: Any]) throws -> EKReminder {
    if let id = argString(args["identifier"]) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw MCPErr("No reminder with identifier \(id)")
        }
        return r
    }
    guard let title = argString(args["title"]) else {
        throw MCPErr("Provide identifier, or title with optional list_name")
    }
    let cals: [EKCalendar]?
    if let listName = argString(args["list_name"]) {
        cals = [try resolveCalendar(listName)]
    } else {
        cals = nil
    }
    let matches = fetchReminders(store.predicateForReminders(in: cals))
        .filter { cdEqual($0.title, title) }
    switch matches.count {
    case 0:
        let scope = argString(args["list_name"]).map { " in list \"\($0)\"" } ?? ""
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

// MARK: - Serialization

func alarmJSON(_ a: EKAlarm) -> [String: Any] {
    var o: [String: Any] = [:]
    if let d = a.absoluteDate {
        o["type"] = "absolute"
        o["date"] = iso8601(d)
    } else if a.relativeOffset != 0 {
        o["type"] = "relative"
        o["offset_seconds"] = a.relativeOffset
    } else if let e = a.emailAddress {
        o["type"] = "email"
        o["email"] = e
    } else if let s = a.soundName {
        o["type"] = "sound"
        o["sound"] = s
    } else {
        o["type"] = "unknown"
    }
    return o
}

/// Raw values verified on this SDK: daily 1, weekly 2, monthly 3, yearly 4,
/// workdays 5, months 6, weeks 7, days 8.
let frequencyRawToName: [Int: String] = [
    1: "daily", 2: "weekly", 3: "monthly", 4: "yearly",
    5: "workdays", 6: "months", 7: "weeks", 8: "days",
]
let frequencyNameToRaw: [String: Int] = [
    "daily": 1, "weekly": 2, "monthly": 3, "yearly": 4,
    "workdays": 5, "months": 6, "weeks": 7, "days": 8,
]

func recurrenceJSON(_ r: EKRecurrenceRule) -> [String: Any] {
    var o: [String: Any] = [
        "frequency": frequencyRawToName[r.frequency.rawValue] ?? "other",
        "interval": r.interval,
    ]
    if let d = r.daysOfTheWeek, !d.isEmpty { o["days_of_week"] = d.map { $0.dayOfTheWeek.rawValue } }
    if let d = r.daysOfTheMonth, !d.isEmpty { o["days_of_month"] = d }
    if let m = r.monthsOfTheYear, !m.isEmpty { o["months_of_year"] = m }
    if let w = r.weeksOfTheYear, !w.isEmpty { o["weeks_of_year"] = w }
    if let y = r.daysOfTheYear, !y.isEmpty { o["days_of_year"] = y }
    if let s = r.setPositions, !s.isEmpty { o["set_positions"] = s }
    if let e = r.recurrenceEnd {
        if e.occurrenceCount > 0 { o["count"] = e.occurrenceCount }
        if let d = e.endDate { o["until"] = iso8601(d) }
    }
    return o
}

func reminderJSON(_ r: EKReminder) -> [String: Any] {
    var o: [String: Any] = [
        "identifier": r.calendarItemIdentifier,
        "title": r.title ?? NSNull(),
        "list": r.calendar?.title ?? NSNull(),
        "list_id": r.calendar?.calendarIdentifier ?? NSNull(),
        "notes": r.notes ?? NSNull(),
        "url": r.url?.absoluteString ?? NSNull(),
        "location": r.location ?? NSNull(),
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

func listJSON(_ c: EKCalendar) -> [String: Any] {
    let all = fetchReminders(store.predicateForReminders(in: [c]))
    let open = all.filter { !$0.isCompleted }.count
    return [
        "id": c.calendarIdentifier,
        "name": c.title,
        "color": hexFromNSColor(c.color),
        "subscribed": c.isSubscribed,
        "allows_modifications": c.allowsContentModifications,
        "immutable": c.isImmutable,
        "source": c.source?.title ?? NSNull(),
        "open_count": open,
        "completed_count": all.count - open,
    ]
}

// MARK: - Field builders

func alarmFrom(_ a: [String: Any]) throws -> EKAlarm {
    if let m = a["minutes"] as? Int {
        return EKAlarm(relativeOffset: TimeInterval(m * 60))
    }
    if let d = argString(a["date"]) {
        guard let dt = parseDue(d)?.date else { throw MCPErr("Bad alarm date \"\(d)\"") }
        return EKAlarm(absoluteDate: dt)
    }
    throw MCPErr("Each alarm must be {minutes: N} or {date: ISO-8601}")
}

func recurrenceFrom(_ a: [String: Any]) throws -> EKRecurrenceRule {
    let freqRaw: Int
    if let f = a["frequency"] as? Int {
        guard (1...8).contains(f) else { throw MCPErr("recurrence.frequency integer must be 1-8") }
        freqRaw = f
    } else if let f = a["frequency"] as? String {
        guard let r = frequencyNameToRaw[f.lowercased()] else {
            throw MCPErr("recurrence.frequency must be daily/weekly/monthly/yearly/workdays/months/weeks/days")
        }
        freqRaw = r
    } else {
        throw MCPErr("recurrence.frequency is required")
    }
    let interval = max(1, (a["interval"] as? Int) ?? 1)

    let end: EKRecurrenceEnd?
    if let count = a["count"] as? Int, count > 0 {
        end = EKRecurrenceEnd(occurrenceCount: count)
    } else if let until = argString(a["until"]) {
        guard let d = parseDue(until)?.date else { throw MCPErr("Bad recurrence.until date \"\(until)\"") }
        end = EKRecurrenceEnd(end: d)
    } else {
        end = nil
    }

    var dows: [EKRecurrenceDayOfWeek] = []
    if let arr = a["days_of_week"] as? [Int] {
        for d in arr {
            guard let w = EKWeekday(rawValue: d) else {
                throw MCPErr("days_of_week values must be 1-7 (1=Sunday)")
            }
            dows.append(EKRecurrenceDayOfWeek(w))
        }
    }

    guard let freq = EKRecurrenceFrequency(rawValue: freqRaw) else {
        throw MCPErr("Bad recurrence frequency")
    }
    let dom: [NSNumber] = ((a["days_of_month"] as? [Int]) ?? []).map { NSNumber(value: $0) }
    let moy: [NSNumber] = ((a["months_of_year"] as? [Int]) ?? []).map { NSNumber(value: $0) }
    let woy: [NSNumber] = ((a["weeks_of_year"] as? [Int]) ?? []).map { NSNumber(value: $0) }
    let doy: [NSNumber] = ((a["days_of_year"] as? [Int]) ?? []).map { NSNumber(value: $0) }
    let sp: [NSNumber] = ((a["set_positions"] as? [Int]) ?? []).map { NSNumber(value: $0) }
    return EKRecurrenceRule(
        recurrenceWith: freq,
        interval: interval,
        daysOfTheWeek: dows,
        daysOfTheMonth: dom,
        monthsOfTheYear: moy,
        weeksOfTheYear: woy,
        daysOfTheYear: doy,
        setPositions: sp,
        end: end
    )
}

// MARK: - List tools

func toolListLists(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let includeEmpty = argBool(a["include_empty"], default: true)
    let all = allReminderCalendars().map(listJSON)
    let lists = includeEmpty ? all : all.filter { ($0["open_count"] as? Int) ?? 0 > 0 || ($0["completed_count"] as? Int) ?? 0 > 0 }
    return ["count": lists.count, "lists": lists]
}

/// This SDK has no createCalendar on EKEventStore — new lists go through
/// AppleScript to Reminders.app, then re-fetch via EventKit.
func toolCreateList(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    guard let name = argString(a["name"]) else { throw MCPErr("name is required") }
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
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw MCPErr("AppleScript list creation failed:\(msg.isEmpty ? "" : " ")\(msg)")
    }

    let cal = try resolveCalendar(name)
    if let color = argString(a["color"]) {
        cal.color = try nsColorFromHex(color)
        do { try store.saveCalendar(cal, commit: true) }
        catch { throw MCPErr("List created, but saving its color failed: \(error.localizedDescription)") }
    }
        var out = listJSON(cal)
        out["created"] = true
        return out
}

func toolRenameList(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    guard let ref = argString(a["list"]), let newName = argString(a["new_name"]) else {
        throw MCPErr("list and new_name are required")
    }
    let cal = try resolveCalendar(ref)
    cal.title = newName
    do { try store.saveCalendar(cal, commit: true) }
    catch { throw MCPErr("saveCalendar failed: \(error.localizedDescription)") }
    return listJSON(cal)
}

func toolSetListColor(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    guard let ref = argString(a["list"]), let color = argString(a["color"]) else {
        throw MCPErr("list and color are required")
    }
    let cal = try resolveCalendar(ref)
    cal.color = try nsColorFromHex(color)
    do { try store.saveCalendar(cal, commit: true) }
    catch { throw MCPErr("saveCalendar failed: \(error.localizedDescription)") }
    return listJSON(cal)
}

func toolDeleteList(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    guard let ref = argString(a["list"]) else { throw MCPErr("list is required") }
    let cal = try resolveCalendar(ref)
    if let targetRef = argString(a["move_to"]) {
        let target = try resolveCalendar(targetRef)
        for r in fetchReminders(store.predicateForReminders(in: [cal])) {
            r.calendar = target
            do { try store.save(r, commit: true) }
            catch { throw MCPErr("Failed to move \"\(r.title ?? "")\" to \(target.title): \(error.localizedDescription)") }
        }
    }
    do { try store.removeCalendar(cal, commit: true) }
    catch { throw MCPErr("removeCalendar failed: \(error.localizedDescription)") }
    return ["deleted": true, "name": cal.title]
}

// MARK: - Reminder tools

func toolListReminders(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let includeCompleted = argBool(a["include_completed"], default: false)
    let completedOnly = argBool(a["completed_only"], default: false)
    let hasDue = argBool(a["has_due_date"], default: false)
    let query = argString(a["query"])
    let notesQuery = argString(a["notes_query"])
    let locationLike = argString(a["location_like"])
    let from = argString(a["due_from"]).flatMap { parseDue($0)?.date }
    let to = argString(a["due_until"]).flatMap { parseDue($0)?.date }
    var limit = (a["limit"] as? Int) ?? 50
    limit = min(max(limit, 1), 500)

    // Single safe factory (see fetchReminders:) — all narrowing in Swift.
    let cals: [EKCalendar]?
    if let list = argString(a["list"]) {
        cals = [try resolveCalendar(list)]
    } else {
        cals = nil
    }

    var out = fetchReminders(store.predicateForReminders(in: cals))
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
        case (nil, _):
            return false
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
    guard let title = argString(a["title"]) else { throw MCPErr("title is required") }

    let list: EKCalendar
    if let listName = argString(a["list_name"]) {
        list = try resolveCalendar(listName)
    } else if let d = store.defaultCalendarForNewReminders() {
        list = d
    } else {
        throw MCPErr("No default list for new reminders — pass list_name")
    }

    var r = EKReminder(eventStore: store)
    r.calendar = list
    r.title = title
    if let notes = a["notes"] as? String { r.notes = notes.isEmpty ? nil : notes }
    if let url = a["url"] as? String {
        if url.isEmpty { r.url = nil }
        else if let u = URL(string: url) { r.url = u }
        else { throw MCPErr("Invalid url: \(url)") }
    }
    if let location = a["location"] as? String { r.location = location.isEmpty ? nil : location }
    if let p = a["priority"] { r.priority = try parsePriority(p) }
    if let due = argString(a["due"]) { r.dueDateComponents = try dueComponents(due) }
    if let start = argString(a["start"]) { r.startDateComponents = try dueComponents(start) }
    if let alarms = a["alarms"] as? [[String: Any]] { r.alarms = try alarms.map(alarmFrom) }
    if let rec = a["recurrence"] as? [String: Any] { r.recurrenceRules = [try recurrenceFrom(rec)] }

    do { try store.save(r, commit: true) }
    catch { throw MCPErr("save failed: \(error.localizedDescription)") }
    if r.calendarItemIdentifier.isEmpty {
        // Some backends assign the identifier only after a re-fetch.
        let fetched = fetchReminders(store.predicateForReminders(in: [list]))
            .filter { cdEqual($0.title, title) }
        if let last = fetched.last { r = last }
    }
    var out = reminderJSON(r)
    out["created"] = true
    return out
}

func toolUpdateReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let r = try resolveReminder(a)
    if let t = argString(a["title"]) { r.title = t }
    if a["notes"] != nil {
        let n = a["notes"] as? String ?? ""
        r.notes = n.isEmpty ? nil : n
    }
    if a["url"] != nil {
        let u = a["url"] as? String ?? ""
        if u.isEmpty { r.url = nil }
        else if let url = URL(string: u) { r.url = url }
        else { throw MCPErr("Invalid url: \(u)") }
    }
    if a["location"] != nil {
        let l = a["location"] as? String ?? ""
        r.location = l.isEmpty ? nil : l
    }
    if let p = a["priority"] { r.priority = try parsePriority(p) }
    if let due = argString(a["due"]) { r.dueDateComponents = try dueComponents(due) }
    if let start = argString(a["start"]) { r.startDateComponents = try dueComponents(start) }
    if argBool(a["remove_due"], default: false) { r.dueDateComponents = nil }
    if argBool(a["remove_start"], default: false) { r.startDateComponents = nil }
    if let alarms = a["alarms"] as? [[String: Any]] { r.alarms = try alarms.map(alarmFrom) }
    if argBool(a["clear_alarm"], default: false) { r.alarms = [] }
    if let rec = a["recurrence"] as? [String: Any] { r.recurrenceRules = [try recurrenceFrom(rec)] }
    if argBool(a["clear_recurrence"], default: false) { r.recurrenceRules = [] }
    if let move = argString(a["move_to_list"]) { r.calendar = try resolveCalendar(move) }

    do { try store.save(r, commit: true) }
    catch { throw MCPErr("save failed: \(error.localizedDescription)") }
    return reminderJSON(r)
}

func toolCompleteReminder(_ a: [String: Any]) throws -> [String: Any] {
    try ensureAccess()
    let r = try resolveReminder(a)
    if let at = argString(a["completed_at"]) {
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

// MARK: - Tool schemas + dispatch table

func toolSchemas() -> [[String: Any]] {
    let lookupProps: [String: Any] = [
        "identifier": ["type": "string", "description": "Reminder calendarItemIdentifier (unambiguous)"],
        "title": ["type": "string", "description": "Exact title; use list_name to narrow"],
        "list_name": ["type": "string", "description": "List name or id to scope the title lookup"],
    ]
    let dueProp: [String: Any] = ["type": "string", "description": "ISO-8601, or YYYY-MM-DD for all-day"]
    let alarmItem: [String: Any] = [
        "type": "object",
        "description": "{minutes: N} for a relative alarm, or {date: ISO-8601} for absolute",
        "properties": [
            "minutes": ["type": "integer"],
            "date": ["type": "string"],
        ],
    ]
    let recurrenceProp: [String: Any] = [
        "type": "object",
        "properties": [
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly", "workdays", "months", "weeks", "days"]],
            "interval": ["type": "integer", "description": "Every N (default 1)"],
            "days_of_week": ["type": "array", "items": ["type": "integer"], "description": "1-7, 1=Sunday"],
            "days_of_month": ["type": "array", "items": ["type": "integer"]],
            "months_of_year": ["type": "array", "items": ["type": "integer"]],
            "weeks_of_year": ["type": "array", "items": ["type": "integer"]],
            "days_of_year": ["type": "array", "items": ["type": "integer"]],
            "set_positions": ["type": "array", "items": ["type": "integer"]],
            "until": ["type": "string", "description": "ISO-8601 end date"],
            "count": ["type": "integer", "description": "Occurrence count (alternative to until)"],
        ],
        "required": ["frequency"],
    ]

    return [
        [
            "name": "list_lists",
            "description": "List all reminder lists with id, name, color, flags, source, and open/completed counts.",
            "inputSchema": [
                "type": "object",
                "properties": ["include_empty": ["type": "boolean", "description": "Include lists with no reminders (default true)"]],
            ],
        ],
        [
            "name": "create_list",
            "description": "Create a new list via Reminders.app (AppleScript — this SDK has no EventKit calendar-creation API). May trigger a macOS automation permission prompt. Optional color applied via EventKit afterwards.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "color": ["type": "string", "description": "#RRGGBB"],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "rename_list",
            "description": "Rename a list by id or name.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "List name or id"],
                    "new_name": ["type": "string"],
                ],
                "required": ["list", "new_name"],
            ],
        ],
        [
            "name": "set_list_color",
            "description": "Set a list's color.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "List name or id"],
                    "color": ["type": "string", "description": "#RRGGBB"],
                ],
                "required": ["list", "color"],
            ],
        ],
        [
            "name": "delete_list",
            "description": "Delete a list. Optionally move its reminders to another list first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "List name or id"],
                    "move_to": ["type": "string", "description": "List name or id to re-home the reminders into"],
                ],
                "required": ["list"],
            ],
        ],
        [
            "name": "list_reminders",
            "description": "Query reminders with filters. Sorted by due date (none last), then title. Default: open reminders only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "Restrict to one list (name or id)"],
                    "include_completed": ["type": "boolean", "description": "Include completed (default false)"],
                    "completed_only": ["type": "boolean", "description": "Only completed; due_from/due_until then bound the completion date"],
                    "due_from": ["type": "string", "description": "Due on/after (ISO-8601 or YYYY-MM-DD)"],
                    "due_until": ["type": "string", "description": "Due on/before (ISO-8601 or YYYY-MM-DD)"],
                    "query": ["type": "string", "description": "Title contains (case/diacritic-insensitive)"],
                    "notes_query": ["type": "string", "description": "Notes contain"],
                    "location_like": ["type": "string", "description": "Location contains"],
                    "has_due_date": ["type": "boolean", "description": "Only reminders with a due date"],
                    "limit": ["type": "integer", "description": "Default 50, max 500"],
                ],
            ],
        ],
        [
            "name": "get_reminder",
            "description": "Fetch one reminder by identifier, or by exact title (optionally scoped to a list). Ambiguous titles return up to 10 candidates.",
            "inputSchema": [
                "type": "object",
                "properties": lookupProps,
            ],
        ],
        [
            "name": "create_reminder",
            "description": "Create a reminder. Due dates are ISO-8601 or YYYY-MM-DD (all-day); time zone left floating.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "list_name": ["type": "string", "description": "List name or id (default: the default list)"],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "location": ["type": "string"],
                    "priority": ["type": ["string", "integer"], "description": "none/high/medium/low or 0/1/5/9"],
                    "due": dueProp,
                    "start": ["type": "string", "description": "ISO-8601 or YYYY-MM-DD start of a period"],
                    "alarms": ["type": "array", "items": alarmItem],
                    "recurrence": recurrenceProp,
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "update_reminder",
            "description": "Update a reminder found by identifier or title+list_name. Pass empty string to clear notes/url/location. remove_due/remove_start/clear_alarm/clear_recurrence clear those fields; move_to_list moves it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": ["type": "string", "description": "Lookup title, or new title"],
                    "list_name": ["type": "string", "description": "Scope for the title lookup"],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "location": ["type": "string"],
                    "priority": ["type": ["string", "integer"], "description": "none/high/medium/low or 0/1/5/9"],
                    "due": dueProp,
                    "start": ["type": "string"],
                    "alarms": ["type": "array", "items": alarmItem, "description": "Replaces the alarm set"],
                    "recurrence": recurrenceProp,
                    "remove_due": ["type": "boolean"],
                    "remove_start": ["type": "boolean"],
                    "clear_alarm": ["type": "boolean"],
                    "clear_recurrence": ["type": "boolean"],
                    "move_to_list": ["type": "string", "description": "List name or id"],
                ],
            ],
        ],
        [
            "name": "complete_reminder",
            "description": "Mark a reminder completed (completion date now, or completed_at if given).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": lookupProps["title"]!,
                    "list_name": lookupProps["list_name"]!,
                    "completed_at": ["type": "string", "description": "ISO-8601 or YYYY-MM-DD"],
                ],
            ],
        ],
        [
            "name": "uncomplete_reminder",
            "description": "Mark a reminder incomplete again.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": lookupProps["title"]!,
                    "list_name": lookupProps["list_name"]!,
                ],
            ],
        ],
        [
            "name": "delete_reminder",
            "description": "Delete a reminder.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": lookupProps["title"]!,
                    "list_name": lookupProps["list_name"]!,
                ],
            ],
        ],
    ]
}

typealias ToolHandler = ([String: Any]) throws -> [String: Any]

let handlers: [String: ToolHandler] = [
    "list_lists": toolListLists,
    "create_list": toolCreateList,
    "rename_list": toolRenameList,
    "set_list_color": toolSetListColor,
    "delete_list": toolDeleteList,
    "list_reminders": toolListReminders,
    "get_reminder": toolGetReminder,
    "create_reminder": toolCreateReminder,
    "update_reminder": toolUpdateReminder,
    "complete_reminder": toolCompleteReminder,
    "uncomplete_reminder": toolUncompleteReminder,
    "delete_reminder": toolDeleteReminder,
]

// MARK: - JSON-RPC dispatch

func errorResponse(_ id: Any?, code: Int, message: String) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "error": ["code": code, "message": message],
    ]
}

func toolError(_ message: String) -> [String: Any] {
    [
        "content": [["type": "text", "text": message]],
        "isError": true,
    ]
}

func writeJSON(_ object: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)   // newline-delimited framing
        FileHandle.standardOutput.write(data)
    } catch {
        FileHandle.standardError.write("reminders-mcp: failed to serialize response: \(error)\n".data(using: .utf8)!)
    }
}

func resultInitialize(_ params: [String: Any]?) -> [String: Any] {
    let pv = (params?["protocolVersion"] as? String).flatMap { knownProtocolVersions.contains($0) ? $0 : nil } ?? "2024-11-05"
    return [
        "protocolVersion": pv,
        "capabilities": ["tools": ["listChanged": false]],
        "serverInfo": ["name": serverName, "version": serverVersion],
        "instructions": "Manage Apple Reminders on this Mac: lists and reminders with due dates, alarms, recurrences, priorities, notes, URLs, locations. Dates are ISO-8601; YYYY-MM-DD means all-day. New lists are created through Reminders.app (AppleScript).",
    ]
}

func handle(_ req: [String: Any]) -> [String: Any]? {
    guard let method = req["method"] as? String else {
        return errorResponse(req["id"], code: -32600, message: "Invalid request: missing method")
    }
    let id = req["id"]          // nil for notifications
    let isNotification = (id == nil) || (id is NSNull)
    let params = req["params"] as? [String: Any]

    var result: Any
    switch method {
    case "initialize":
        result = resultInitialize(params)
    case "ping":
        result = [String: Any]()
    case "tools/list":
        result = ["tools": toolSchemas()]
    case "notifications/initialized":
        return nil   // notification, never responds
    case "tools/call":
        if let name = params?["name"] as? String {
            if let handler = handlers[name] {
                let args: [String: Any] = params?["arguments"] as? [String: Any] ?? [:]
                let outcome = Result { try handler(args) }
                switch outcome {
                case let .success(out):
                    result = ["content": [["type": "text", "text": jsonString(out)]], "isError": false]
                case let .failure(err):
                    result = toolError(err.localizedDescription)
                }
            } else {
                result = toolError("Unknown tool: \(name)")
            }
        } else {
            result = toolError("tools/call requires a name")
        }
    default:
        if isNotification { return nil }
        return errorResponse(id, code: -32601, message: "Method not found: \(method)")
    }

    if isNotification { return nil }
    return ["jsonrpc": "2.0", "id": id!, "result": result]
}

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }
    let response: [String: Any]?
    do {
        guard let data = trimmed.data(using: .utf8) else { throw MCPErr("not UTF-8") }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let req = obj as? [String: Any] else { throw MCPErr("not a JSON object") }
        response = handle(req)
    } catch {
        response = errorResponse(nil, code: -32700, message: "Parse error: \(error.localizedDescription)")
    }
    if let r = response { writeJSON(r) }
}

