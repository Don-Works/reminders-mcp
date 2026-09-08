// reminders-mcp — date parsing and serialization.
//
// Two different things are mixed on purpose:
//  * Wall-clock *components* — how due dates are stored (floating, no time
//    zone) and what the user means by "9am" or a bare date.
//  * Absolute *instants* — completion/creation/last-modified times, which are
//    real points in time and serialize as UTC ISO-8601.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import Foundation

/// Local-time-zone Gregorian calendar: parses naive input, and materializes the
/// floating components EventKit stores into Dates for comparison/sorting.
public let gregorian = Calendar(identifier: .gregorian)

/// UTC ISO-8601, for absolute instants.
public let isoFormatter = ISO8601DateFormatter()

/// Same, but fractional seconds are accepted. (The default formatter rejects
/// "…09:00:00.5Z" — agents paste such strings from other tools.)
public let isoFormatterFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Floating components rendered with this machine's current offset, so a reminder set for
/// 14:00 reads back as 14:00 and not as its UTC equivalent.
public let localISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

public func iso8601(_ date: Date) -> String {
    isoFormatter.string(from: date)
}

public struct ParsedDue {
    public let date: Date
    public let dateOnly: Bool
}

/// Accepts full ISO-8601 (with Z/offset or local time), optional fractional
/// seconds, and bare YYYY-MM-DD (all-day). Local forms are interpreted in the
/// current time zone.
public func parseDue(_ s: String) -> ParsedDue? {
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
    if let d = isoFormatterFractional.date(from: t) { return ParsedDue(date: d, dateOnly: false) }
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        let f = DateFormatter()
        f.dateFormat = fmt
        f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: t) { return ParsedDue(date: d, dateOnly: false) }
    }
    return nil
}

/// Build dueDateComponents / startDateComponents from a user date string.
/// Year/month/day only ⇒ all-day. Time zone left unset (floating).
public func dueComponents(_ s: String) throws -> DateComponents {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let ymd = bareDateComponents(t) { return ymd }
    guard let p = parseDue(t) else {
        throw MCPErr("Unparseable date \"\(s)\" — use ISO-8601 or YYYY-MM-DD")
    }
    var c = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.date)
    c.timeZone = nil
    return c
}

/// Year/month/day taken straight from the string, validated against the
/// calendar (2099-02-30 comes back nil rather than as a components object
/// EventKit would choke on or silently normalize). A bare date carries no time
/// zone, so routing it through a Date — parsed in one zone, decomposed in
/// another — is what made "2026-07-01" arrive as 30 June wherever the two
/// zones disagree.
public func bareDateComponents(_ s: String) -> DateComponents? {
    guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
    let parts = s.split(separator: "-")
    guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
          (1...12).contains(m), (1...31).contains(d) else { return nil }
    var probe = DateComponents()
    probe.year = y
    probe.month = m
    probe.day = d
    guard let date = gregorian.date(from: probe),
          gregorian.component(.month, from: date) == m,
          gregorian.component(.day, from: date) == d else { return nil }
    return probe
}

/// All-day reminders serialize as the bare date they were set to. Rendering
/// floating components as an absolute instant is what turned an all-day 1
/// July into "2026-06-30T23:00:00Z" under BST — the previous day, every
/// summer date, silently.
public func isoFromComponents(_ c: DateComponents?) -> String? {
    guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
    if isAllDay(c) { return String(format: "%04d-%02d-%02d", y, m, d) }
    guard let date = gregorian.date(from: c) else { return nil }
    return localISOFormatter.string(from: date)
}

public func isAllDay(_ c: DateComponents?) -> Bool {
    guard let c else { return false }
    return c.hour == nil && c.minute == nil && c.second == nil
}

/// 23:59:59.999 of the local day `day` falls in, so a bare-date upper bound
/// ("due_until": "2099-12-31") includes the whole day rather than only its
/// midnight instant.
public func localEndOfDay(_ day: Date) -> Date {
    var c = gregorian.dateComponents([.year, .month, .day], from: day)
    c.hour = 23
    c.minute = 59
    c.second = 59
    c.nanosecond = 999_000_000
    return gregorian.date(from: c) ?? day
}

/// Parse a query boundary. Naive values and bare dates are local wall-clock
/// (the same footing stored due dates are compared on); Z/offset-suffixed
/// values are absolute instants. A bare date used as an *upper* bound spans
/// the whole day. Unparseable input is a hard error — silently dropping the
/// filter would make a wrong query look like a right one.
public func parseBoundary(_ s: String, upperBoundDateOnlySpansDay: Bool) throws -> Date {
    guard let p = parseDue(s) else {
        throw MCPErr("Unparseable date \"\(s)\" — use ISO-8601 or YYYY-MM-DD")
    }
    if p.dateOnly, upperBoundDateOnlySpansDay { return localEndOfDay(p.date) }
    return p.date
}
