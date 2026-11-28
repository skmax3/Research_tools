import Foundation

/// URL スキーム（clipshelf://）の解析。Logi Options+ のアクションリングなど、外から呼ぶために使う。
/// AppKit に依存しない（GitHub Actions で単体テストする）。
///
///   clipshelf://open                    パネルを開く（⇧⌘X と同じ）
///   clipshelf://open?kind=image         種類で絞り込んで開く（text / link / image / video / file）
///   clipshelf://paste                   いちばん新しい履歴を、今のアプリに貼る
///   clipshelf://paste?n=2               新しいほうから 2 番目を貼る（n は 1〜9。「ひとつ前」を貼るのに便利）
///   clipshelf://paste?kind=image        いちばん新しい画像を貼る（n と組み合わせてもよい）
///   clipshelf://transform?type=joinLines  いちばん新しいテキストを変換して貼る（type は TextTransform の名前）
///   clipshelf://send                    いちばん新しい履歴を、ほかの端末へ送る
///   clipshelf://pause[?state=on|off]    記録の一時停止（state なしなら切り替え）
///
/// open 以外は、人が選ばずに貼ったり送ったりするので、メニューで許可したときだけ動く（AppDelegate 側）。
/// kind が空・知らない値のときは「絞り込みなし」。知らないコマンド・type は何もしない（nil）。
enum DeepLink: Equatable {
    enum PauseMode: String { case toggle, on, off }

    case open(kind: String?)
    case paste(index: Int, kind: String?)
    case transform(type: String)
    case send
    case pause(PauseMode)

    static let scheme = "clipshelf"
    /// 絞り込みに使える種類（ClipCategory の rawValue と同じ）
    static let kinds = ["text", "link", "image", "video", "file"]

    /// 人が選ばずに貼る・送る・変える・止めるコマンドか（メニューでの許可が要る）
    var needsPermission: Bool {
        if case .open = self { return false }
        return true
    }

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // コマンドは、スキームの直後（// や / があれば読み飛ばす）から、/ ? # : の手前まで。
        // clipshelf://open も clipshelf:open も clipshelf:///open も同じに読む（host / path の扱いは形で変わるので使わない）
        var rest = Substring(url.absoluteString.dropFirst(scheme.count + 1))
        rest = rest.drop { $0 == "/" }
        let command = String(rest.prefix { !"/?#:".contains($0) }).lowercased()

        let items = URLComponents(string: url.absoluteString)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        let kind = value("kind").flatMap { kinds.contains($0) ? $0 : nil }

        switch command {
        case "open":
            return .open(kind: kind)
        case "paste":
            // n は 1〜9。ない・不正なときは 1（いちばん新しいもの）
            let n = value("n").flatMap(Int.init).flatMap { (1...9).contains($0) ? $0 : nil } ?? 1
            return .paste(index: n, kind: kind)
        case "transform":
            // type は TextTransform の名前（大文字小文字は区別しない）。ないもの・知らないものは何もしない
            guard let raw = value("type"),
                  let t = TextTransform.allCases.first(where: { $0.rawValue.lowercased() == raw }) else { return nil }
            return .transform(type: t.rawValue)
        case "send":
            return .send
        case "pause":
            return .pause(value("state").flatMap(PauseMode.init(rawValue:)) ?? .toggle)
        default:
            return nil
        }
    }
}
