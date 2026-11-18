import Foundation

/// プリセットをどの画面に並べるか
enum ScreenTarget: String, Codable, CaseIterable, Identifiable {
    case largest   // 一番大きい画面（27 インチ 4K を想定）
    case mouse     // マウスのある画面
    case builtin   // MacBook 本体の画面

    var id: String { rawValue }
    var title: String {
        switch self {
        case .largest: return "一番大きい画面（4K モニター）"
        case .mouse: return "マウスのある画面"
        case .builtin: return "MacBook 本体の画面"
        }
    }
}

/// プリセットの 1 行：「このアプリのウィンドウを、この場所へ」
struct Slot: Codable, Identifiable, Hashable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var zone: Zone
    /// 起動していなければ起動する（ウィンドウがなければ開き直す）
    var launch = false
    /// 並べたあとフルスクリーンにする（MacBook 本体の画面で全画面で使うときなど）
    var fullScreen = false

    init(bundleID: String, appName: String, zone: Zone, launch: Bool = false, fullScreen: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.zone = zone
        self.launch = launch
        self.fullScreen = fullScreen
    }

    init(_ app: KnownApp, _ z: NamedZone, launch: Bool = false) {
        self.init(bundleID: app.bundleID, appName: app.name, zone: z.zone, launch: launch)
    }

    // 将来、項目が増えても古い保存データを読めるように、ない項目は初期値にする
    enum CodingKeys: String, CodingKey { case id, bundleID, appName, zone, launch, fullScreen }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
        zone = try c.decode(Zone.self, forKey: .zone)
        launch = try c.decodeIfPresent(Bool.self, forKey: .launch) ?? false
        fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? false
    }
}

/// 配置プリセット（⌃⌥1〜9 で呼び出す）
struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var slots: [Slot]
    var screen: ScreenTarget = .largest
    /// プリセットにないアプリを隠す（集中したいとき）
    var hideOthers = false
    /// 並べる前に切り替えるデスクトップ（1〜9）。0 なら今のデスクトップのまま
    var desktop = 0

    init(name: String, slots: [Slot], screen: ScreenTarget = .largest, hideOthers: Bool = false, desktop: Int = 0) {
        self.name = name
        self.slots = slots
        self.screen = screen
        self.hideOthers = hideOthers
        self.desktop = desktop
    }

    enum CodingKeys: String, CodingKey { case id, name, slots, screen, hideOthers, desktop }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "プリセット"
        slots = try c.decodeIfPresent([Slot].self, forKey: .slots) ?? []
        screen = (try? c.decodeIfPresent(ScreenTarget.self, forKey: .screen)) ?? .largest
        hideOthers = try c.decodeIfPresent(Bool.self, forKey: .hideOthers) ?? false
        desktop = try c.decodeIfPresent(Int.self, forKey: .desktop) ?? 0
    }

    /// 初めて起動したときのプリセット（設定画面で自由に変えられる）
    static var defaults: [Preset] {
        [
            Preset(name: "AI ＋ 論文・レポート執筆 ＋ PDF", slots: [
                Slot(.claude, .leftThird, launch: true),
                Slot(.word, .centerThird),
                Slot(.preview, .rightThird),
            ]),
            Preset(name: "AI ＋ コード（Python・MATLAB など）", slots: [
                Slot(.claude, .leftThird, launch: true),
                Slot(.vscode, .rightTwoThirds),
            ]),
            Preset(name: "AI ＋ 調べもの（6 分割）", slots: [
                Slot(.claude, .leftThird, launch: true),
                Slot(.safari, .centerThird),
                Slot(.preview, .rightThirdTop),
                Slot(.finder, .rightThirdBottom),
            ]),
            Preset(name: "資料を読みながら AI に聞く", slots: [
                Slot(.preview, .leftTwoThirds),
                Slot(.claude, .rightThird, launch: true),
            ]),
        ]
    }
}

/// よく使うアプリ（バンドル ID はアプリごとに決まった名前）
struct KnownApp: Hashable {
    let bundleID: String
    let name: String

    static let claude = KnownApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude")
    static let chatgpt = KnownApp(bundleID: "com.openai.chat", name: "ChatGPT")
    static let safari = KnownApp(bundleID: "com.apple.Safari", name: "Safari")
    static let chrome = KnownApp(bundleID: "com.google.Chrome", name: "Google Chrome")
    static let word = KnownApp(bundleID: "com.microsoft.Word", name: "Microsoft Word")
    static let excel = KnownApp(bundleID: "com.microsoft.Excel", name: "Microsoft Excel")
    static let powerpoint = KnownApp(bundleID: "com.microsoft.Powerpoint", name: "Microsoft PowerPoint")
    static let preview = KnownApp(bundleID: "com.apple.Preview", name: "プレビュー")
    static let finder = KnownApp(bundleID: "com.apple.finder", name: "Finder")
    static let vscode = KnownApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")
    static let terminal = KnownApp(bundleID: "com.apple.Terminal", name: "ターミナル")
    static let notes = KnownApp(bundleID: "com.apple.Notes", name: "メモ")
    static let notion = KnownApp(bundleID: "notion.id", name: "Notion")
    static let zotero = KnownApp(bundleID: "org.zotero.zotero", name: "Zotero")

    static let all: [KnownApp] = [claude, chatgpt, safari, chrome, word, excel, powerpoint, preview, finder,
                                  vscode, terminal, notes, notion, zotero]
}

/// 「AI と並べる」で使う場所の計算（テストできるようにここに置く）
enum AIPairing {
    /// AI のウィンドウの場所と、作業中のウィンドウの場所
    static func zones(aiOnLeft: Bool, fraction: Double) -> (ai: Zone, work: Zone) {
        let f = min(max(fraction, 0.15), 0.85)
        return aiOnLeft
            ? (Zone(0, 0, f, 1), Zone(f, 0, 1 - f, 1))
            : (Zone(1 - f, 0, f, 1), Zone(0, 0, 1 - f, 1))
    }
}
