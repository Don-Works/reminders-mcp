// reminders-mcp — recurrence + alarm construction and serialization.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import Foundation
import EventKit

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
/// workdays 5, months 6, weeks 7. 8 ("days") exists in the ObjC enum but
/// EKRecurrenceRule silently stores it as raw 0 (an invalid rule) — probed
/// 2026-09-08 — so it is rejected on the way in but still labelled on the way
/// out, in case another client manages to create such a rule.
let frequencyRawToName: [Int: String] = [
    1: "daily", 2: "weekly", 3: "monthly", 4: "yearly",
    5: "workdays", 6: "months", 7: "weeks", 8: "days",
]
let frequencyNameToRaw: [String: Int] = [
    "daily": 1, "weekly": 2, "monthly": 3, "yearly": 4,
    "workdays": 5, "months": 6, "weeks": 7,
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

// MARK: - Construction

public func alarmFrom(_ a: [String: Any]) throws -> EKAlarm {
    if let m = a["minutes"] as? Int {
        return EKAlarm(relativeOffset: TimeInterval(m * 60))
    }
    if let d = argString(a["date"]) {
        guard let dt = parseDue(d)?.date else { throw MCPErr("Bad alarm date \"\(d)\"") }
        return EKAlarm(absoluteDate: dt)
    }
    throw MCPErr("Each alarm must be {minutes: N} or {date: ISO-8601}")
}

/// Build an EKRecurrenceRule with every numeric field range-checked. Unchecked
/// values can raise an uncatchable ObjC exception inside EKRecurrenceRule's
/// initializers — which kills the whole server process, not just the call.
public func recurrenceFrom(_ a: [String: Any]) throws -> EKRecurrenceRule {
    // NOTE: the failable inits of these @objc enums are NOT actually failable
    // on this SDK — EKRecurrenceFrequency(rawValue: 9) and EKWeekday(rawValue: 0)
    // both return a non-nil zeroed/invalid case. Never trust them to reject
    // out-of-range values; range-check the Int first. An invalid value that
    // reaches EKRecurrenceRule's init raises an uncatchable ObjC exception,
    // which kills the whole server process instead of failing one call.
    let freqRaw: Int
    if let f = a["frequency"] as? Int {
        guard (1...7).contains(f) else {
            throw MCPErr("recurrence.frequency integer must be 1-7 (daily/weekly/monthly/yearly/workdays/months/weeks); 8 (\"days\") is silently dropped by this SDK's EKRecurrenceRule")
        }
        freqRaw = f
    } else if let f = a["frequency"] as? String {
        guard let r = frequencyNameToRaw[f.lowercased()] else {
            throw MCPErr("recurrence.frequency must be daily/weekly/monthly/yearly/workdays/months/weeks")
        }
        freqRaw = r
    } else {
        throw MCPErr("recurrence.frequency is required")
    }
    if let iv = a["interval"] as? Int, iv < 1 {
        throw MCPErr("recurrence.interval must be >= 1")
    }
    let interval = max(1, (a["interval"] as? Int) ?? 1)

    let end: EKRecurrenceEnd?
    if let count = a["count"] as? Int {
        // 0 used to slip through as "no end" — an accidental infinite recurrence.
        guard count > 0 else { throw MCPErr("recurrence.count must be >= 1") }
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
            // Explicit range check: EKWeekday(rawValue:) is non-failable here (see note above).
            guard (1...7).contains(d) else {
                throw MCPErr("recurrence.days_of_week values must be 1-7 (1=Sunday)")
            }
            dows.append(EKRecurrenceDayOfWeek(EKWeekday(rawValue: d)!))
        }
    }

    let dom = try validInts("days_of_month", a["days_of_month"] as? [Int], 1...31)
    let moy = try validInts("months_of_year", a["months_of_year"] as? [Int], 1...12)
    let woy = try validInts("weeks_of_year", a["weeks_of_year"] as? [Int], 1...53)
    let doy = try validInts("days_of_year", a["days_of_year"] as? [Int], 1...366)
    let sp: [NSNumber]
    if let arr = a["set_positions"] as? [Int] {
        for v in arr where !(1...6).contains(abs(v)) {
            throw MCPErr("recurrence.set_positions values must be ±1 to ±6")
        }
        sp = arr.map { NSNumber(value: $0) }
    } else {
        sp = []
    }

    guard let freq = EKRecurrenceFrequency(rawValue: freqRaw) else {
        throw MCPErr("Bad recurrence frequency")
    }
    // Sanity: freqRaw is 1-7 so this is always non-nil-and-valid; keep the check
    // as a tripwire against a future SDK that makes the init actually failable.
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

private func validInts(_ name: String, _ values: [Int]?, _ range: ClosedRange<Int>) throws -> [NSNumber] {
    guard let values else { return [] }
    for v in values where !range.contains(v) {
        throw MCPErr("recurrence.\(name) value \(v) out of range \(range.lowerBound)-\(range.upperBound)")
    }
    return values.map { NSNumber(value: $0) }
}
