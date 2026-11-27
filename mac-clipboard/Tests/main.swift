// Transforms.swift の確認（GitHub Actions で実行: swiftc Sources/Transforms.swift Tests/main.swift）
// 期待値は Web 版 clipboard/index.html の同じ変換の出力
import AppKit
import Foundation
import CryptoKit

var failed = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want {
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)\n  got:  \(got.debugDescription)\n  want: \(want.debugDescription)")
    }
}

check("joinLines",
      Transforms.joinLines("これは日本語の\n文章です。\n次の段落\nline one\ncontinues here and hyphen-\nated word.\n\nnew para"),
      "これは日本語の文章です。\n次の段落line one continues here and hyphenated word.\n\nnew para")
check("joinLines CRLF", Transforms.joinLines("abc  \r\ndef\r\n\r\n\r\nxyz"), "abc def\n\nxyz")
check("toHalf", Transforms.toHalf("ＡＢＣ１２３　（ｘ）「日本」、。"), "ABC123 (x)「日本」、。")
check("kanaFull", Transforms.kanaFull("ｶﾞｷﾞｸﾞﾃｽﾄ abc ｱ"), "ガギグテスト abc ア")
check("trimSpaces", Transforms.trimSpaces("  a  \n\n\n\nb\u{3000}\n"), "a\n\nb")
check("csv", Transforms.toCSV("名前\t値\n\"a,b\"\t\"x\ny\"\n"), "名前,値\n\"a,b\",\"x\ny\"")
check("tsv", Transforms.toTSV("a,b\n\"1,5\",2"), "a\tb\n1,5\t2")
check("markdown", Transforms.toMarkdown("名前\t値 (mm)\nA|B\t1,234.5\nC\t-2e3"),
      "| 名前 | 値 (mm) |\n| --- | ---: |\n| A\\|B | 1,234.5 |\n| C | -2e3 |")
check("latex", Transforms.toLatex("a_b\t50%\n$x$\t1"),
      "\\begin{tabular}{lr}\n  \\hline\n  a\\_b & 50\\% \\\\\n  \\hline\n  \\$x\\$ & 1 \\\\\n  \\hline\n\\end{tabular}")
check("ragged rows", Transforms.toCSV("a\tb\tc\n1"), "a,b,c\n1,,")
for t in TextTransform.allCases { _ = t.apply(""); _ = t.apply("x") }  // 空でも落ちない


