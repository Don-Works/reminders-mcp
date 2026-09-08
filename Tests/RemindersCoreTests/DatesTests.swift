// reminders-mcp — date parsing/serialization tests.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import XCTest
import Foundation
import RemindersCore

final class DatesTests: XCTestCase {
    // MARK: serialization (the A1 regression: all-day dates reading back as the previous day)

    func testAllDaySerializesToTheBareDate() {
        var july = DateComponents()
        july.year = 2099; july.month = 7; july.day = 1
        XCTAssertEqual(isoFromComponents(july), "2099-07-01")

        var jan = DateComponents()
        jan.year = 2026; jan.month = 1; jan.day = 5
        XCTAssertEqual(isoFromComponents(jan), "2026-01-05")
    }

    func testTimedFloatingComponentsKeepTheirWallClock() {
        var c = DateComponents()
        c.year = 2099; c.month = 7; c.day = 1; c.hour = 14; c.minute = 0; c.second = 0
        let s = isoFromComponents(c)
        XCTAssertTrue(s?.hasPrefix("2099-07-01T14:00:00") ?? false, "got \(s ?? "nil")")
    }

    func testIsAllDay() {
        var allDay = DateComponents()
        allDay.year = 2099; allDay.month = 6; allDay.day = 15
        XCTAssertTrue(isAllDay(allDay))

        var timed = allDay
        timed.hour = 9
        XCTAssertFalse(isAllDay(timed))
        XCTAssertFalse(isAllDay(nil))
    }

    // MARK: dueComponents

    func testDateOnlyIsExactWallClock() {
        let c = try! dueComponents("2099-06-15")
        XCTAssertEqual(c.year, 2099)
        XCTAssertEqual(c.month, 6)
        XCTAssertEqual(c.day, 15)
        XCTAssertNil(c.hour)
        XCTAssertNil(c.timeZone)
    }

    func testDateOnlyRejectsImpossibleDates() {
        XCTAssertThrowsError(try dueComponents("2099-02-30"))
        XCTAssertThrowsError(try dueComponents("2099-13-01"))
        XCTAssertThrowsError(try dueComponents("2099-00-10"))
    }

    func testNaiveLocalKeepsWallClock() {
        let c = try! dueComponents("2024-06-01T09:30:15")
        XCTAssertEqual(c.hour, 9)
        XCTAssertEqual(c.minute, 30)
        XCTAssertEqual(c.second, 15)
        XCTAssertNil(c.timeZone)
    }

    func testZSuffixedParsesToTheSameInstant() {
        let reference = ISO8601DateFormatter().date(from: "2024-06-01T09:00:00Z")!
        let p = parseDue("2024-06-01T09:00:00Z")!
        XCTAssertEqual(p.date.timeIntervalSince(reference), 0, accuracy: 0.001)
        // and the stored components are that instant in local wall-clock
        let c = try! dueComponents("2024-06-01T09:00:00Z")
        let comps = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.date)
        XCTAssertEqual(c.hour, comps.hour)
        XCTAssertEqual(c.minute, comps.minute)
    }

    func testFractionalSecondsParse() {
        XCTAssertNotNil(parseDue("2024-06-01T09:00:00.5Z"))
        XCTAssertNotNil(parseDue("2024-06-01T09:00:00.5"))
        XCTAssertNotNil(parseDue("2024-06-01 09:00:00.250"))
        let c = try! dueComponents("2099-07-02T09:30:00.5")
        XCTAssertEqual(c.hour, 9)
        XCTAssertEqual(c.minute, 30)
    }

    func testGarbageDoesNotParse() {
        XCTAssertNil(parseDue("tomorrow"))
        XCTAssertNil(parseDue("2024-06-01T25:00:00"))
        XCTAssertNil(parseDue(""))
        XCTAssertNil(parseDue("2024-6-1"))
    }

    // MARK: query boundaries

    func testBoundaryDateOnlyIsLocalMidnight() throws {
        let d = try parseBoundary("2099-12-31", upperBoundDateOnlySpansDay: false)
        let c = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        XCTAssertEqual(c.year, 2099)
        XCTAssertEqual(c.month, 12)
        XCTAssertEqual(c.day, 31)
        XCTAssertEqual(c.hour, 0)
        XCTAssertEqual(c.minute, 0)
        XCTAssertEqual(c.second, 0)
    }

    func testBoundaryUpperDateOnlySpansTheWholeDay() throws {
        let d = try parseBoundary("2099-12-31", upperBoundDateOnlySpansDay: true)
        let c = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
        XCTAssertEqual(c.year, 2099)
        XCTAssertEqual(c.month, 12)
        XCTAssertEqual(c.day, 31)
        XCTAssertEqual(c.hour, 23)
        XCTAssertEqual(c.minute, 59)
        XCTAssertEqual(c.second, 59)
        // Date is a Double with ~119 ns resolution at the magnitude of year 2099,
        // so the 999 ms we ask for cannot round-trip exactly — tolerate the drift.
        XCTAssertGreaterThanOrEqual(c.nanosecond ?? 0, 998_000_000)
        XCTAssertLessThan(c.nanosecond ?? 0, 1_000_000_000)
    }

    func testBoundaryKeepsTimedValuesUntouched() throws {
        let d = try parseBoundary("2099-12-31T10:00:00", upperBoundDateOnlySpansDay: true)
        let c = gregorian.dateComponents([.hour, .minute], from: d)
        XCTAssertEqual(c.hour, 10)
        XCTAssertEqual(c.minute, 0)
    }

    func testUnparseableBoundaryThrows() {
        XCTAssertThrowsError(try parseBoundary("next week", upperBoundDateOnlySpansDay: false))
        XCTAssertThrowsError(try parseBoundary("2024/06/01", upperBoundDateOnlySpansDay: true))
    }
}
