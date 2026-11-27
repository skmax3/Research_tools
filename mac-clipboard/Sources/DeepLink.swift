import Foundation

/// URL スキーム（clipshelf://）の解析。Logi Options+ のアクションリングなど、外から呼ぶために使う。
/// AppKit に依存しない（GitHub Actions で単体テストする）。
///
///   clipshelf://open                  パネルを開く（⇧⌘X と同じ）
///   clipshelf://open?kind=image       種類で絞り込んで開く（text / link / image / video / file）
///
/// kind が空・知らない値のときは、絞り込みなしで開く。知らないコマンドは、何もしない（nil）。
enum DeepLink: Equatable {
    case open(kind: String?)

    static let scheme = "clipshelf"
    /// 絞り込みに使える種類（ClipCategory の rawValue と同じ）
    static let kinds = ["text", "link", "image", "video", "file"]

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // clipshelf://open … は host、clipshelf:open や clipshelf:///open … は path に入る
        var command = (url.host ?? "").lowercased()
        if command.isEmpty {
            command = url.path.split(separator: "/").first.map { String($0).lowercased() } ?? ""
        }
        guard command == "open" else { return nil }

        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name.lowercased() == "kind" }?.value?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let kind = value.flatMap { kinds.contains($0) ? $0 : nil }
        return .open(kind: kind)
    }
}
