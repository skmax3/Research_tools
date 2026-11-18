import AppKit
import Carbon.HIToolbox

/// ショートカットでできること
enum WindowAction {
    /// 同じキーを続けて押すと、zones の順に切り替わる
    case snap([NamedZone])
    /// 今いる列の中で上半分・下半分にする（もう一度押すと横幅いっぱいの上半分・下半分）
    case half(top: Bool)
    case display(Int)   // 隣の画面へ（-1: 左、+1: 右）
    case undo
    case grid
    case ai
    case preset(Int)    // 0 始まり
}

/// ショートカットの一覧。登録（App.swift）と設定画面の表で同じものを使う
struct Shortcut: Identifiable {
    let id = UUID()
    let keyCode: Int
    let modifiers: Int
    let label: String       // 表示用（例 ⌃⌥←）
    let title: String
    let action: WindowAction
    /// メニューに表示するキー（NSMenuItem の keyEquivalent）
    let menuKey: String

    static let co = controlKey | optionKey

    private static func arrow(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt32(code))!))
    }

    static let windowKeys: [Shortcut] = [
        Shortcut(keyCode: kVK_LeftArrow, modifiers: co, label: "⌃⌥←", title: "左半分 → 左 2/3 → 左 1/3（押すたびに切り替え）",
                 action: .snap([.leftHalf, .leftTwoThirds, .leftThird]), menuKey: arrow(NSLeftArrowFunctionKey)),
        Shortcut(keyCode: kVK_RightArrow, modifiers: co, label: "⌃⌥→", title: "右半分 → 右 2/3 → 右 1/3（押すたびに切り替え）",
                 action: .snap([.rightHalf, .rightTwoThirds, .rightThird]), menuKey: arrow(NSRightArrowFunctionKey)),
        Shortcut(keyCode: kVK_UpArrow, modifiers: co, label: "⌃⌥↑", title: "今の列の上半分 → 横幅いっぱいの上半分",
                 action: .half(top: true), menuKey: arrow(NSUpArrowFunctionKey)),
        Shortcut(keyCode: kVK_DownArrow, modifiers: co, label: "⌃⌥↓", title: "今の列の下半分 → 横幅いっぱいの下半分",
                 action: .half(top: false), menuKey: arrow(NSDownArrowFunctionKey)),
        Shortcut(keyCode: kVK_ANSI_D, modifiers: co, label: "⌃⌥D", title: "左 1/3 → 左 1/3 の上 → 下",
                 action: .snap([.leftThird, .leftThirdTop, .leftThirdBottom]), menuKey: "d"),
        Shortcut(keyCode: kVK_ANSI_F, modifiers: co, label: "⌃⌥F", title: "中央 1/3 → 中央 1/3 の上 → 下",
                 action: .snap([.centerThird, .centerThirdTop, .centerThirdBottom]), menuKey: "f"),
        Shortcut(keyCode: kVK_ANSI_G, modifiers: co, label: "⌃⌥G", title: "右 1/3 → 右 1/3 の上 → 下",
                 action: .snap([.rightThird, .rightThirdTop, .rightThirdBottom]), menuKey: "g"),
        Shortcut(keyCode: kVK_ANSI_E, modifiers: co, label: "⌃⌥E", title: "左 2/3",
                 action: .snap([.leftTwoThirds]), menuKey: "e"),
        Shortcut(keyCode: kVK_ANSI_T, modifiers: co, label: "⌃⌥T", title: "右 2/3",
                 action: .snap([.rightTwoThirds]), menuKey: "t"),
        Shortcut(keyCode: kVK_ANSI_C, modifiers: co, label: "⌃⌥C", title: "中央 1/2 → 中央に大きく",
                 action: .snap([.centerHalf, .center]), menuKey: "c"),
        Shortcut(keyCode: kVK_ANSI_U, modifiers: co, label: "⌃⌥U", title: "左上 1/4",
                 action: .snap([.topLeft]), menuKey: "u"),
        Shortcut(keyCode: kVK_ANSI_I, modifiers: co, label: "⌃⌥I", title: "右上 1/4",
                 action: .snap([.topRight]), menuKey: "i"),
        Shortcut(keyCode: kVK_ANSI_J, modifiers: co, label: "⌃⌥J", title: "左下 1/4",
                 action: .snap([.bottomLeft]), menuKey: "j"),
        Shortcut(keyCode: kVK_ANSI_K, modifiers: co, label: "⌃⌥K", title: "右下 1/4",
                 action: .snap([.bottomRight]), menuKey: "k"),
        Shortcut(keyCode: kVK_Return, modifiers: co, label: "⌃⌥↩", title: "全体（最大化）",
                 action: .snap([.maximize]), menuKey: "\r"),
        Shortcut(keyCode: kVK_LeftArrow, modifiers: co | cmdKey, label: "⌃⌥⌘←", title: "左の画面へ移す（同じ割合で）",
                 action: .display(-1), menuKey: arrow(NSLeftArrowFunctionKey)),
        Shortcut(keyCode: kVK_RightArrow, modifiers: co | cmdKey, label: "⌃⌥⌘→", title: "右の画面へ移す（同じ割合で）",
                 action: .display(1), menuKey: arrow(NSRightArrowFunctionKey)),
        Shortcut(keyCode: kVK_Delete, modifiers: co, label: "⌃⌥⌫", title: "元の位置に戻す",
                 action: .undo, menuKey: "\u{8}"),
    ]

    static let toolKeys: [Shortcut] = [
        Shortcut(keyCode: kVK_ANSI_A, modifiers: co, label: "⌃⌥A", title: "AI と並べる（作業中のウィンドウの横に AI を出す）",
                 action: .ai, menuKey: "a"),
        Shortcut(keyCode: kVK_ANSI_W, modifiers: co, label: "⌃⌥W", title: "マス目で場所を指定（ドラッグ）",
                 action: .grid, menuKey: "w"),
    ]

    static let presetKeys: [Shortcut] = {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return codes.enumerated().map { i, code in
            Shortcut(keyCode: code, modifiers: Shortcut.co, label: "⌃⌥\(i + 1)", title: "配置プリセット \(i + 1)",
                     action: .preset(i), menuKey: "\(i + 1)")
        }
    }()

    static var all: [Shortcut] { windowKeys + toolKeys + presetKeys }

    /// NSMenuItem 用の修飾キー
    var menuModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { m.insert(.control) }
        if modifiers & optionKey != 0 { m.insert(.option) }
        if modifiers & cmdKey != 0 { m.insert(.command) }
        if modifiers & shiftKey != 0 { m.insert(.shift) }
        return m
    }
}
