// Geometry.swift / Presets.swift の確認（GitHub Actions で実行:
//   swiftc Sources/Geometry.swift Sources/Presets.swift Tests/main.swift -o /tmp/geometry-check && /tmp/geometry-check）
import CoreGraphics
import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name) \(detail())")
    }
}

// 27 インチ 4K を「2560×1440 相当」で使い、メニューバー 25pt・Dock なしの場合の使える範囲（左上原点）
let area = CGRect(x: 0, y: 25, width: 2560, height: 1415)

// 座標変換は行って戻ると元どおり
let r = CGRect(x: 100, y: 200, width: 300, height: 400)
check("flip 往復", Geometry.flip(Geometry.flip(r, primaryHeight: 1440), primaryHeight: 1440) == r)
check("flip 値", Geometry.flip(CGRect(x: 0, y: 0, width: 2560, height: 1415), primaryHeight: 1440)
      == CGRect(x: 0, y: 25, width: 2560, height: 1415))

// 左半分: 端は 8、真ん中は 4（隣と合わせて 8）
let lh = Geometry.frame(for: NamedZone.leftHalf.zone, in: area, gap: 8)
check("左半分", lh == CGRect(x: 8, y: 33, width: 1268, height: 1399), "\(lh)")

// 3 列のすき間がどこでも 8 になる
let l3 = Geometry.frame(for: NamedZone.leftThird.zone, in: area, gap: 8)
let c3 = Geometry.frame(for: NamedZone.centerThird.zone, in: area, gap: 8)
let r3 = Geometry.frame(for: NamedZone.rightThird.zone, in: area, gap: 8)
check("3列 左端", l3.minX == 8, "\(l3)")
check("3列 すき間1", c3.minX - l3.maxX == 8, "\(l3) \(c3)")
check("3列 すき間2", r3.minX - c3.maxX == 8, "\(c3) \(r3)")
check("3列 右端", area.maxX - r3.maxX == 8, "\(r3)")

// 6 分割の上下のすき間
let rt = Geometry.frame(for: NamedZone.rightThirdTop.zone, in: area, gap: 8)
let rb = Geometry.frame(for: NamedZone.rightThirdBottom.zone, in: area, gap: 8)
check("上下のすき間", rb.minY - rt.maxY == 8, "\(rt) \(rb)")
check("下端", area.maxY - rb.maxY == 8, "\(rb)")

// すき間 0 なら画面いっぱい
check("最大化 gap0", Geometry.frame(for: NamedZone.maximize.zone, in: area, gap: 0) == area)

// 枠 → 割合 → 枠 で元に戻る（今の配置の保存・別の画面への移動）
for z in NamedZone.allCases {
    let f = Geometry.frame(for: z.zone, in: area, gap: 8)
    let back = Geometry.zone(for: f, in: area)
    check("往復 \(z.rawValue)", back.isClose(to: z.zone), "\(back) vs \(z.zone)")
    check("名前 \(z.rawValue)", NamedZone.named(back) == z || (z == .center), "\(String(describing: NamedZone.named(back)))")
}

// 別の画面（MacBook 内蔵 1512×945 相当）へ移すと同じ割合で入る
let small = CGRect(x: -1512, y: 500, width: 1512, height: 920)
let moved = Geometry.frame(for: Geometry.zone(for: l3, in: area), in: small, gap: 8)
check("別の画面へ", moved == Geometry.frame(for: NamedZone.leftThird.zone, in: small, gap: 8), "\(moved)")

// 同じキーを続けて押すと 1/2 → 2/3 → 1/3 → 1/2 …
let cycle = [NamedZone.leftHalf, .leftTwoThirds, .leftThird].map { Geometry.frame(for: $0.zone, in: area, gap: 8) }
check("切り替え 最初", Geometry.nextIndex(current: CGRect(x: 300, y: 300, width: 500, height: 500), candidates: cycle) == 0)
check("切り替え 1/2→2/3", Geometry.nextIndex(current: cycle[0], candidates: cycle) == 1)
check("切り替え 1/3→1/2", Geometry.nextIndex(current: cycle[2], candidates: cycle) == 0)
let almost = cycle[1].insetBy(dx: 3, dy: 2)  // アプリの都合で少しずれても同じとみなす
check("切り替え 少しずれ", Geometry.nextIndex(current: almost, candidates: cycle) == 2)

