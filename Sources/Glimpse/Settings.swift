import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// A global keyboard shortcut, stored as a Carbon key code and modifier mask.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String

    /// Lightshot's default: ⇧⌘9.
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey), keyName: "9")

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Builds a shortcut from a key press. Returns nil unless the key has ⌘, ⌃ or ⌥, or is a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)
        let isFunctionKey = Shortcut.functionKeyNames[code] != nil
        guard isFunctionKey || !flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        guard let name = Shortcut.functionKeyNames[code] ?? Shortcut.specialKeyNames[code] ?? Shortcut.characterName(of: event) else {
            return nil
        }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        self.init(keyCode: UInt32(code), modifiers: carbon, keyName: name)
    }

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    /// The shortcut as a menu item key equivalent, when the key is a single character.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard keyName.count == 1 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (keyName.lowercased(), flags)
    }

    private static func characterName(of event: NSEvent) -> String? {
        guard let chars = event.characters(byApplyingModifiers: []), chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        return chars.uppercased()
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟"
    ]
}

enum ImageFormat: String {
    case png
    case jpeg

    var fileExtension: String { self == .png ? "png" : "jpg" }
    var contentType: UTType { self == .png ? .png : .jpeg }
}

/// The swatches offered by the colour picker. The first one is the default colour.
enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.15, blue: 0.15, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.19, green: 0.69, blue: 0.78, alpha: 1), // teal
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1), // indigo
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor(srgbRed: 1.00, green: 0.18, blue: 0.57, alpha: 1), // pink
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
        NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1), // grey
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1)  // black
    ]
}

enum Settings {
    private enum Key {
        static let shortcut = "shortcut"
        static let downscaleRetina = "downscaleRetina"
        static let saveFormat = "saveFormat"
        static let keepHistory = "keepHistory"
        static let lineWidth = "lineWidth"
        static let toolColor = "toolColor"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let askedForScreenAccess = "askedForScreenAccess"
    }

    private static var defaults: UserDefaults { .standard }

    static var shortcut: Shortcut {
        get {
            guard let data = defaults.data(forKey: Key.shortcut),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .standard }
            return shortcut
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.shortcut) }
    }

    /// Save Retina captures at 1× (point) resolution instead of full pixel resolution.
    static var downscaleRetina: Bool {
        get { defaults.bool(forKey: Key.downscaleRetina) }
        set { defaults.set(newValue, forKey: Key.downscaleRetina) }
    }

    static var saveFormat: ImageFormat {
        get { defaults.string(forKey: Key.saveFormat).flatMap(ImageFormat.init(rawValue:)) ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Key.saveFormat) }
    }

    /// Keep the last few screenshots for the menu bar's Recent list. On unless turned off.
    static var keepHistory: Bool {
        get { defaults.object(forKey: Key.keepHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.keepHistory) }
    }

    static var lineWidth: CGFloat {
        get {
            let value = defaults.double(forKey: Key.lineWidth)
            return value > 0 ? value : 3
        }
        set { defaults.set(Double(newValue), forKey: Key.lineWidth) }
    }

    static var toolColor: NSColor {
        get {
            guard let data = defaults.data(forKey: Key.toolColor),
                  let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
                return Palette.colors[0]
            }
            return color
        }
        set {
            defaults.set(try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true), forKey: Key.toolColor)
        }
    }

    static var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }

    static var askedForScreenAccess: Bool {
        get { defaults.bool(forKey: Key.askedForScreenAccess) }
        set { defaults.set(newValue, forKey: Key.askedForScreenAccess) }
    }
}
