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
    let alarmMinutes: [String: Any] = [
        "type": "integer", "minimum": -alarmMinutesLimit, "maximum": alarmMinutesLimit,
        "description": "Minutes relative to the due date; negative = before (-15 = 15 minutes before). Needs a due date.",
    ]
    let alarmItem: [String: Any] = [
        "type": "object",
        "description": alarmShapeHelp,
        "properties": [
            "relative_minutes": alarmMinutes,
            "minutes": ["type": "integer", "minimum": -alarmMinutesLimit, "maximum": alarmMinutesLimit, "description": "Alias of relative_minutes"],
            "date": ["type": "string", "minLength": 1, "description": "Absolute alarm time, ISO-8601"],
            "location": [
                "type": "object",
                "description": "Location alarm: fires on arriving at or leaving this place",
                "properties": [
                    "title": ["type": "string", "minLength": 1, "description": "Place name; reads back as the reminder's location"],
                    "lat": ["type": "number", "minimum": -90, "maximum": 90],
                    "lon": ["type": "number", "minimum": -180, "maximum": 180],
                    "radius_m": ["type": "number", "exclusiveMinimum": 0, "maximum": alarmRadiusLimit, "description": "Geofence radius in metres (default: system default)"],
                ],
                "required": ["title", "lat", "lon"],
                "additionalProperties": false,
            ],
            "proximity": ["type": "string", "enum": ["arrive", "leave"], "description": "Location alarms only (default arrive)"],
        ],
        "oneOf": [
            ["required": ["relative_minutes"]], ["required": ["minutes"]],
            ["required": ["date"]], ["required": ["location"]],
        ],
        "additionalProperties": false,
    ]
    let recurrenceProp: [String: Any] = [
        "type": "object",
        "properties": [
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"], "description": "For workdays use weekly with days_of_week [2,3,4,5,6]"],
            "interval": ["type": "integer", "minimum": 1, "maximum": recurrenceIntegerLimit, "description": "Every N (default 1)"],
            "days_of_week": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 7], "description": "1-7, 1=Sunday"],
            "days_of_month": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 31], "description": "1-31"],
            "months_of_year": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 12], "description": "1-12"],
            "weeks_of_year": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 53], "description": "1-53"],
            "days_of_year": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 366], "description": "1-366"],
            "set_positions": [
                "type": "array",
                "items": [
                    "anyOf": [
                        ["type": "integer", "minimum": -6, "maximum": -1],
                        ["type": "integer", "minimum": 1, "maximum": 6],
                    ],
                ],
                "description": "±1 to ±6 (first/last etc.)",
            ],
            "until": ["type": "string", "minLength": 1, "description": "ISO-8601 end date"],
            "count": ["type": "integer", "minimum": 1, "maximum": recurrenceIntegerLimit, "description": "Occurrence count (alternative to until)"],
        ],
        "required": ["frequency"],
        "additionalProperties": false,
    ]

    // Kept in the schema only so a caller gets the specific rejection (see
    // rejectLocationArg) instead of a generic unknown-field error.
    let locationProp: [String: Any] = [
        "type": "string",
        "description": "Not supported: Apple Reminders does not store a plain location and this is rejected. Use a location alarm in alarms.",
    ]
    let tools: [[String: Any]] = [
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
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 50, max 500"],
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
            "description": "Create a reminder. Due dates are ISO-8601 or YYYY-MM-DD (all-day); time zone left floating. Fractional seconds are accepted. Apple Reminders stores a place only as a location alarm, so set a location with alarms: [{location: {title, lat, lon}, proximity: \"arrive\"}]; a plain location argument is rejected.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "list_name": ["type": "string", "description": "List name or id (default: the default list)"],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "location": locationProp,
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
            "description": "Update a reminder found by identifier or title+list_name. Pass empty string to clear notes/url. A location is set with a location alarm (see create_reminder). remove_due/remove_start/clear_alarm/clear_recurrence clear those fields; move_to_list moves it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identifier": lookupProps["identifier"]!,
                    "title": ["type": "string", "description": "Lookup title, or new title"],
                    "list_name": ["type": "string", "description": "Scope for the title lookup"],
                    "notes": ["type": "string"],
                    "url": ["type": "string"],
                    "location": locationProp,
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
            "description": "Mark a reminder completed (completion date now, or completed_at if given). Returns completed and recurring. For a recurring reminder EventKit saves the completed occurrence as a separate reminder (completed_occurrence) and moves this identifier to the next occurrence (next_due), so is_completed reads false on it.",
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
    return tools.map { tool in
        var closedTool = tool
        if var inputSchema = tool["inputSchema"] as? [String: Any] {
            inputSchema["additionalProperties"] = false
            closedTool["inputSchema"] = inputSchema
        }
        return closedTool
    }
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

func validateToolArguments(_ arguments: [String: Any], for toolName: String) throws {
    guard let tool = toolSchemas().first(where: { $0["name"] as? String == toolName }),
          let schema = tool["inputSchema"] as? [String: Any],
          let properties = schema["properties"] as? [String: Any] else { return }
    try rejectUnknownKeys(arguments, allowed: Set(properties.keys), name: toolName)
}

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
    let hasID = req.keys.contains("id")
    let id = req["id"]
    let isNotification = !hasID

    guard req["jsonrpc"] as? String == "2.0" else {
        return errorResponse(hasID ? id : nil, code: -32600, message: "Invalid request: jsonrpc must be \"2.0\"")
    }
    if let id, !(id is NSNull), !(id is String), !isJSONNumber(id) {
        return errorResponse(nil, code: -32600, message: "Invalid request: id must be a string, number, or null")
    }
    guard let method = req["method"] as? String else {
        return errorResponse(hasID ? id : nil, code: -32600, message: "Invalid request: missing method")
    }
    let params: [String: Any]?
    if let rawParams = req["params"] {
        guard let object = rawParams as? [String: Any] else {
            if isNotification { return nil }
            return errorResponse(id, code: -32602, message: "Invalid params: this server accepts named parameters as an object")
        }
        params = object
    } else {
        params = nil
    }

    var result: Any
    switch method {
    case "initialize":
        result = resultInitialize(params)
    case "ping":
        result = [String: Any]()
    case "tools/list":
        result = ["tools": toolSchemas()]
    case "notifications/initialized":
        if isNotification { return nil }
        result = [String: Any]()
    case "tools/call":
        if isNotification {
            // A tools/call without an id can't get a result back. Executing a
            // mutation we can't report on is worse than refusing it.
            FileHandle.standardError.write("reminders-mcp: ignoring tools/call sent as a notification (no id)\n".data(using: .utf8)!)
            return nil
        }
        if let name = try? requiredStringArg(params?["name"], name: "tools/call.name") {
            if let handler = handlers[name] {
                let args: [String: Any]
                if let rawArguments = params?["arguments"] {
                    guard let object = rawArguments as? [String: Any] else {
                        return errorResponse(id, code: -32602, message: "Invalid params: tools/call.arguments must be an object")
                    }
                    args = object
                } else {
                    args = [:]
                }
                let outcome = Result {
                    try validateToolArguments(args, for: name)
                    return try handler(args)
                }
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
            return errorResponse(id, code: -32602, message: "Invalid params: tools/call.name must be a non-empty string")
        }
    default:
        if isNotification { return nil }
        return errorResponse(id, code: -32601, message: "Method not found: \(method)")
    }

    if isNotification { return nil }
    return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
}
