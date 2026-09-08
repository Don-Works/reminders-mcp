// reminders-mcp — a standalone MCP server for Apple Reminders.
//
// Swift + EventKit, JSON-RPC 2.0 over stdio (newline-delimited JSON, no
// Content-Length header). See docs/tool-spec.md and docs/eventkit-surface.md.
//
// Copyright (C) 2026 Revitt / Don Works. AGPL-3.0-or-later.

import Foundation
import EventKit
import RemindersCore

// MARK: - Globals

let store = EKEventStore()

let serverName = "reminders-mcp"
let serverVersion = "0.1.0"
// Latest first: an unknown client protocolVersion is answered with the newest
// we support (MCP spec SHOULD), so `first` is the fallback.
let knownProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }
    let response: [String: Any]?
    guard let data = trimmed.data(using: .utf8) else {
        writeJSON(errorResponse(nil, code: -32700, message: "Parse error: input was not UTF-8"))
        continue
    }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        response = errorResponse(nil, code: -32700, message: "Parse error: \(error.localizedDescription)")
        if let response { writeJSON(response) }
        continue
    }
    if let request = object as? [String: Any] {
        response = handle(request)
    } else {
        // Valid JSON with the wrong top-level shape is an invalid request, not
        // a parse error. Batch requests are intentionally unsupported by MCP.
        response = errorResponse(nil, code: -32600, message: "Invalid request: expected a JSON object")
    }
    if let r = response { writeJSON(r) }
}
