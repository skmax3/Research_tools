import Combine
import Foundation

/// 設定（UserDefaults に保存。保存先: ~/Library/Preferences/io.github.skmax3.madowari.plist）
/// 設定を足すときは: @Published の行を足す → init で読み込む → 初期値を register に足す → 設定画面に部品を足す
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var presets: [Preset] { didSet { save(presets, "presets") } }
    /// ウィンドウどうし・画面の端とのすき間（pt）
    @Published var gap: Double { didSet { d.set(gap, forKey: "gap") } }

    // MARK: AI と並べる
    @Published var aiBundleID: String { didSet { d.set(aiBundleID, forKey: "aiBundleID") } }
    @Published var aiName: String { didSet { d.set(aiName, forKey: "aiName") } }
    @Published var aiOnLeft: Bool { didSet { d.set(aiOnLeft, forKey: "aiOnLeft") } }
    /// AI のウィンドウの幅（画面に対する割合）
    @Published var aiFraction: Double { didSet { d.set(aiFraction, forKey: "aiFraction") } }

    // MARK: 動かし方
    /// フルスクリーンのウィンドウは、解除してから並べる
    @Published var exitFullScreen: Bool { didSet { d.set(exitFullScreen, forKey: "exitFullScreen") } }
    /// 動かしたときに、場所の名前を画面に一瞬出す
    @Published var showToast: Bool { didSet { d.set(showToast, forKey: "showToast") } }

    // MARK: 境目でカーソルを止める
    @Published var edgeBarrier: Bool { didSet { d.set(edgeBarrier, forKey: "edgeBarrier") } }
    /// 止める時間（秒）
    @Published var edgeHold: Double { didSet { d.set(edgeHold, forKey: "edgeHold") } }
    /// 上下左右すべての境目で止める（オフなら下の境目だけ）
    @Published var edgeAllSides: Bool { didSet { d.set(edgeAllSides, forKey: "edgeAllSides") } }

    // MARK: ショートカット
    /// ユーザーが変えたキー（Shortcut.id → キー）
    @Published var shortcutOverrides: [String: KeyCombo] { didSet { save(shortcutOverrides, "shortcutOverrides") } }
    /// オフにしたショートカット（Shortcut.id）
    @Published var disabledShortcuts: Set<String> { didSet { save(disabledShortcuts, "disabledShortcuts") } }
    /// 設定画面でキーを記録している間は、ショートカットを止める（保存しない）
    @Published var isRecordingShortcut = false

    init() {
        d.register(defaults: [
            "gap": 8.0,
            "aiBundleID": KnownApp.claude.bundleID,
            "aiName": KnownApp.claude.name,
            "aiOnLeft": true,
            "aiFraction": 1.0 / 3.0,
            "exitFullScreen": true,
            "showToast": true,
            "edgeBarrier": true,
            "edgeHold": 0.4,
            "edgeAllSides": false,
        ])
        gap = d.double(forKey: "gap")
        aiBundleID = d.string(forKey: "aiBundleID") ?? KnownApp.claude.bundleID
        aiName = d.string(forKey: "aiName") ?? KnownApp.claude.name
        aiOnLeft = d.bool(forKey: "aiOnLeft")
        aiFraction = d.double(forKey: "aiFraction")
        exitFullScreen = d.bool(forKey: "exitFullScreen")
        showToast = d.bool(forKey: "showToast")
        edgeBarrier = d.bool(forKey: "edgeBarrier")
        edgeHold = d.double(forKey: "edgeHold")
        edgeAllSides = d.bool(forKey: "edgeAllSides")
        presets = Self.load([Preset].self, "presets", from: d) ?? Preset.defaults
        shortcutOverrides = Self.load([String: KeyCombo].self, "shortcutOverrides", from: d) ?? [:]
        disabledShortcuts = Self.load(Set<String>.self, "disabledShortcuts", from: d) ?? []
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func resetPresets() { presets = Preset.defaults }

    // MARK: ショートカットのキー

    /// 今使うキー（オフなら nil）
    func combo(for s: Shortcut) -> KeyCombo? {
        if disabledShortcuts.contains(s.id) { return nil }
        return shortcutOverrides[s.id] ?? s.defaultCombo
    }

    func setCombo(_ c: KeyCombo?, for s: Shortcut) {
        if let c {
            disabledShortcuts.remove(s.id)
            if c == s.defaultCombo { shortcutOverrides[s.id] = nil } else { shortcutOverrides[s.id] = c }
        } else {
            disabledShortcuts.insert(s.id)
        }
    }

    func resetCombo(for s: Shortcut) {
        disabledShortcuts.remove(s.id)
        shortcutOverrides[s.id] = nil
    }

    func resetAllShortcuts() {
        disabledShortcuts = []
        shortcutOverrides = [:]
    }

    /// 同じキーを使っているほかのショートカット
    func conflict(_ c: KeyCombo, except s: Shortcut) -> Shortcut? {
        Shortcut.all.first { $0.id != s.id && combo(for: $0).map { $0.keyCode == c.keyCode && $0.modifiers == c.modifiers } == true }
    }
}