// どの画面にあるか
let screens = [small, area]
check("画面 重なり", Geometry.bestScreenIndex(for: CGRect(x: 100, y: 100, width: 400, height: 400), screens: screens) == 1)
check("画面 またぐ", Geometry.bestScreenIndex(for: CGRect(x: -1000, y: 600, width: 1100, height: 300), screens: screens) == 0)
check("画面 外", Geometry.bestScreenIndex(for: CGRect(x: 5000, y: 100, width: 10, height: 10), screens: screens) == 1)

// マス目のドラッグ（12×6）
let g = Geometry.gridZone(c0: 7, r0: 5, c1: 4, r1: 3, cols: 12, rows: 6)
check("マス目", g.isClose(to: Zone(4.0 / 12, 0.5, 4.0 / 12, 0.5)), "\(g)")
let gAll = Geometry.gridZone(c0: 0, r0: 0, c1: 11, r1: 5, cols: 12, rows: 6)
check("マス目 全部", gAll.isClose(to: NamedZone.maximize.zone))
let cell = Geometry.cell(at: CGPoint(x: 999, y: -5), size: CGSize(width: 480, height: 270), cols: 12, rows: 6)
check("マス 範囲外", cell.c == 11 && cell.r == 0)

// 列の中で上下に分ける
let vh = Geometry.verticalHalf(of: NamedZone.rightThird.zone, top: true)
check("列の上半分", vh.isClose(to: NamedZone.rightThirdTop.zone), "\(vh)")
check("もう一度で横幅いっぱい", Geometry.verticalHalf(of: vh, top: true).isClose(to: NamedZone.topHalf.zone))
check("列の下半分", Geometry.verticalHalf(of: NamedZone.leftThirdTop.zone, top: false).isClose(to: NamedZone.leftThirdBottom.zone))

// AI と並べる
let p = AIPairing.zones(aiOnLeft: true, fraction: 1.0 / 3.0)
check("AI 左", p.ai.isClose(to: NamedZone.leftThird.zone) && p.work.isClose(to: NamedZone.rightTwoThirds.zone))
let q = AIPairing.zones(aiOnLeft: false, fraction: 0.25)
check("AI 右", q.ai.isClose(to: NamedZone.rightQuarter.zone) && q.work.isClose(to: Zone(0, 0, 0.75, 1)))

// プリセットの保存と読み込み
let defaults = Preset.defaults
let data = try! JSONEncoder().encode(defaults)
let decoded = try! JSONDecoder().decode([Preset].self, from: data)
check("プリセット 往復", decoded == defaults)
check("プリセット 範囲", defaults.allSatisfy { $0.slots.allSatisfy { s in
    s.zone.x >= 0 && s.zone.y >= 0 && s.zone.x + s.zone.w <= 1.0001 && s.zone.y + s.zone.h <= 1.0001 } })
// 古い（項目の少ない）保存データも読める
let old = #"[{"name":"古い","slots":[{"bundleID":"com.apple.Safari","zone":{"x":0,"y":0,"w":0.5,"h":1}}]}]"#
let oldDecoded = try? JSONDecoder().decode([Preset].self, from: Data(old.utf8))
check("古いデータ", oldDecoded?.first?.slots.first?.appName == "com.apple.Safari"
      && oldDecoded?.first?.screen == .largest && oldDecoded?.first?.slots.first?.launch == false)

print(failed == 0 ? "\nすべて成功" : "\n\(failed) 件失敗")
exit(failed == 0 ? 0 : 1)
