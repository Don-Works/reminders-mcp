// reminders-mcp — list colour helpers.
//
// Copyright (C) 2026 Revitt / Don Works. Licensed under AGPL-3.0-or-later.

import AppKit

public func hexFromNSColor(_ c: NSColor) -> String {
    guard let rgb = c.usingColorSpace(.sRGB) else { return "#000000" }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", min(r, 255), min(g, 255), min(b, 255))
}

public func nsColorFromHex(_ hex: String) throws -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else {
        throw MCPErr("color must be #RRGGBB")
    }
    return NSColor(
        red: CGFloat((v >> 16) & 0xFF) / 255.0,
        green: CGFloat((v >> 8) & 0xFF) / 255.0,
        blue: CGFloat(v & 0xFF) / 255.0,
        alpha: 1.0
    )
}
