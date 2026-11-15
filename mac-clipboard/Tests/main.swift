// Transforms.swift の確認（GitHub Actions で実行: swiftc Sources/Transforms.swift Tests/main.swift）
// 期待値は Web 版 clipboard/index.html の同じ変換の出力
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

if failed > 0 { print("\(failed) 件失敗"); exit(1) }
print("すべて成功")