// MARK: - 暗号（iPhone 用 Web アプリと共通）
// 固定の値は clip-send/test/crypto-vector.mjs --swift が出力したもの（Web 版が作った暗号文）
let vecSecret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
let vecRoom = "yPw6bue3EVsxQB8TPGB-HA"
let vecMeta = #"{"k":"text","name":"","mime":"text/plain"}"#
let vecBody = "こんにちは, clip!"
let vecNonceHex = "000102030405060708090a0b"
let vecSealedHex = "01000102030405060708090a0b7715f50bcb4cd950d51bc4cdda6bd8f671145bf5a1efd5a27a1f2991c52b183940310f6d6bdf7fbbd1ead04782c961d91c8e7215a0805ac880c782d5e23ab38677bdb2f863b8c33e4f067c0818ed497221987d2f"

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func fromHex(_ s: String) -> Data {
    var out = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

do {
    let keys = try SyncCrypto.derive(secret: vecSecret)
    check("sync: 部屋ID", keys.room, vecRoom)
    let nonce = try AES.GCM.Nonce(data: fromHex(vecNonceHex))
    let sealed = try SyncCrypto.seal(keys, meta: Data(vecMeta.utf8), body: Data(vecBody.utf8), nonce: nonce)
    check("sync: 暗号文が Web 版と一致", hex(sealed), vecSealedHex)

    let opened = try SyncCrypto.open(keys, fromHex(vecSealedHex))
    check("sync: Web 版の暗号文を復号（本体）", String(data: opened.body, encoding: .utf8) ?? "", vecBody)
    check("sync: Web 版の暗号文を復号（種類）", opened.meta["k"] as? String ?? "", "text")

    // 自分で作ったものを自分で開ける（毎回違う nonce）
    let a = try SyncCrypto.seal(keys, kind: "image", name: "a.jpg", mime: "image/jpeg", body: Data([1, 2, 3, 255]))
    let b = try SyncCrypto.seal(keys, kind: "image", name: "a.jpg", mime: "image/jpeg", body: Data([1, 2, 3, 255]))
    check("sync: nonce は毎回違う", String(a == b), "false")
    let back = try SyncCrypto.open(keys, a)
    check("sync: 往復（本体）", hex(back.body), "010203ff")
    check("sync: 往復（名前）", back.meta["name"] as? String ?? "", "a.jpg")

    // 改ざん・別の鍵は拒否
    var bad = fromHex(vecSealedHex)
    bad[bad.count - 1] ^= 1
    var rejected = false
    do { _ = try SyncCrypto.open(keys, bad) } catch { rejected = true }
    check("sync: 改ざんは復号できない", String(rejected), "true")

    let other = try SyncCrypto.derive(secret: SyncCrypto.newSecret())
    rejected = false
    do { _ = try SyncCrypto.open(other, fromHex(vecSealedHex)) } catch { rejected = true }
    check("sync: 別の鍵では復号できない", String(rejected), "true")
    check("sync: 別の秘密は別の部屋ID", String(other.room == keys.room), "false")
    check("sync: 部屋IDは22文字", String(keys.room.count), "22")

    rejected = false
    do { _ = try SyncCrypto.derive(secret: "short") } catch { rejected = true }
    check("sync: 短い秘密は拒否", String(rejected), "true")
} catch {
    failed += 1
    print("FAIL sync: 予期しないエラー \(error)")
}

// MARK: - 高速モード（ショートカットから直接送り、サーバーが Mac の公開鍵で暗号化する）
// 固定の値は clip-relay/test/quick.mjs --swift が出力したもの（サーバーのコードが作った暗号文）
let quickPrivateHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
let quickPublicHex = "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354"
let quickBody = "ショートカット, quick!"
let quickSealedHex = "02045142f48a7c80caf47544a428fc57d272a6c678ad5e93ffcba36666a99639e51dd1bdb6fb598144567a2657e8ff3619fbaa0cd2a040c19ab22af910c705a757ba32333435363738393a3b3c3dafe2cdb9a9657b9efb6f60e5d0be037c5a235c218b07897ef820877373b1c402aa78749039c8e032ffd4057a61316f031e1579d2b31fc6b42a4c544403be5582d43be73117746ed28afef4306d031f17d75de7fc475332a76b2fdb"

do {
    let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: fromHex(quickPrivateHex))
    check("quick: 公開鍵（x963）の形式が一致", hex(priv.publicKey.x963Representation), quickPublicHex)
    let opened = try SyncCrypto.openQuick(priv, fromHex(quickSealedHex))
    check("quick: サーバーが作った暗号文を復号（本体）", String(data: opened.body, encoding: .utf8) ?? "", quickBody)
    check("quick: 復号（種類）", opened.meta["k"] as? String ?? "", "text")

    var bad = fromHex(quickSealedHex)
    bad[bad.count - 1] ^= 1
    var rejected = false
    do { _ = try SyncCrypto.openQuick(priv, bad) } catch { rejected = true }
    check("quick: 改ざんは復号できない", String(rejected), "true")

    rejected = false
    do { _ = try SyncCrypto.openQuick(P256.KeyAgreement.PrivateKey(), fromHex(quickSealedHex)) } catch { rejected = true }
    check("quick: 別の Mac の鍵では復号できない", String(rejected), "true")

    rejected = false
    do { _ = try SyncCrypto.openQuick(priv, Data([2, 1, 2, 3])) } catch { rejected = true }
    check("quick: 短すぎるデータは拒否", String(rejected), "true")
} catch {
    failed += 1
    print("FAIL quick: 予期しないエラー \(error)")
}

