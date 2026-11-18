import AppKit
import CryptoKit
import UniformTypeIdentifiers

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
    /// そのアプリのバンドルID（アイコン表示・絞り込み用）
    var appID = ""
    var date = Date()
    var pinned = false
    /// 動画の長さ（秒）
    var duration: Double = 0
}

/// 古い版で保存した index.json（項目が足りない）も読めるようにする
extension ClipItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        hasRTF = try c.decodeIfPresent(Bool.self, forKey: .hasRTF) ?? false
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
    }

    /// 色分けの種類（テキストのうち URL だけのものは「リンク」）
    var category: ClipCategory {
        switch kind {
        case .image: return .image
        case .files:
            // Finder でコピーしたファイルは、中身が動画・画像ならそれとして色分けする
            let types = paths.map { UTType(filenameExtension: URL(fileURLWithPath: $0).pathExtension) }
            guard !types.isEmpty, types.allSatisfy({ $0 != nil }) else { return .file }
            if types.allSatisfy({ $0!.conforms(to: .movie) }) { return .video }
            if types.allSatisfy({ $0!.conforms(to: .image) }) { return .image }
            return .file
        case .text:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.contains("\n"), !t.contains(" "), let url = URL(string: t),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                return .link
            }
            return .text
        }
    }

    /// アプリでまとめるときのキー
    var appKey: String { appID.isEmpty ? app : appID }
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
    /// 画像の保存場所。iPhone から届いた写真は JPEG のまま（.jpg）、それ以外は PNG
    func imageURL(_ id: UUID) -> URL {
        let jpg = dir.appendingPathComponent("images/\(id.uuidString).jpg")
        return FileManager.default.fileExists(atPath: jpg.path) ? jpg : dir.appendingPathComponent("images/\(id.uuidString).png")
    }
    func thumbURL(_ id: UUID) -> URL { dir.appendingPathComponent("thumbs/\(id.uuidString).png") }
    func rtfURL(_ id: UUID) -> URL { dir.appendingPathComponent("rich/\(id.uuidString).rtf") }

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
        // 上限を超えて残っている古いもの（この機能を入れる前の分）を片付ける
        enforceLimits()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// 先頭に追加する。同じ内容がすでにあれば、新しく作らずに先頭へ移動する。
    func add(_ item: ClipItem, image: Data? = nil, imageExt: String = "png", thumb: Data? = nil, rtf: Data? = nil) {
        if let i = items.firstIndex(where: { $0.kind == item.kind && $0.hash == item.hash }) {
            var old = items.remove(at: i)
            old.date = Date()
            if !item.app.isEmpty { old.app = item.app; old.appID = item.appID }
            items.insert(old, at: 0)
            save()
            return
        }
        if let image { try? image.write(to: dir.appendingPathComponent("images/\(item.id.uuidString).\(imageExt)")) }
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

    /// 動画のサムネイル・大きさ・長さを後から入れる（読み込みに時間がかかるため）
    func updateMedia(_ id: UUID, thumb: Data?, width: Int, height: Int, duration: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let thumb {
            try? thumb.write(to: thumbURL(id))
            ThumbCache.shared.remove(id)
        }
        items[i].width = width
        items[i].height = height
        items[i].duration = duration
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

    /// 件数（maxItems）と容量（Settings.maxStorageMB）の上限を超えた分を、古いものから消す。ピン留めは消さない
    private func trim() {
        let mb = Settings.maxStorageMB
        let entries = items.map { StoragePolicy.Entry(pinned: $0.pinned, bytes: bytes(of: $0)) }
        let remove = StoragePolicy.toRemove(entries, maxItems: maxItems, maxBytes: mb > 0 ? Int64(mb) * 1024 * 1024 : nil)
        guard !remove.isEmpty else { return }
        for i in remove { removeFiles(items[i]) }
        items = items.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
    }

    /// 上限を変えたときなどに、すぐ片付ける
    func enforceLimits() {
        let before = items.count
        trim()
        if items.count != before { save() }
    }

    /// 1 件分のファイルの大きさ（画像・サムネイル・書式付きテキスト）
    func bytes(of item: ClipItem) -> Int64 {
        let jpg = dir.appendingPathComponent("images/\(item.id.uuidString).jpg")
        let png = dir.appendingPathComponent("images/\(item.id.uuidString).png")
        return [jpg, png, thumbURL(item.id), rtfURL(item.id)].reduce(Int64(0)) { sum, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    /// 保存フォルダ全体の使用量（バイト）
    func totalBytes() -> Int64 {
        items.reduce(Int64(0)) { $0 + bytes(of: $1) }
    }

    private func removeFiles(_ item: ClipItem) {
        let jpg = dir.appendingPathComponent("images/\(item.id.uuidString).jpg")
        for url in [imageURL(item.id), jpg, thumbURL(item.id), rtfURL(item.id)] {
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

    /// 長い辺が maxSide 以下になるように縮小した JPEG（iPhone へ送る写真用）
    static func jpegData(_ image: NSImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))  // 透明な部分は白にする（JPEG は透明を持てない）
        ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: quality])
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
