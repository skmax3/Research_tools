import Combine
import Foundation

/// 設定（UserDefaults に保存。保存先: ~/Library/Preferences/io.github.skmax3.madowari.plist）
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var presets: [Preset] { didSet { savePresets() } }
    /// ウィンドウどうし・画面の端とのすき間（pt）
    @Published var gap: Double { didSet { d.set(gap, forKey: "gap") } }
    /// 「AI と並べる」で使うアプリ
    @Published var aiBundleID: String { didSet { d.set(aiBundleID, forKey: "aiBundleID") } }
    @Published var aiName: String { didSet { d.set(aiName, forKey: "aiName") } }
    @Published var aiOnLeft: Bool { didSet { d.set(aiOnLeft, forKey: "aiOnLeft") } }
    /// AI のウィンドウの幅（画面に対する割合）
    @Published var aiFraction: Double { didSet { d.set(aiFraction, forKey: "aiFraction") } }

    init() {
        d.register(defaults: [
            "gap": 8.0,
            "aiBundleID": KnownApp.claude.bundleID,
            "aiName": KnownApp.claude.name,
            "aiOnLeft": true,
            "aiFraction": 1.0 / 3.0,
        ])
        gap = d.double(forKey: "gap")
        aiBundleID = d.string(forKey: "aiBundleID") ?? KnownApp.claude.bundleID
        aiName = d.string(forKey: "aiName") ?? KnownApp.claude.name
        aiOnLeft = d.bool(forKey: "aiOnLeft")
        aiFraction = d.double(forKey: "aiFraction")
        if let data = d.data(forKey: "presets"), let p = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = p
        } else {
            presets = Preset.defaults
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) { d.set(data, forKey: "presets") }
    }

    func resetPresets() { presets = Preset.defaults }
}
