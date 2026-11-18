import Foundation

/// ステージマネージャ（macOS 13 Ventura から。ウィンドウを左の帯にしまって、1 つずつ前に出す機能）。
/// オンのままだと、アプリを手前に出すたびに、それまで手前だったアプリが左の帯へしまわれる。
/// そのため、いくつものアプリをまとめて並べると、最後のアプリしか画面に残らない。
/// 窓割りは、まとめて並べる前にステージマネージャをオフにする（設定で変えられる）。
///
/// 設定の保存先はシステムの `com.apple.WindowManager` の `GloballyEnabled`。
/// ターミナルの `defaults write com.apple.WindowManager GloballyEnabled -bool false` と同じで、書くとすぐに反映される。
enum StageManager {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let key = "GloballyEnabled" as CFString

    /// いまオンか
    static var isOn: Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain) as? Bool) ?? false
    }

    /// オン・オフを切り替える（コントロールセンターのボタンと同じ）。うまくいったら true
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", on ? "true" : "false"]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return false
        }
        return isOn == on
    }
}
