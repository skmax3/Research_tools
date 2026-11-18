import Carbon.HIToolbox
import Foundation

/// ショートカットのキーの組み合わせ（設定に保存できる形）
struct KeyCombo: Codable, Hashable {
    /// キーの番号（kVK_…。キーボードの文字ではなく物理的な位置）
    var keyCode: Int
    /// 修飾キー（Carbon の cmdKey・optionKey・controlKey・shiftKey の組み合わせ）
    var modifiers: Int
    /// 表示用のキー名（例 "D"、"←"）
    var key: String

    init(_ keyCode: Int, _ modifiers: Int, _ key: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key ?? KeyCombo.specialName(keyCode) ?? "?"
    }

    static let co = controlKey | optionKey

    /// 表示（例 ⌃⌥←）。macOS のメニューと同じ ⌃⌥⇧⌘ の順
    var label: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    /// ⌃⌥⌘ のどれかを含むか（⇧ だけ・修飾なしは、普段の入力とぶつかるので使わない）
    var hasModifier: Bool { modifiers & (controlKey | optionKey | cmdKey) != 0 }

    /// メニューの右側に表示するためのキー（NSMenuItem.keyEquivalent）
    var menuKey: String {
        switch keyCode {
        case kVK_LeftArrow: return Self.char(0xF702)
        case kVK_RightArrow: return Self.char(0xF703)
        case kVK_UpArrow: return Self.char(0xF700)
        case kVK_DownArrow: return Self.char(0xF701)
        case kVK_Return: return "\r"
        case kVK_Delete: return "\u{8}"
        case kVK_ForwardDelete: return Self.char(0xF728)
        case kVK_Space: return " "
        case kVK_Tab: return "\t"
        case kVK_Escape: return "\u{1B}"
        case kVK_Home: return Self.char(0xF729)
        case kVK_End: return Self.char(0xF72B)
        case kVK_PageUp: return Self.char(0xF72C)
        case kVK_PageDown: return Self.char(0xF72D)
        default:
            if let i = Self.functionKeys.firstIndex(of: keyCode) { return Self.char(0xF704 + UInt32(i)) }
            return key.count == 1 ? key.lowercased() : ""
        }
    }

    private static func char(_ v: UInt32) -> String { String(Character(UnicodeScalar(v)!)) }

    static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// 文字ではないキーの名前（文字のキーは押したときの文字を使う）
    static func specialName(_ keyCode: Int) -> String? {
        switch keyCode {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Space: return "Space"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "esc"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let i = functionKeys.firstIndex(of: keyCode) { return "F\(i + 1)" }
            return nil
        }
    }

    /// ファンクションキー（修飾キーなしでも登録してよいキー）か
    var isFunctionKey: Bool { Self.functionKeys.contains(keyCode) }
}
