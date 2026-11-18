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
    case panel          // 配置パネル（マス目・プリセット・AI）
    case ai
    case preset(Int)    // 0 始まり
    case toggleBarrier  // 境目でカーソルを止める機能のオン・オフ
    case tidy           // 手前の数個のアプリだけ残し、ほかを隠す（マウスのある画面）
}

/// ショートカットの一覧。登録（App.swift）・メニュー・設定画面で同じものを使う。
/// キーは設定画面で変えられる（変えたキーは AppSettings.shortcutOverrides に保存）。
/// 新しい操作を足すときは、ここに 1 行足して、App.swift の perform に処理を書く。
struct Shortcut: Identifiable {
    /// 保存用の名前（変えると、ユーザーが変えたキーの設定が消えるので変えない）
    let id: String
    let title: String
    let action: WindowAction
    let defaultCombo: KeyCombo?

    private static let co = KeyCombo.co

    private static func s(_ id: String, _ code: Int, _ mods: Int, _ title: String, _ action: WindowAction,
                          key: String? = nil) -> Shortcut {
        Shortcut(id: id, title: title, action: action, defaultCombo: KeyCombo(code, mods, key))
    }

    /// 手前のウィンドウを動かす
    static let windowKeys: [Shortcut] = [
        s("left", kVK_LeftArrow, co, "左半分 → 左 2/3 → 左 1/3（押すたびに切り替え）",
          .snap([.leftHalf, .leftTwoThirds, .leftThird])),
        s("right", kVK_RightArrow, co, "右半分 → 右 2/3 → 右 1/3（押すたびに切り替え）",
          .snap([.rightHalf, .rightTwoThirds, .rightThird])),
        s("up", kVK_UpArrow, co, "今の列の上半分 → 横幅いっぱいの上半分", .half(top: true)),
        s("down", kVK_DownArrow, co, "今の列の下半分 → 横幅いっぱいの下半分", .half(top: false)),
        s("third-left", kVK_ANSI_D, co, "左 1/3 → 左 1/3 の上 → 下", .snap([.leftThird, .leftThirdTop, .leftThirdBottom]), key: "D"),
        s("third-center", kVK_ANSI_F, co, "中央 1/3 → 中央 1/3 の上 → 下",
          .snap([.centerThird, .centerThirdTop, .centerThirdBottom]), key: "F"),
        s("third-right", kVK_ANSI_G, co, "右 1/3 → 右 1/3 の上 → 下", .snap([.rightThird, .rightThirdTop, .rightThirdBottom]), key: "G"),
        s("two-left", kVK_ANSI_E, co, "左 2/3", .snap([.leftTwoThirds]), key: "E"),
        s("two-right", kVK_ANSI_T, co, "右 2/3", .snap([.rightTwoThirds]), key: "T"),
        s("center", kVK_ANSI_C, co, "中央 1/2 → 中央に大きく", .snap([.centerHalf, .center]), key: "C"),
        s("top-left", kVK_ANSI_U, co, "左上 1/4", .snap([.topLeft]), key: "U"),
        s("top-right", kVK_ANSI_I, co, "右上 1/4", .snap([.topRight]), key: "I"),
        s("bottom-left", kVK_ANSI_J, co, "左下 1/4", .snap([.bottomLeft]), key: "J"),
        s("bottom-right", kVK_ANSI_K, co, "右下 1/4", .snap([.bottomRight]), key: "K"),
        s("maximize", kVK_Return, co, "全体（最大化）", .snap([.maximize])),
        s("display-left", kVK_LeftArrow, co | cmdKey, "左の画面へ移す（同じ割合で）", .display(-1)),
        s("display-right", kVK_RightArrow, co | cmdKey, "右の画面へ移す（同じ割合で）", .display(1)),
        s("undo", kVK_Delete, co, "元の位置に戻す", .undo),
    ]

    /// 道具
    static let toolKeys: [Shortcut] = [
        s("panel", kVK_ANSI_W, co, "配置パネルを開く（マス目・プリセット・AI をマウスで）", .panel, key: "W"),
        s("ai", kVK_ANSI_A, co, "AI と並べる（作業中のウィンドウの横に AI を出す）", .ai, key: "A"),
        s("barrier", kVK_ANSI_B, co, "境目でカーソルを止める：オン・オフ", .toggleBarrier, key: "B"),
        s("tidy", kVK_ANSI_H, co, "この画面を整理（手前の数個のアプリだけ残し、ほかを隠す）", .tidy, key: "H"),
    ]

    /// 配置プリセット 1〜9
    static let presetKeys: [Shortcut] = {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return codes.enumerated().map { i, code in
            Shortcut(id: "preset\(i + 1)", title: "配置プリセット \(i + 1)", action: .preset(i),
                     defaultCombo: KeyCombo(code, KeyCombo.co, "\(i + 1)"))
        }
    }()

    static var all: [Shortcut] { windowKeys + toolKeys + presetKeys }

    static func named(_ id: String) -> Shortcut? { all.first { $0.id == id } }
}

extension KeyCombo {
    /// NSMenuItem 用の修飾キー
    var menuModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { m.insert(.control) }
        if modifiers & optionKey != 0 { m.insert(.option) }
        if modifiers & cmdKey != 0 { m.insert(.command) }
        if modifiers & shiftKey != 0 { m.insert(.shift) }
        return m
    }

    /// 設定画面で押されたキーから作る
    init(event: NSEvent) {
        var m = 0
        let f = event.modifierFlags
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.shift) { m |= shiftKey }
        let code = Int(event.keyCode)
        let name = KeyCombo.specialName(code) ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(code, m, name)
    }
}
