// reminders-mcp — MCP protocol: tool schemas, dispatch, JSON-RPC handling.
//
// Copyright (C) 2026 Revitt / Don Works. AGPL-3.0-or-later.

import Foundation
import RemindersCore

// MARK: - Tool schemas

func toolSchemas() -> [[String: Any]] {
    let lookupProps: [String: Any] = [
        "identifier": ["type": "string", "description": "Reminder calendarItemIdentifier (unambiguous)"],
        "title": ["type": "string", "description": "Exact title; use list_name to narrow"],
        "list_name": ["type": "string", "description": "List name or id to scope the title lookup"],
    ]
    let dueProp: [String: Any] = ["type": "string", "description": "ISO-8601, or YYYY-MM-DD for all-day"]
    let alarmItem: [String: Any] = [
        "type": "object",
        "description": "{minutes: N} for a relative alarm, or {date: ISO-8601} for absolute",
        "properties": [
            "minutes": ["type": "integer"],
            "date": ["type": "string"],
        ],
    ]
    let recurrenceProp: [String: Any] = [
        "type": "object",
        "properties": [
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly", "workdays", "months", "weeks", "days"]],
            "interval": ["type": "integer", "description": "Every N (default 1, must be >= 1)"],
            "days_of_week": ["type": "array", "items": ["type": "integer"], "description": "1-7, 1=Sunday"],
            "days_of_month": ["type": "array", "items": ["type": "integer"], "description": "1-31"],
            "months_of_year": ["type": "array", "items": ["type": "integer"], "description": "1-12"],
            "weeks_of_year": ["type": "array", "items": ["type": "integer"], "description": "1-53"],
            "days_of_year": ["type": "array", "items": ["type": "integer"], "description": "1-366"],
            "set_positions": ["type": "array", "items": ["type": "integer"], "description": "±1 to ±6 (first/last etc.)"],
            "until": ["type": "string", "description": "ISO-8601 end date"],
            "count": ["type": "integer", "description": "Occurrence count, >= 1 (alternative to until)"],
        ],
        "required": ["frequency"],
    ]

    return [
        [
            "name": "list_lists",
            "description": "List all reminder lists with id, name, color, flags, source, and open/completed counts.",
            "inputSchema": [
                "type": "object",
                "properties": ["include_empty": ["type": "boolean", "description": "Include lists with no reminders (default true)"]],
            ],
        ],
        [
            "name": "create_list",
            "description": "Create a new list via Reminders.app (AppleScript — this SDK has no EventKit calendar-creation API). May trigger a macOS automation permission prompt. Optional color applied via EventKit afterwards.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "color": ["type": "string", "description": "#RRGGBB"],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "rename_list",
            "description": "Rename a list by id or name.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "List name or id"],
                    "new_name": ["type": "string"],
                ],
                "required": ["list", "new_name"],
            ],
        ],
        [
            "name": "set_list_color",
            "description": "Set a list's color.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "List name or id"],
                    "color": ["type": "string", "description": "#RRGGBB"],
                ],
                "required": ["list", "color"],
            ],
        ],
        [
            "name": "delete_list",
            "description": "Delete a list. Optionally move its reminders to another list first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "List name or id"],
                    "move_to": ["type": "string", "description": "List name or id to re-home the reminders into"],
                ],
                "required": ["list"],
            ],
        ],
        [
            "name": "list_reminders",
            "description": "Query reminders with filters. Sorted by due date (none last), then title. Default: open reminders only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "Restrict to one list (name or id)"],
                    "include_completed": ["type": "boolean", "description": "Include completed (default false)"],
                    "completed_only": ["type": "boolean", "description": "Only completed; due_from/due_until then bound the completion date"],
                    "due_from": ["type": "string", "description": "Due on/after (inclusive). ISO-8601 or YYYY-MM-DD. Naive values and bare dates are local wall-clock; Z/offset values are absolute instants. Must be parseable — unparseable values are an error."],
                    "due_until": ["type": "string", "description": "Due on/before (inclusive). A bare YYYY-MM-DD spans the whole day (through 23:59:59). Same local-vs-absolute rule as due_from."],
                    "query": ["type": "string", "description": "Title contains (case/diacritic-insensitive)"],
                    "notes_query": ["type": "string", "description": "Notes contain"],
                    "location_like": ["type": "string", "description": "Location contains"],
                    "has_due_date": ["type": "boolean", "description": "Only reminders with a due date"],
                    "limit": ["type": "integer", "description": "Default 50, max 500"],
                ],
            ],
        ],
        [
            "name": "get_reminder",
            "description": "Fetch one reminder by identifier, or by exact title (optionally scoped to a list). Ambiguous titles return up to 10 candidates.",
            "inputSchema": [
                "type": "object",
                "properties": lookupProps,
            ],
        ],
        [
            "name": "create_reminder",
            "description": "Create a reminder. Due dates are ISO-8601 or YYYY-MM-DD (all-day); time zone left floating. Fractional seconds are accepted.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "list_name": ["type": "string", "description": "List name or id (default: the default list)"],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "location": ["type": "string"],
                    "priority": ["type": ["string", "integer"], "description": "none/high/medium/low or 0/1/5/9"],
                    "due": dueProp,
                    "start": ["type": "string", "description": "ISO-8601 or YYYY-MM-DD start of a period"],
                    "alarms": ["type": "array", "items": alarmItem],
                    "recurrence": recurrenceProp,
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "update_reminder",
            "description": "Update a reminder found by identifier or title+list_name. Pass empty string to clear notes/url/location. remove_due/remove_start/clear_alarm/clear_recurrence clear those fields; move_to_list moves it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": ["type": "string", "description": "Lookup title, or new title"],
                    "list_name": ["type": "string", "description": "Scope for the title lookup"],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "location": ["type": "string"],
                    "priority": ["type": ["string", "integer"], "description": "none/high/medium/low or 0/1/5/9"],
                    "due": dueProp,
                    "start": ["type": "string"],
                    "alarms": ["type": "array", "items": alarmItem, "description": "Replaces the alarm set"],
                    "recurrence": recurrenceProp,
                    "remove_due": ["type": "boolean"],
                    "remove_start": ["type": "boolean"],
                    "clear_alarm": ["type": "boolean"],
                    "clear_recurrence": ["type": "boolean"],
                    "move_to_list": ["type": "string", "description": "List name or id"],
                ],
            ],
        ],
        [
            "name": "complete_reminder",
            "description": "Mark a reminder completed (completion date now, or completed_at if given).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": lookupProps["title"]!,
                    "list_name": lookupProps["list_name"]!,
                    "completed_at": ["type": "string", "description": "ISO-8601 or YYYY-MM-DD"],
                ],
            ],
        ],
        [
            "name": "uncomplete_reminder",
            "description": "Mark a reminder incomplete again.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": lookupProps["title"]!,
                    "list_name": lookupProps["list_name"]!,
                ],
            ],
        ],
        [
            "name": "delete_reminder",
            "description": "Delete a reminder.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": lookupProps["title"]!,
                    "list_name": lookupProps["list_name"]!,
                ],
            ],
        ],
    ]
}