// StoragePolicy（履歴の件数・容量の上限）
do {
    typealias E = StoragePolicy.Entry
    let MB: Int64 = 1024 * 1024
    func ids(_ s: Set<Int>) -> String { s.sorted().map(String.init).joined(separator: ",") }
    // 件数だけ: ピン留め以外 2 件まで → 一番古い（3 番）を消す。ピン留め（1 番）は数えない
    check("storage: 件数", ids(StoragePolicy.toRemove([E(pinned: false, bytes: 0), E(pinned: true, bytes: 0),
                                                     E(pinned: false, bytes: 0), E(pinned: false, bytes: 0)],
                                                    maxItems: 2, maxBytes: nil)), "3")
    // 容量: 10MB 上限で 4+4+4+4 → 古い方から 2 件消して 8MB
    check("storage: 容量", ids(StoragePolicy.toRemove(Array(repeating: E(pinned: false, bytes: 4 * MB), count: 4),
                                                    maxItems: 500, maxBytes: 10 * MB)), "2,3")
    // ピン留めは容量を超えていても消さない（合計には入る）
    check("storage: ピン留めは残す", ids(StoragePolicy.toRemove([E(pinned: false, bytes: 1 * MB), E(pinned: false, bytes: 1 * MB),
                                                         E(pinned: true, bytes: 9 * MB)],
                                                        maxItems: 500, maxBytes: 10 * MB)), "1")
    // テキストだけ（0 バイト）は容量のために消さない。いちばん新しい 1 件も消さない
    check("storage: 新しい1件とテキストは残す", ids(StoragePolicy.toRemove([E(pinned: false, bytes: 20 * MB), E(pinned: false, bytes: 0)],
                                                           maxItems: 500, maxBytes: 10 * MB)), "")
    check("storage: 上限の表示", StoragePolicy.label(mb: 1024) + "/" + StoragePolicy.label(mb: 500) + "/" + StoragePolicy.label(mb: 0),
          "1 GB/500 MB/上限なし")
}

// MARK: - 大きい順（履歴の一覧）
check("大きい順: 並び", StoragePolicy.sizeOrder([5, 0, 9, 5, 0]).map(String.init).joined(separator: ","), "2,0,3,1,4")
check("大きい順: 空", String(StoragePolicy.sizeOrder([]).count), "0")
check("大きい順: すべて同じ", StoragePolicy.sizeOrder([3, 3, 3]).map(String.init).joined(separator: ","), "0,1,2")

// MARK: - 古い画像を軽くする
let nowDate = Date()
check("軽くする: 7日たった", String(StoragePolicy.isOldEnough(nowDate.addingTimeInterval(-7 * 86400), now: nowDate, days: 7)), "true")
check("軽くする: 6日はまだ", String(StoragePolicy.isOldEnough(nowDate.addingTimeInterval(-6 * 86400), now: nowDate, days: 7)), "false")
check("軽くする: 「しない」は、いつまでも古くない", String(StoragePolicy.isOldEnough(nowDate.addingTimeInterval(-9999 * 86400), now: nowDate, days: 0)), "false")
check("軽くする: 3割以上軽くなる", String(StoragePolicy.worthwhile(original: 1000, compressed: 700, minSaving: 0.3)), "true")
check("軽くする: 3割未満は採用しない", String(StoragePolicy.worthwhile(original: 1000, compressed: 701, minSaving: 0.3)), "false")
check("軽くする: 大きさ 0 は採用しない", String(StoragePolicy.worthwhile(original: 0, compressed: 0, minSaving: 0.3)), "false")

