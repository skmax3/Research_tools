import Foundation

/// URL スキーム `madowari://run/<ショートカットの id>` の解析（画面にも AppKit にも触らないので、Tests/main.swift で確かめられる）。
/// 例: madowari://run/left, madowari://run/preset1, madowari://run/panel
/// id は Shortcuts.swift の `Shortcut.id`。URL からの呼び出しの公開名でもあるので、あとで変えない。
enum MadoWariURL {
    static let scheme = "madowari"
    static let runHost = "run"

    /// URL から id を取り出す。形が違えば nil（スキーム・ホストの大文字小文字、末尾の / 、?クエリ は許す）
    static func shortcutID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == runHost else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1 else { return nil }
        let id = String(parts[0]).lowercased()
        return id.isEmpty || id.count > 64 ? nil : id
    }
}
