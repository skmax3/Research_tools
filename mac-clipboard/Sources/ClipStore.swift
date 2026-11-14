import AppKit
import CryptoKit

enum ClipKind: String, Codable {
    case text, image, files
}

/// 履歴の1件。画像・書式付きテキストの中身は別ファイルに保存し、ここには情報だけ持つ。
struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind
    /// テキスト本体。ファイルの場合はファイル名の一覧（検索用）
    var text = ""
    /// 書式付き（RTF）も保存しているか
    var hasRTF = false
    /// ファイルの場合のパス
    var paths: [String] = []
    var width = 0
    var height = 0
    /// 同じ内容かどうかの判定用
    var hash = ""
    /// コピーしたときに前面にあったアプリ名
    var app = ""
    var date = Date()
    var pinned = false
}

/// 履歴の保存場所: ~/Library/Application Support/ClipShelf/
///   index.json（一覧）, images/（画像PNG）, thumbs/（縮小画像）, rich/（RTF）
/// すべて Mac の中だけに保存し、外部には送らない。
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    let dir: URL
    /// ピン留め以外に残す件数
    var maxItems = 500

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("ClipShelf", isDirectory: true)
        for sub in ["images", "thumbs", "rich"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
    }

    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    func imageURL(_ id: UUID) -> URL { dir.appendingPathComponent("images/\(id.uuidString).png") }
    func thumbURL(_ id: UUID) -> URL { dir.appendingPathComponent("thumbs/\(id.uuidString).png") }
    func rtfURL(_ id: UUID) -> URL { dir.appendingPathComponent("rich/\(id.uuidString).rtf") }

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// 先頭に追加する。同じ内容がすでにあれば、新しく作らずに先頭へ移動する。
    func add(_ item: ClipItem, image: Data? = nil, thumb: Data? = nil, rtf: Data? = nil) {
        if let i = items.firstIndex(where: { $0.kind == item.kind && $0.hash == item.hash }) {
            var old = items.remove(at: i)
            old.date = Date()
            if !item.app.isEmpty { old.app = item.app }
            items.insert(old, at: 0)
            save()
            return
        }
        if let image { try? image.write(to: imageURL(item.id)) }
        if let thumb { try? thumb.write(to: thumbURL(item.id)) }
        if let rtf { try? rtf.write(to: rtfURL(item.id)) }
        items.insert(item, at: 0)
        trim()
        save()
    }

    func moveToTop(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i != 0 else { return }
        var item = items.remove(at: i)
        item.date = Date()
        items.insert(item, at: 0)
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        save()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(items[i])
        items.remove(at: i)
        save()
    }

    func clearUnpinned() {
        for item in items where !item.pinned { removeFiles(item) }
        items.removeAll { !$0.pinned }
        save()
    }

    private func trim() {
        var count = 0
        var keep: [ClipItem] = []
        for item in items {
            if item.pinned {
                keep.append(item)
            } else {
                count += 1
                if count <= maxItems { keep.append(item) } else { removeFiles(item) }
            }
        }
        items = keep
    }

    private func removeFiles(_ item: ClipItem) {
        for url in [imageURL(item.id), thumbURL(item.id), rtfURL(item.id)] {
            try? FileManager.default.removeItem(at: url)
        }
        ThumbCache.shared.remove(item.id)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 画像の変換（PNG化・縮小）
enum ImageUtil {
    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// 長い辺が maxSide 以下になるように縮小した PNG
    static func thumbnail(_ image: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    static func pixelSize(_ image: NSImage) -> (Int, Int) {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return (cg.width, cg.height) }
        return (Int(image.size.width), Int(image.size.height))
    }
}

/// 縮小画像を何度も読み込まないための入れ物
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSUUID, NSImage>()

    func image(for item: ClipItem, store: ClipStore) -> NSImage? {
        if let img = cache.object(forKey: item.id as NSUUID) { return img }
        guard let img = NSImage(contentsOf: store.thumbURL(item.id)) else { return nil }
        cache.setObject(img, forKey: item.id as NSUUID)
        return img
    }

    func remove(_ id: UUID) { cache.removeObject(forKey: id as NSUUID) }
}
