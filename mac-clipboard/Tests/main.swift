// Transforms.swift の確認（GitHub Actions で実行: swiftc Sources/Transforms.swift Tests/main.swift）
// 期待値は Web 版 clipboard/index.html の同じ変換の出力
import Foundation

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

if failed > 0 { print("\(failed) 件失敗"); exit(1) }
print("すべて成功")
