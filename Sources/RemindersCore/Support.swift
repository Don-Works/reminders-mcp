// reminders-mcp — shared error + argument helpers.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import Foundation
import CoreFoundation

/// User-facing tool error; `localizedDescription` becomes the MCP `isError` text.
public struct MCPErr: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// JSON-encode a result value for the MCP text envelope.
public func jsonString(_ object: Any) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: []),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return String(describing: object)
}

/// Extract a non-empty trimmed string from an argument value.
public func argString(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

public func argBool(_ value: Any?, default def: Bool) -> Bool {
    (value as? Bool) ?? def
}

/// JSONSerialization bridges booleans and numbers through NSNumber, and Swift's
/// ordinary casts are surprisingly permissive (`true as? Int == 1`, while
/// `1 as? Bool == true`). These helpers enforce the types advertised by the MCP
/// schemas before values reach EventKit.
public func jsonBoolean(_ value: Any?) -> Bool? {
    guard let value,
          CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
          let number = value as? NSNumber else { return nil }
    return number.boolValue
}

public func jsonInteger(_ value: Any?) -> Int? {
    guard let value,
          CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
    return value as? Int
}

public func isJSONNumber(_ value: Any?) -> Bool {
    guard let value,
          CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return false }
    return value is NSNumber
}

public func rejectUnknownKeys(_ object: [String: Any], allowed: Set<String>, name: String) throws {
    let unknown = object.keys.filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
        throw MCPErr("\(name) contains unknown field(s): \(unknown.joined(separator: ", ")). Accepted fields: \(allowed.sorted().joined(separator: ", "))")
    }
}

/// Return nil only when the field is absent. A present null/wrong type is an
/// error; callers must never mistake malformed input for "leave unchanged".
public func optionalStringArg(
    _ value: Any?,
    name: String,
    allowEmpty: Bool = false
) throws -> String? {
    guard let value else { return nil }
    guard let string = value as? String else { throw MCPErr("\(name) must be a string") }
    if allowEmpty { return string }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw MCPErr("\(name) must be a non-empty string") }
    return trimmed
}

public func requiredStringArg(_ value: Any?, name: String) throws -> String {
    guard let string = try optionalStringArg(value, name: name) else {
        throw MCPErr("\(name) is required")
    }
    return string
}

public func boolArg(_ value: Any?, name: String, default defaultValue: Bool) throws -> Bool {
    guard value != nil else { return defaultValue }
    guard let boolean = jsonBoolean(value) else { throw MCPErr("\(name) must be a boolean") }
    return boolean
}

public func optionalIntegerArg(_ value: Any?, name: String) throws -> Int? {
    guard value != nil else { return nil }
    guard let integer = jsonInteger(value) else { throw MCPErr("\(name) must be an integer") }
    return integer
}

public func optionalObjectArg(_ value: Any?, name: String) throws -> [String: Any]? {
    guard let value else { return nil }
    guard let object = value as? [String: Any] else { throw MCPErr("\(name) must be an object") }
    return object
}

public func optionalObjectArrayArg(_ value: Any?, name: String) throws -> [[String: Any]]? {
    guard let value else { return nil }
    guard let items = value as? [Any] else { throw MCPErr("\(name) must be an array") }
    return try items.enumerated().map { index, item in
        guard let object = item as? [String: Any] else {
            throw MCPErr("\(name)[\(index)] must be an object")
        }
        return object
    }
}

public func optionalIntegerArrayArg(_ value: Any?, name: String) throws -> [Int]? {
    guard let value else { return nil }
    guard let items = value as? [Any] else { throw MCPErr("\(name) must be an array") }
    return try items.enumerated().map { index, item in
        guard let integer = jsonInteger(item) else {
            throw MCPErr("\(name)[\(index)] must be an integer")
        }
        return integer
    }
}

/// Case- and diacritic-insensitive equality.
public func cdEqual(_ a: String?, _ b: String) -> Bool {
    guard let a else { return false }
    return fold(a) == fold(b)
}

public func cdContains(_ a: String?, _ needle: String) -> Bool {
    guard let a, !needle.isEmpty else { return false }
    return fold(a).range(of: fold(needle)) != nil
}

private func fold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
}
