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

    func testStrictJSONArgumentTypes() throws {
        XCTAssertEqual(jsonBoolean(true), true)
        XCTAssertNil(jsonBoolean(1), "a JSON integer must not bridge to Bool")
        XCTAssertEqual(jsonInteger(1), 1)
        XCTAssertNil(jsonInteger(true), "a JSON boolean must not bridge to Int")
        XCTAssertTrue(isJSONNumber(1.5))
        XCTAssertFalse(isJSONNumber(true))

        XCTAssertEqual(try optionalStringArg("  value  ", name: "field"), "value")
        XCTAssertEqual(try optionalStringArg("", name: "notes", allowEmpty: true), "")
        XCTAssertNil(try optionalStringArg(nil, name: "field"))
        XCTAssertThrowsError(try optionalStringArg(NSNull(), name: "field"))
        XCTAssertThrowsError(try optionalStringArg(42, name: "field"))
        XCTAssertThrowsError(try boolArg(1, name: "flag", default: false))
        XCTAssertThrowsError(try optionalIntegerArg(true, name: "count"))
        XCTAssertEqual(try optionalIntegerArrayArg([1, 2, 3], name: "values"), [1, 2, 3])
        XCTAssertThrowsError(try optionalIntegerArrayArg([1, true], name: "values"))
        XCTAssertThrowsError(try optionalObjectArrayArg([["ok": true], 2], name: "objects"))
        XCTAssertNoThrow(try rejectUnknownKeys(["known": 1], allowed: ["known"], name: "object"))
        XCTAssertThrowsError(try rejectUnknownKeys(["typo": 1], allowed: ["known"], name: "object"))
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
        XCTAssertThrowsError(try parsePriority(true))
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
