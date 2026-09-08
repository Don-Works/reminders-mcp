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

/// A hundred years either side of the reminder. Wide enough for any real alarm, and it keeps
/// `m * 60` away from the overflow that traps — a Swift arithmetic trap is not catchable, so an
/// oversized `minutes` took the whole process down rather than failing the one call.
public let alarmMinutesLimit = 100 * 365 * 24 * 60
public let recurrenceIntegerLimit = Int(Int32.max)

public func alarmFrom(_ a: [String: Any]) throws -> EKAlarm {
    try rejectUnknownKeys(a, allowed: ["minutes", "date"], name: "alarm")
    let hasMinutes = a.keys.contains("minutes")
    let hasDate = a.keys.contains("date")
    guard hasMinutes != hasDate else {
        throw MCPErr("Each alarm must contain exactly one of minutes or date")
    }
    if hasMinutes {
        guard let m = try optionalIntegerArg(a["minutes"], name: "alarm.minutes") else {
            throw MCPErr("alarm.minutes is required")
        }
        guard (-alarmMinutesLimit...alarmMinutesLimit).contains(m) else {
            throw MCPErr("alarm.minutes must be within ±\(alarmMinutesLimit) (about a century)")
        }
        return EKAlarm(relativeOffset: TimeInterval(m * 60))
    }
    if let d = try optionalStringArg(a["date"], name: "alarm.date") {
        guard let dt = parseDue(d)?.date else { throw MCPErr("Bad alarm date \"\(d)\"") }
        return EKAlarm(absoluteDate: dt)
    }
    throw MCPErr("Each alarm must be {minutes: N} or {date: ISO-8601}")
}

/// Build an EKRecurrenceRule with every numeric field range-checked. Unchecked
/// values can raise an uncatchable ObjC exception inside EKRecurrenceRule's
/// initializers — which kills the whole server process, not just the call.
public func recurrenceFrom(_ a: [String: Any]) throws -> EKRecurrenceRule {
    try rejectUnknownKeys(
        a,
        allowed: [
            "frequency", "interval", "days_of_week", "days_of_month",
            "months_of_year", "weeks_of_year", "days_of_year", "set_positions",
            "until", "count",
        ],
        name: "recurrence"
    )
    // NOTE: the failable inits of these @objc enums are NOT actually failable
    // on this SDK — EKRecurrenceFrequency(rawValue: 9) and EKWeekday(rawValue: 0)
    // both return a non-nil zeroed/invalid case. Never trust them to reject
    // out-of-range values; range-check the Int first. An invalid value that
    // reaches EKRecurrenceRule's init raises an uncatchable ObjC exception,
    // which kills the whole server process instead of failing one call.
    let frequencyName = try requiredStringArg(a["frequency"], name: "recurrence.frequency").lowercased()
    guard let freqRaw = frequencyNameToRaw[frequencyName] else {
        throw MCPErr("recurrence.frequency must be daily/weekly/monthly/yearly/workdays/months/weeks")
    }
    let interval = try optionalIntegerArg(a["interval"], name: "recurrence.interval") ?? 1
    guard (1...recurrenceIntegerLimit).contains(interval) else {
        throw MCPErr("recurrence.interval must be 1-\(recurrenceIntegerLimit)")
    }

    let end: EKRecurrenceEnd?
    let count = try optionalIntegerArg(a["count"], name: "recurrence.count")
    let until = try optionalStringArg(a["until"], name: "recurrence.until")
    if count != nil && until != nil {
        throw MCPErr("recurrence.count and recurrence.until are alternatives; provide only one")
    }
    if let count {
        // 0 used to slip through as "no end" — an accidental infinite recurrence.
        guard (1...recurrenceIntegerLimit).contains(count) else {
            throw MCPErr("recurrence.count must be 1-\(recurrenceIntegerLimit)")
        }
        end = EKRecurrenceEnd(occurrenceCount: count)
    } else if let until {
        guard let d = parseDue(until)?.date else { throw MCPErr("Bad recurrence.until date \"\(until)\"") }
        end = EKRecurrenceEnd(end: d)
    } else {
        end = nil
    }

    var dows: [EKRecurrenceDayOfWeek] = []
    if let arr = try optionalIntegerArrayArg(a["days_of_week"], name: "recurrence.days_of_week") {
        for d in arr {
            // Explicit range check: EKWeekday(rawValue:) is non-failable here (see note above).
            guard (1...7).contains(d) else {
                throw MCPErr("recurrence.days_of_week values must be 1-7 (1=Sunday)")
            }
            dows.append(EKRecurrenceDayOfWeek(EKWeekday(rawValue: d)!))
        }
    }

    let dom = try validInts("days_of_month", try optionalIntegerArrayArg(a["days_of_month"], name: "recurrence.days_of_month"), 1...31)
    let moy = try validInts("months_of_year", try optionalIntegerArrayArg(a["months_of_year"], name: "recurrence.months_of_year"), 1...12)
    let woy = try validInts("weeks_of_year", try optionalIntegerArrayArg(a["weeks_of_year"], name: "recurrence.weeks_of_year"), 1...53)
    let doy = try validInts("days_of_year", try optionalIntegerArrayArg(a["days_of_year"], name: "recurrence.days_of_year"), 1...366)
    let sp: [NSNumber]
    if let arr = try optionalIntegerArrayArg(a["set_positions"], name: "recurrence.set_positions") {
        for v in arr where !((-6 ... -1).contains(v) || (1...6).contains(v)) {
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
