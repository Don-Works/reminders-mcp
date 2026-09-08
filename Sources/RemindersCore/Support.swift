// reminders-mcp — shared error + argument helpers.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import Foundation

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