/// テスト用の画像。写真のようになめらかで、少しだけ細かいむらがある。alpha が 255 未満の四角を入れることもできる
func testPNG(width: Int, height: Int, transparentBlock: Bool = false, flat: Bool = false) -> Data {
    var seed: UInt32 = 12345
    func noise() -> Int { seed = seed &* 1664525 &+ 1013904223; return Int((seed >> 24) % 9) - 4 }
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let base = (x * 255 / width, y * 255 / height, (x + y) * 255 / (width + height))
            func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
            p[i] = flat ? 200 : clamp(base.0 + noise())
            p[i + 1] = flat ? 120 : clamp(base.1 + noise())
            p[i + 2] = flat ? 60 : clamp(base.2 + noise())
            let transparent = transparentBlock && x < width / 4 && y < height / 4
            p[i + 3] = transparent ? 128 : 255
            if transparent { p[i] = p[i] / 2; p[i + 1] = p[i + 1] / 2; p[i + 2] = p[i + 2] / 2 }  // premultiplied
        }
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let photoPNG = testPNG(width: 1600, height: 1000)
if let jpg = ImageRecompressor.jpegIfWorthwhile(photoPNG) {
    check("軽くする: JPEG になる", String(jpg.starts(with: [0xFF, 0xD8])), "true")
    check("軽くする: 3割以上小さい", String(Double(jpg.count) <= Double(photoPNG.count) * 0.7), "true")
    let rep = NSBitmapImageRep(data: jpg)
    check("軽くする: 大きさ（画素数）は同じ", "\(rep?.pixelsWide ?? 0)x\(rep?.pixelsHigh ?? 0)", "1600x1000")
    print("  （参考）PNG \(photoPNG.count / 1024) KB → JPEG \(jpg.count / 1024) KB")
} else {
    failed += 1
    print("FAIL 軽くする: 写真のような画像が JPEG にならなかった")
}
check("軽くする: 透明な部分がある画像は変えない", String(ImageRecompressor.jpegIfWorthwhile(testPNG(width: 800, height: 600, transparentBlock: true)) == nil), "true")
check("軽くする: 小さくならない単色の図は変えない", String(ImageRecompressor.jpegIfWorthwhile(testPNG(width: 64, height: 64, flat: true)) == nil), "true")
check("軽くする: PNG ではないデータは変えない", String(ImageRecompressor.jpegIfWorthwhile(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])) == nil), "true")
check("軽くする: 壊れた PNG は変えない", String(ImageRecompressor.jpegIfWorthwhile(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])) == nil), "true")

// URL スキーム（DeepLink.swift）
func link(_ s: String) -> String {
    guard let url = URL(string: s) else { return "URLにならない" }
    switch DeepLink.parse(url) {
    case .none: return "無視"
    case .open(let kind)?: return "open:" + (kind ?? "すべて")
    }
}
check("URL: open", link("clipshelf://open"), "open:すべて")
check("URL: open/（末尾の /）", link("clipshelf://open/"), "open:すべて")
for kind in DeepLink.kinds {
    check("URL: kind=\(kind)", link("clipshelf://open?kind=\(kind)"), "open:\(kind)")
}
check("URL: 大文字でも読める", link("CLIPSHELF://OPEN?kind=Image"), "open:image")
check("URL: 前後の空白は無視", link("clipshelf://open?kind=%20text%20"), "open:text")
check("URL: 知らない kind は絞り込みなしで開く", link("clipshelf://open?kind=movie"), "open:すべて")
check("URL: 空の kind は絞り込みなしで開く", link("clipshelf://open?kind="), "open:すべて")
check("URL: 値のない kind は絞り込みなしで開く", link("clipshelf://open?kind"), "open:すべて")
check("URL: kind が複数なら最初のもの", link("clipshelf://open?kind=link&kind=text"), "open:link")
check("URL: 別の項目は無視して開く", link("clipshelf://open?foo=1&kind=file"), "open:file")
check("URL: clipshelf:open の形", link("clipshelf:open?kind=video"), "open:video")
check("URL: clipshelf:///open の形", link("clipshelf:///open?kind=image"), "open:image")
check("URL: 知らないコマンドは何もしない", link("clipshelf://close"), "無視")
check("URL: open に似た名前は何もしない", link("clipshelf://openx"), "無視")
check("URL: コマンドなしは何もしない", link("clipshelf://"), "無視")
check("URL: 別のスキームは何もしない", link("https://open/?kind=image"), "無視")
check("URL: kind の候補は ClipCategory と同じ並び", DeepLink.kinds.joined(separator: ","), "text,link,image,video,file")

if failed > 0 { print("\(failed) 件失敗"); exit(1) }
print("すべて成功")