typealias ToolHandler = ([String: Any]) throws -> [String: Any]

let handlers: [String: ToolHandler] = [
    "list_lists": toolListLists,
    "create_list": toolCreateList,
    "rename_list": toolRenameList,
    "set_list_color": toolSetListColor,
    "delete_list": toolDeleteList,
    "list_reminders": toolListReminders,
    "get_reminder": toolGetReminder,
    "create_reminder": toolCreateReminder,
    "update_reminder": toolUpdateReminder,
    "complete_reminder": toolCompleteReminder,
    "uncomplete_reminder": toolUncompleteReminder,
    "delete_reminder": toolDeleteReminder,
]

// MARK: - JSON-RPC dispatch

func errorResponse(_ id: Any?, code: Int, message: String) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "error": ["code": code, "message": message],
    ]
}

func toolError(_ message: String) -> [String: Any] {
    [
        "content": [["type": "text", "text": message]],
        "isError": true,
    ]
}

func writeJSON(_ object: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)   // newline-delimited framing
        FileHandle.standardOutput.write(data)
    } catch {
        FileHandle.standardError.write("reminders-mcp: failed to serialize response: \(error)\n".data(using: .utf8)!)
    }
}

func resultInitialize(_ params: [String: Any]?) -> [String: Any] {
    // Echo a version we know; otherwise answer with the latest we support
    // (knownProtocolVersions is sorted latest-first, per the MCP spec SHOULD).
    let pv = (params?["protocolVersion"] as? String).flatMap { knownProtocolVersions.contains($0) ? $0 : nil } ?? knownProtocolVersions[0]
    return [
        "protocolVersion": pv,
        "capabilities": ["tools": ["listChanged": false]],
        "serverInfo": ["name": serverName, "version": serverVersion],
        "instructions": "Manage Apple Reminders on this Mac: lists and reminders with due dates, alarms, recurrences, priorities, notes, URLs, locations. Dates are ISO-8601; YYYY-MM-DD means all-day. New lists are created through Reminders.app (AppleScript).",
    ]
}

func handle(_ req: [String: Any]) -> [String: Any]? {
    guard let method = req["method"] as? String else {
        return errorResponse(req["id"], code: -32600, message: "Invalid request: missing method")
    }
    let id = req["id"]          // nil for notifications
    let isNotification = (id == nil) || (id is NSNull)
    let params = req["params"] as? [String: Any]

    var result: Any
    switch method {
    case "initialize":
        result = resultInitialize(params)
    case "ping":
        result = [String: Any]()
    case "tools/list":
        result = ["tools": toolSchemas()]
    case "notifications/initialized":
        return nil   // notification, never responds
    case "tools/call":
        if isNotification {
            // A tools/call without an id can't get a result back. Executing a
            // mutation we can't report on is worse than refusing it.
            FileHandle.standardError.write("reminders-mcp: ignoring tools/call sent as a notification (no id)\n".data(using: .utf8)!)
            return nil
        }
        if let name = params?["name"] as? String {
            if let handler = handlers[name] {
                let args: [String: Any] = params?["arguments"] as? [String: Any] ?? [:]
                let outcome = Result { try handler(args) }
                switch outcome {
                case let .success(out):
                    result = ["content": [["type": "text", "text": jsonString(out)]], "isError": false]
                case let .failure(err):
                    result = toolError(err.localizedDescription)
                }
            } else {
                result = toolError("Unknown tool: \(name)")
            }
        } else {
            result = toolError("tools/call requires a name")
        }
    default:
        if isNotification { return nil }
        return errorResponse(id, code: -32601, message: "Method not found: \(method)")
    }

    if isNotification { return nil }
    return ["jsonrpc": "2.0", "id": id!, "result": result]
}
