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

        // "days" (raw 8) exists in the ObjC enum but EKRecurrenceRule silently
        // corrupts it to raw 0 — must be rejected, not silently built.
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
        XCTAssertThrowsError(try rec(["frequency": "daily", "count": 0]))
    }

    func testAlarmFrom() throws {
        let rel = try alarmFrom(["minutes": 10])
        XCTAssertEqual(rel.relativeOffset, 600)
        let abs = try alarmFrom(["date": "2099-01-01T09:00:00"])
        XCTAssertNotNil(abs.absoluteDate)
        XCTAssertThrowsError(try alarmFrom([:]))
        XCTAssertThrowsError(try alarmFrom(["date": "someday"]))
    }

    // Swift traps on overflow and a trap cannot be caught, so these took the whole server
    // down rather than failing one call: minutes * 60 overflowed, and abs(Int.min) has no
    // representable result.
    func testExtremeIntegersAreRejectedRatherThanTrapping() {
        XCTAssertThrowsError(try alarmFrom(["minutes": Int.max]))
        XCTAssertThrowsError(try alarmFrom(["minutes": Int.min]))
        XCTAssertThrowsError(try recurrenceFrom(["frequency": "weekly", "set_positions": [Int.min]]))
        XCTAssertThrowsError(try recurrenceFrom(["frequency": "weekly", "set_positions": [Int.max]]))
        XCTAssertNoThrow(try alarmFrom(["minutes": -15]))
        XCTAssertNoThrow(try recurrenceFrom(["frequency": "weekly", "set_positions": [-1]]))
    }
}
