import AppKit
import Carbon.HIToolbox

/// Mac keys → X11 keysyms for RFB, layout-aware: characters come from the event (so a Norwegian layout sends the
/// keysym of the glyph the key means there), special keys from the key code.
enum KeyMap {
    static let special: [UInt16: UInt32] = [
        36: 0xff0d, 76: 0xff8d, 51: 0xff08, 48: 0xff09, 53: 0xff1b, 117: 0xffff,
        123: 0xff51, 126: 0xff52, 124: 0xff53, 125: 0xff54, 115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56,
        122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1, 96: 0xffc2, 97: 0xffc3, 98: 0xffc4, 100: 0xffc5, 101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9,
        105: 0xffca, 107: 0xffcb, 113: 0xffcc,                       // F13-F15
        56: 0xffe1, 60: 0xffe2, 59: 0xffe3, 62: 0xffe4, 58: 0xffe9, 61: 0xffea, 55: 0xffeb, 54: 0xffec, 57: 0xffe5,
        71: 0xff7f, 82: 0xffb0, 83: 0xffb1, 84: 0xffb2, 85: 0xffb3, 86: 0xffb4, 87: 0xffb5, 88: 0xffb6, 89: 0xffb7, 91: 0xffb8, 92: 0xffb9,
        65: 0xffae, 67: 0xffaa, 69: 0xffab, 75: 0xffaf, 78: 0xffad, 81: 0xffbd,
    ]
    static let modifierKeysyms: [(NSEvent.ModifierFlags, UInt32)] = [(.shift, 0xffe1), (.control, 0xffe3), (.option, 0xffe9), (.command, 0xffeb)]
    static let superL: UInt32 = 0xffeb, altL: UInt32 = 0xffe9

    /// keysym for a key event; nil for keys the remote cannot use
    static func keysym(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?, shift: Bool) -> UInt32? {
        if let k = special[keyCode] { return k }
        // the shifted glyph when Shift is down (the remote applies no Shift of its own to a keysym), the plain one
        // otherwise (Ctrl+c must arrive as "c", not the control character macOS puts in `characters`)
        let source = shift ? (characters ?? charactersIgnoringModifiers) : charactersIgnoringModifiers
        guard let s = source, let u = s.unicodeScalars.first else { return nil }
        var v = u.value
        if v < 0x20 || v == 0x7f, let plain = charactersIgnoringModifiers?.unicodeScalars.first { v = plain.value }
        if v < 0x20 { return nil }
        return v < 0x100 ? v : 0x01000000 + v
    }
    static func keysym(_ e: NSEvent) -> UInt32? {
        keysym(keyCode: e.keyCode, characters: e.characters, charactersIgnoringModifiers: e.charactersIgnoringModifiers, shift: e.modifierFlags.contains(.shift))
    }

    /// "cmd+shift+c" style names for the keep-for-Mac list
    static func shortcutName(_ e: NSEvent) -> String? {
        guard let c = e.charactersIgnoringModifiers?.lowercased(), !c.isEmpty else { return nil }
        var parts: [String] = []
        if e.modifierFlags.contains(.control) { parts.append("ctrl") }
        if e.modifierFlags.contains(.option) { parts.append("opt") }
        if e.modifierFlags.contains(.shift) { parts.append("shift") }
        if e.modifierFlags.contains(.command) { parts.append("cmd") }
        let key: String
        switch e.keyCode { case 48: key = "tab"; case 49: key = "space"; case 53: key = "esc"; case 36: key = "return"; default: key = c }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
