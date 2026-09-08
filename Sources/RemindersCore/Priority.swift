// reminders-mcp — priority mapping.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

/// EventKit on this SDK only accepts 0, 1, 5, 9 — other values fail the save.
public func parsePriority(_ v: Any?) throws -> Int {
    if let i = v as? Int {
        guard [0, 1, 5, 9].contains(i) else { throw MCPErr("priority must be 0, 1, 5 or 9") }
        return i
    }
    switch (v as? String)?.lowercased() {
    case "none", "0": return 0
    case "high", "1": return 1
    case "medium", "5": return 5
    case "low", "9": return 9
    default: throw MCPErr("priority must be none/high/medium/low or one of 0, 1, 5, 9")
    }
}

public func priorityName(_ p: Int) -> String {
    switch p {
    case 1: return "high"
    case 5: return "medium"
    case 9: return "low"
    default: return "none"
    }
}
