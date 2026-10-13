// reminders-mcp — recurrence + alarm construction and serialization.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import Foundation
import EventKit
import CoreLocation

// MARK: - Serialization

func alarmJSON(_ a: EKAlarm) -> [String: Any] {
    var o: [String: Any] = [:]
    if let sl = a.structuredLocation {
        o["type"] = "location"
        var loc: [String: Any] = ["title": sl.title ?? NSNull()]
        if let c = sl.geoLocation?.coordinate {
            loc["lat"] = c.latitude
            loc["lon"] = c.longitude
        }
        if sl.radius > 0 { loc["radius_m"] = sl.radius }
        o["location"] = loc
        o["proximity"] = proximityNames[a.proximity] ?? "none"
    } else if let d = a.absoluteDate {
        o["type"] = "absolute"
        o["date"] = iso8601(d)
    } else if a.relativeOffset == 0, let e = a.emailAddress {
        o["type"] = "email"
        o["email"] = e
    } else if a.relativeOffset == 0, let s = a.soundName {
        o["type"] = "sound"
        o["sound"] = s
    } else {
        // An offset of 0 is a real alarm ("at the due time"), not an unknown one.
        o["type"] = "relative"
        o["offset_seconds"] = a.relativeOffset
        o["relative_minutes"] = Int((a.relativeOffset / 60).rounded())
    }
    return o
}

let proximityNames: [EKAlarmProximity: String] = [.enter: "arrive", .leave: "leave", .none: "none"]

/// Uses the SDK's own cases. The table used to hard-code daily 1, weekly 2,
/// monthly 3, yearly 4, workdays 5, months 6, weeks 7, which is off by one
/// (EventKit: daily 0, weekly 1, monthly 2, yearly 3; anything above 3 stores
/// as DAILY). A "weekly" request was saved as FREQ=MONTHLY and read back as
/// "weekly" through the same table. Probed 2026-10-13.
let frequencyByName: [String: EKRecurrenceFrequency] = [
    "daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly,
]

func recurrenceJSON(_ r: EKRecurrenceRule) -> [String: Any] {
    var o: [String: Any] = [
        "frequency": frequencyByName.first { $0.value == r.frequency }?.key ?? "other",
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

public let alarmFields: Set<String> = ["relative_minutes", "minutes", "date", "location", "proximity"]
public let alarmLocationFields: Set<String> = ["title", "lat", "lon", "radius_m"]
public let alarmRadiusLimit = 100_000.0
public let alarmShapeHelp = "Each alarm must be exactly one of {relative_minutes: N} (minutes from the due date, negative = before; `minutes` is an alias), {date: ISO-8601}, or {location: {title, lat, lon, radius_m?}, proximity: \"arrive\"|\"leave\" (default arrive)}"

public func alarmFrom(_ a: [String: Any]) throws -> EKAlarm {
    try rejectUnknownKeys(a, allowed: alarmFields, name: "alarm")
    let kinds = ["relative_minutes", "minutes", "date", "location"].filter { a.keys.contains($0) }
    guard kinds.count == 1, let kind = kinds.first else { throw MCPErr(alarmShapeHelp) }
    if a.keys.contains("proximity") && kind != "location" {
        throw MCPErr("alarm.proximity applies only to a location alarm. \(alarmShapeHelp)")
    }
    switch kind {
    case "relative_minutes", "minutes":
        guard let m = try optionalIntegerArg(a[kind], name: "alarm.\(kind)") else {
            throw MCPErr("alarm.\(kind) must be an integer")
        }
        guard (-alarmMinutesLimit...alarmMinutesLimit).contains(m) else {
            throw MCPErr("alarm.\(kind) must be within ±\(alarmMinutesLimit) (about a century)")
        }
        return EKAlarm(relativeOffset: TimeInterval(m * 60))
    case "date":
        let d = try requiredStringArg(a["date"], name: "alarm.date")
        guard let dt = parseDue(d)?.date else { throw MCPErr("Bad alarm date \"\(d)\"") }
        return EKAlarm(absoluteDate: dt)
    default:
        return try locationAlarmFrom(a)
    }
}

private func locationAlarmFrom(_ a: [String: Any]) throws -> EKAlarm {
    guard let loc = try optionalObjectArg(a["location"], name: "alarm.location") else {
        throw MCPErr("alarm.location must be an object")
    }
    try rejectUnknownKeys(loc, allowed: alarmLocationFields, name: "alarm.location")
    let title = try requiredStringArg(loc["title"], name: "alarm.location.title")
    let lat = try coordinate(loc["lat"], name: "alarm.location.lat", limit: 90)
    let lon = try coordinate(loc["lon"], name: "alarm.location.lon", limit: 180)
    let proximity: EKAlarmProximity
    switch try optionalStringArg(a["proximity"], name: "alarm.proximity")?.lowercased() {
    case nil, "arrive": proximity = .enter
    case "leave": proximity = .leave
    case let other?: throw MCPErr("alarm.proximity must be \"arrive\" or \"leave\", not \"\(other)\"")
    }
    let sl = EKStructuredLocation(title: title)
    sl.geoLocation = CLLocation(latitude: lat, longitude: lon)
    if loc["radius_m"] != nil {
        guard isJSONNumber(loc["radius_m"]), let r = (loc["radius_m"] as? NSNumber)?.doubleValue,
              r.isFinite, r > 0, r <= alarmRadiusLimit else {
            throw MCPErr("alarm.location.radius_m must be a number above 0 and at most \(Int(alarmRadiusLimit))")
        }
        sl.radius = r
    }
    let alarm = EKAlarm()
    alarm.structuredLocation = sl
    alarm.proximity = proximity
    return alarm
}

private func coordinate(_ value: Any?, name: String, limit: Double) throws -> Double {
    guard isJSONNumber(value), let d = (value as? NSNumber)?.doubleValue, d.isFinite, abs(d) <= limit else {
        throw MCPErr("\(name) must be a number between -\(Int(limit)) and \(Int(limit))")
    }
    return d
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
    guard let freq = frequencyByName[frequencyName] else {
        throw MCPErr("recurrence.frequency must be daily/weekly/monthly/yearly (for workdays use weekly with days_of_week [2,3,4,5,6])")
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
