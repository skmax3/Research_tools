import Foundation
import CryptoKit

/// iPhone 用 Web アプリ（clip-send/index.html の SYNC-BEGIN〜END）と同じ暗号の取り決め。
/// Foundation と CryptoKit だけで書いてあり、Tests/main.swift で Web 版が作った固定の値と一致することを確かめる。
///
///   秘密 K（32バイト）→ HKDF-SHA256（salt = "clipshelf-v1"）で
///     部屋ID = HKDF(info = "clipshelf-v1 room", 16バイト) の base64url（22文字）
///     暗号鍵 = HKDF(info = "clipshelf-v1 enc", 32バイト) を AES-256-GCM に使う
///   送るデータ   = [0x01][nonce 12バイト][AES-GCM の暗号文＋タグ16バイト（追加認証データ = "clipshelf-v1"）]
///   暗号化する中身 = [メタ情報の長さ 4バイト（ビッグエンディアン）][メタ情報 JSON][本体]
enum SyncCrypto {
    static let tag = Data("clipshelf-v1".utf8)

    struct Keys {
        let room: String
        let key: SymmetricKey
    }

    struct Opened {
        let meta: [String: Any]
        let body: Data
    }

    enum Failure: Error {
        case badSecret
        case badFormat
    }

    // MARK: base64url

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url（普通の base64 も可）→ Data
    static func fromBase64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: 鍵

    static func newSecret() -> String {
        base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    static func derive(secret: String) throws -> Keys {
        guard let raw = fromBase64(secret), raw.count == 32 else { throw Failure.badSecret }
        let ikm = SymmetricKey(data: raw)
        func bits(_ info: String, _ count: Int) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: tag,
                                   info: Data("clipshelf-v1 \(info)".utf8), outputByteCount: count)
        }
        let room = bits("room", 16).withUnsafeBytes { base64url(Data($0)) }
        return Keys(room: room, key: bits("enc", 32))
    }

    // MARK: 暗号化・復号

    /// nonce はテスト用（普通は省略して毎回ランダムにする）
    static func seal(_ keys: Keys, meta: Data, body: Data, nonce: AES.GCM.Nonce? = nil) throws -> Data {
        var plain = Data()
        var length = UInt32(meta.count).bigEndian
        withUnsafeBytes(of: &length) { plain.append(contentsOf: $0) }
        plain.append(meta)
        plain.append(body)
        let box = try AES.GCM.seal(plain, using: keys.key, nonce: nonce, authenticating: tag)
        guard let combined = box.combined else { throw Failure.badFormat }
        return Data([1]) + combined
    }

    static func seal(_ keys: Keys, kind: String, name: String, mime: String, body: Data) throws -> Data {
        let meta = try JSONSerialization.data(withJSONObject: ["k": kind, "name": name, "mime": mime])
        return try seal(keys, meta: meta, body: body)
    }

    static func open(_ keys: Keys, _ data: Data) throws -> Opened {
        guard data.count > 1 + 12 + 16, data[data.startIndex] == 1 else { throw Failure.badFormat }
        let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst()))
        let plain = try AES.GCM.open(box, using: keys.key, authenticating: tag)
        guard plain.count >= 4 else { throw Failure.badFormat }
        let n = Int(plain[0]) << 24 | Int(plain[1]) << 16 | Int(plain[2]) << 8 | Int(plain[3])
        guard 4 + n <= plain.count,
              let meta = try JSONSerialization.jsonObject(with: plain.subdata(in: 4..<(4 + n))) as? [String: Any]
        else { throw Failure.badFormat }
        return Opened(meta: meta, body: plain.subdata(in: (4 + n)..<plain.count))
    }
}
