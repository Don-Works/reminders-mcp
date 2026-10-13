// reminders-mcp — alarm construction and serialization tests.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import XCTest
import EventKit
import RemindersCore

final class AlarmTests: XCTestCase {
    private func message(_ body: () throws -> Void) -> String {
        do { try body() } catch { return error.localizedDescription }
        XCTFail("expected an error")
        return ""
    }

    func testRelativeMinutesAndAlias() throws {
        XCTAssertEqual(try alarmFrom(["relative_minutes": -15]).relativeOffset, -900)
        XCTAssertEqual(try alarmFrom(["minutes": 10]).relativeOffset, 600)
        XCTAssertThrowsError(try alarmFrom(["relative_minutes": -15, "minutes": -15]))
        XCTAssertThrowsError(try alarmFrom(["relative_minutes": "soon"]))
        XCTAssertThrowsError(try alarmFrom(["relative_minutes": alarmMinutesLimit + 1]))
    }

    func testLocationAlarm() throws {
        let a = try alarmFrom([
            "location": ["title": "Office", "lat": 51.5, "lon": -0.12, "radius_m": 150],
            "proximity": "leave",
        ])
        XCTAssertEqual(a.structuredLocation?.title, "Office")
        XCTAssertEqual(a.structuredLocation?.geoLocation?.coordinate.latitude ?? 0, 51.5, accuracy: 1e-9)
        XCTAssertEqual(a.structuredLocation?.geoLocation?.coordinate.longitude ?? 0, -0.12, accuracy: 1e-9)
        XCTAssertEqual(a.structuredLocation?.radius, 150)
        XCTAssertEqual(a.proximity, .leave)

        let arrive = try alarmFrom(["location": ["title": "Home", "lat": 0, "lon": 0]])
        XCTAssertEqual(arrive.proximity, .enter, "proximity defaults to arrive")
    }

    func testLocationAlarmValidation() {
        XCTAssertThrowsError(try alarmFrom(["location": ["title": "X", "lat": 91, "lon": 0]]))
        XCTAssertThrowsError(try alarmFrom(["location": ["title": "X", "lat": 0, "lon": 181]]))
        XCTAssertThrowsError(try alarmFrom(["location": ["title": "X", "lat": true, "lon": 0]]))
        XCTAssertThrowsError(try alarmFrom(["location": ["title": "X", "lat": "51", "lon": 0]]))
        XCTAssertThrowsError(try alarmFrom(["location": ["lat": 0, "lon": 0]]))
        XCTAssertThrowsError(try alarmFrom(["location": ["title": "X", "lat": 0, "lon": 0, "radius_m": 0]]))
        XCTAssertThrowsError(try alarmFrom(["location": ["title": "X", "lat": 0, "lon": 0], "proximity": "near"]))
        XCTAssertThrowsError(try alarmFrom(["location": "Office"]))
        XCTAssertThrowsError(try alarmFrom(["date": "2099-01-01T09:00", "proximity": "arrive"]),
                             "proximity without a location is rejected")
        let unknown = message { _ = try alarmFrom(["location": ["title": "X", "lat": 0, "lon": 0, "latitude": 1]]) }
        XCTAssertTrue(unknown.contains("Accepted fields: lat, lon, radius_m, title"), unknown)
    }

    func testUnknownAlarmFieldListsAcceptedFields() {
        let text = message { _ = try alarmFrom(["offset": -15]) }
        XCTAssertTrue(text.contains("unknown field(s): offset"), text)
        XCTAssertTrue(text.contains("Accepted fields: date, location, minutes, proximity, relative_minutes"), text)
        let empty = message { _ = try alarmFrom([:]) }
        XCTAssertTrue(empty.contains("relative_minutes") && empty.contains("location"), empty)
    }

    func testAlarmJSON() throws {
        let store = EKEventStore()
        let r = EKReminder(eventStore: store)
        r.alarms = [
            try alarmFrom(["relative_minutes": -15]),
            try alarmFrom(["relative_minutes": 0]),
            try alarmFrom(["location": ["title": "Office", "lat": 51.5, "lon": -0.12, "radius_m": 150], "proximity": "arrive"]),
        ]
        let json = reminderJSON(r)
        // EKReminder does not keep alarm order, so look each one up.
        let alarms = try XCTUnwrap(json["alarms"] as? [[String: Any]])
        XCTAssertEqual(alarms.count, 3)
        let relative = alarms.filter { $0["type"] as? String == "relative" }
        XCTAssertEqual(Set(relative.compactMap { $0["relative_minutes"] as? Int }), [-15, 0],
                       "an at-due-time alarm is relative 0, not 'unknown'")
        let location = try XCTUnwrap(alarms.first { $0["type"] as? String == "location" })
        XCTAssertEqual(location["proximity"] as? String, "arrive")
        let loc = try XCTUnwrap(location["location"] as? [String: Any])
        XCTAssertEqual(loc["title"] as? String, "Office")
        XCTAssertEqual(loc["radius_m"] as? Double, 150)
        XCTAssertEqual(json["location"] as? String, "Office", "location reads back from the location alarm")
        XCTAssertTrue(hasRelativeAlarm(r.alarms ?? []))
        XCTAssertFalse(hasRelativeAlarm([try alarmFrom(["date": "2099-01-01T09:00"])]))
    }
}
