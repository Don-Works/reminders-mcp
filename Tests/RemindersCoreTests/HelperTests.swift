// reminders-mcp — argument/text/priority/color helper tests.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import XCTest
import AppKit
import RemindersCore

final class HelperTests: XCTestCase {
    func testArgStringTrimsAndRejectsEmpty() {
        XCTAssertEqual(argString("  x  "), "x")
        XCTAssertNil(argString("   "))
        XCTAssertNil(argString(42))
        XCTAssertNil(argString(nil))
        XCTAssertNil(argString(["a"]))
    }

    func testArgBool() {
        XCTAssertTrue(argBool(true, default: false))
        XCTAssertFalse(argBool("yes", default: false))
        XCTAssertTrue(argBool(nil, default: true))
        XCTAssertFalse(argBool(nil, default: false))
    }

    func testCaseDiacriticInsensitive() {
        XCTAssertTrue(cdEqual("Café", "cafe"))
        XCTAssertTrue(cdEqual("CAFÉ", "café"))
        XCTAssertFalse(cdEqual("cafe", "cafea"))
        XCTAssertFalse(cdEqual(nil, "cafe"))
        XCTAssertTrue(cdContains("Meeting at the Café", "meeting"))
        XCTAssertTrue(cdContains("café", "CAFE"))
        XCTAssertFalse(cdContains(nil, "x"))
        XCTAssertFalse(cdContains("abc", ""))
    }

    func testPriorityParsing() throws {
        XCTAssertEqual(try parsePriority("high"), 1)
        XCTAssertEqual(try parsePriority("HIGH"), 1)
        XCTAssertEqual(try parsePriority("medium"), 5)
        XCTAssertEqual(try parsePriority("low"), 9)
        XCTAssertEqual(try parsePriority("none"), 0)
        XCTAssertEqual(try parsePriority(1), 1)
        XCTAssertEqual(try parsePriority("5"), 5)
        XCTAssertThrowsError(try parsePriority(7))
        XCTAssertThrowsError(try parsePriority("urgent"))
        XCTAssertThrowsError(try parsePriority(nil))
    }

    func testPriorityNames() {
        XCTAssertEqual(priorityName(1), "high")
        XCTAssertEqual(priorityName(5), "medium")
        XCTAssertEqual(priorityName(9), "low")
        XCTAssertEqual(priorityName(0), "none")
    }

    func testHexRoundTrip() throws {
        let c = try nsColorFromHex("#ff8800")
        let hex = hexFromNSColor(c)
        XCTAssertEqual(hex.uppercased(), "#FF8800")
        let withPrefix = try nsColorFromHex("00AAFF")
        XCTAssertEqual(hexFromNSColor(withPrefix).uppercased(), "#00AAFF")
    }

    func testHexRejectsGarbage() {
        XCTAssertThrowsError(try nsColorFromHex("nope"))
        XCTAssertThrowsError(try nsColorFromHex("#GGGGGG"))
        XCTAssertThrowsError(try nsColorFromHex("#FFF"))
        XCTAssertThrowsError(try nsColorFromHex(""))
    }

    func testJsonStringRoundTrip() {
        let obj: [String: Any] = ["a": 1, "b": ["x"], "c": "t", "d": true]
        let s = jsonString(obj)
        let data = s.data(using: .utf8)!
        let back = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(back["a"] as? Int, 1)
        XCTAssertEqual(back["d"] as? Bool, true)
    }
}
