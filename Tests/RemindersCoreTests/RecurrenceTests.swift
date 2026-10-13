// reminders-mcp — recurrence/alarm construction tests.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import XCTest
import EventKit
import RemindersCore

final class RecurrenceTests: XCTestCase {
    private func rec(_ a: [String: Any]) throws -> EKRecurrenceRule {
        try recurrenceFrom(a)
    }

    func testValidWeekly() throws {
        let r = try rec(["frequency": "weekly", "days_of_week": [1, 5]])
        XCTAssertEqual(r.interval, 1)
        XCTAssertEqual(r.daysOfTheWeek?.count, 2)
    }

    // The name table was off by one: "weekly" stored FREQ=MONTHLY, "yearly" and
    // the extra names stored FREQ=DAILY, and reads mapped them back to the
    // requested name. Check what EventKit actually holds, then the read-back.
    func testFrequencyNamesMatchEventKit() throws {
        let cases: [(String, EKRecurrenceFrequency, String)] = [
            ("daily", .daily, "FREQ=DAILY"), ("weekly", .weekly, "FREQ=WEEKLY"),
            ("monthly", .monthly, "FREQ=MONTHLY"), ("yearly", .yearly, "FREQ=YEARLY"),
        ]
        let store = EKEventStore()
        for (name, freq, rrule) in cases {
            let rule = try rec(["frequency": name])
            XCTAssertEqual(rule.frequency, freq, name)
            XCTAssertTrue(rule.description.contains(rrule), "\(name): \(rule.description)")
            let r = EKReminder(eventStore: store)
            r.recurrenceRules = [rule]
            XCTAssertEqual((reminderJSON(r)["recurrence"] as? [String: Any])?["frequency"] as? String, name)
        }
        for name in ["workdays", "months", "weeks"] {
            XCTAssertThrowsError(try rec(["frequency": name]), "\(name) is not an EventKit frequency")
        }
    }

    func testValidRangesAndEnds() throws {
        let monthly = try rec([
            "frequency": "monthly",
            "days_of_month": [1, 31],
            "months_of_year": [1, 12],
            "set_positions": [-6, 6],
            "count": 3,
        ])
        XCTAssertEqual(monthly.recurrenceEnd?.occurrenceCount, 3)

        let weekly = try rec(["frequency": "weekly", "days_of_week": [2], "until": "2099-01-01"])
        XCTAssertNotNil(weekly.recurrenceEnd?.endDate)

        // "days" exists in the ObjC enum but EKRecurrenceRule silently corrupts
        // it to raw 0. The public contract accepts named, supported values only.
        XCTAssertThrowsError(try rec(["frequency": 8]))
        XCTAssertThrowsError(try rec(["frequency": "days"]))
    }

    // EKWeekday/EKRecurrenceFrequency failable inits are non-failable on this SDK
    // (any raw returns a zeroed case), so these used to reach EKRecurrenceRule's
    // init and raise an uncatchable ObjC exception — a dead server process
    // instead of a tool error. All must be caught by Swift-side validation.
    func testOutOfRangeFieldsAreRejected() {
        XCTAssertThrowsError(try rec(["frequency": "fortnightly"]))
        XCTAssertThrowsError(try rec(["frequency": 9]))
        XCTAssertThrowsError(try rec(["frequency": "weekly", "days_of_week": [8]]))
        XCTAssertThrowsError(try rec(["frequency": "weekly", "days_of_week": [0]]))
        XCTAssertThrowsError(try rec(["frequency": "monthly", "days_of_month": [32]]))
        XCTAssertThrowsError(try rec(["frequency": "monthly", "days_of_month": [0]]))
        XCTAssertThrowsError(try rec(["frequency": "yearly", "months_of_year": [13]]))
        XCTAssertThrowsError(try rec(["frequency": "weekly", "weeks_of_year": [54]]))
        XCTAssertThrowsError(try rec(["frequency": "days", "days_of_year": [367]]))
        XCTAssertThrowsError(try rec(["frequency": "days", "days_of_year": [0]]))
        XCTAssertThrowsError(try rec(["frequency": "monthly", "set_positions": [7]]))
        XCTAssertThrowsError(try rec(["frequency": "monthly", "set_positions": [0]]))
        XCTAssertThrowsError(try rec(["frequency": "monthly", "set_positions": [-7]]))
        XCTAssertThrowsError(try rec(["frequency": "daily", "interval": 0]))
        XCTAssertThrowsError(try rec(["frequency": "daily", "interval": recurrenceIntegerLimit + 1]))
        XCTAssertThrowsError(try rec(["frequency": "daily", "count": 0]))
        XCTAssertThrowsError(try rec(["frequency": "daily", "count": recurrenceIntegerLimit + 1]))
        XCTAssertThrowsError(try rec(["frequency": "daily", "count": 2, "until": "2099-01-01"]))
        XCTAssertThrowsError(try rec(["frequency": "weekly", "days_of_week": "monday"]))
        XCTAssertThrowsError(try rec(["frequency": "weekly", "days_of_week": [true]]))
    }

    func testAlarmFrom() throws {
        let rel = try alarmFrom(["minutes": 10])
        XCTAssertEqual(rel.relativeOffset, 600)
        let abs = try alarmFrom(["date": "2099-01-01T09:00:00"])
        XCTAssertNotNil(abs.absoluteDate)
        XCTAssertThrowsError(try alarmFrom([:]))
        XCTAssertThrowsError(try alarmFrom(["date": "someday"]))
        XCTAssertThrowsError(try alarmFrom(["minutes": true]))
        XCTAssertThrowsError(try alarmFrom(["minutes": 10, "date": "2099-01-01"]))
        XCTAssertThrowsError(try alarmFrom(["minutes": 10, "offset": 10]))
    }

    // Swift traps on overflow and a trap cannot be caught, so these took the whole server
    // down rather than failing one call: minutes * 60 overflowed, and abs(Int.min) has no
    // representable result.
    func testExtremeIntegersAreRejectedRatherThanTrapping() {
        XCTAssertThrowsError(try alarmFrom(["minutes": Int.max]))
        XCTAssertThrowsError(try alarmFrom(["minutes": Int.min]))
        XCTAssertThrowsError(try recurrenceFrom(["frequency": "weekly", "set_positions": [Int.min]]))
        XCTAssertThrowsError(try recurrenceFrom(["frequency": "weekly", "set_positions": [Int.max]]))
        XCTAssertThrowsError(try recurrenceFrom(["frequency": "weekly", "weekday": 2]))
        XCTAssertNoThrow(try alarmFrom(["minutes": -15]))
        XCTAssertNoThrow(try recurrenceFrom(["frequency": "weekly", "set_positions": [-1]]))
    }
}
