// 計算部分の確認（GitHub Actions で実行:
//   swiftc Sources/Geometry.swift Sources/Presets.swift Sources/EdgeLogic.swift Sources/KeyCombo.swift Sources/Layouts.swift Tests/main.swift -o /tmp/geometry-check && /tmp/geometry-check）
import Carbon.HIToolbox
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

// 境目でカーソルを止める（Dell 2560×1440 の下に MacBook 1470×956、中央寄せ）
let dell = CGRect(x: 0, y: 0, width: 2560, height: 1440)
let mac = CGRect(x: 545, y: 1440, width: 1470, height: 956)
let both = [dell, mac]
var eb = EdgeBarrier()
eb.hold = 0.4
let t0 = Date(timeIntervalSince1970: 1000)
let s1 = eb.filter(from: CGPoint(x: 1000, y: 1430), to: CGPoint(x: 1000, y: 1450), screens: both, now: t0)
check("境目 止める", s1 == CGPoint(x: 1000, y: 1439), "\(String(describing: s1))")
let s2 = eb.filter(from: CGPoint(x: 1000, y: 1439), to: CGPoint(x: 1000, y: 1446), screens: both, now: t0.addingTimeInterval(0.2))
check("境目 押している間は止める", s2 == CGPoint(x: 1000, y: 1439))
let s3 = eb.filter(from: CGPoint(x: 1000, y: 1439), to: CGPoint(x: 1000, y: 1446), screens: both, now: t0.addingTimeInterval(0.45))
check("境目 押し続けたら通す", s3 == nil)
// 通り抜けたあと、戻ってきてまた押すと、もう一度止まる（少し時間を空ける）
let s4 = eb.filter(from: CGPoint(x: 1000, y: 1430), to: CGPoint(x: 1000, y: 1445), screens: both, now: t0.addingTimeInterval(2))
check("境目 もう一度止まる", s4 == CGPoint(x: 1000, y: 1439))
// 押すのをやめて時間がたつと、数え直し
var eb2 = EdgeBarrier()
_ = eb2.filter(from: CGPoint(x: 1000, y: 1430), to: CGPoint(x: 1000, y: 1445), screens: both, now: t0)
_ = eb2.filter(from: CGPoint(x: 1000, y: 1439), to: CGPoint(x: 1010, y: 1435), screens: both, now: t0.addingTimeInterval(0.3))
let s5 = eb2.filter(from: CGPoint(x: 1010, y: 1435), to: CGPoint(x: 1010, y: 1445), screens: both, now: t0.addingTimeInterval(1.2))
check("境目 数え直し", s5 == CGPoint(x: 1010, y: 1439))
// 下に画面がない所（MacBook の横）は、macOS が止めるので何もしない
var eb3 = EdgeBarrier()
check("境目 下に画面なし", eb3.filter(from: CGPoint(x: 100, y: 1430), to: CGPoint(x: 100, y: 1445), screens: both, now: t0) == nil)
// 上へ戻るとき（MacBook → Dell）も、MacBook の上の端（メニューバー）で止める
check("境目 上へも止める（メニューバー）", eb3.filter(from: CGPoint(x: 1000, y: 1445), to: CGPoint(x: 1000, y: 1430), screens: both, now: t0)
      == CGPoint(x: 1000, y: 1440))
// 左右の境目は、上下左右すべての設定のときだけ
let side = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
var eb4 = EdgeBarrier()
check("境目 左右は止めない", eb4.filter(from: CGPoint(x: 990, y: 100), to: CGPoint(x: 1010, y: 100), screens: side, now: t0) == nil)
eb4.allSides = true
check("境目 すべてなら左右も", eb4.filter(from: CGPoint(x: 990, y: 100), to: CGPoint(x: 1010, y: 100), screens: side, now: t0)
      == CGPoint(x: 999, y: 100))
// 重なった画面（仮想画面・ミラー）の中の動きは、境目とみなさない（画面の途中で止まらない）
var eb5 = EdgeBarrier()
let virtual = CGRect(x: 0, y: 700, width: 1200, height: 900)  // Dell の下の方に重なっている
check("境目 重なった画面の中", eb5.filter(from: CGPoint(x: 600, y: 750), to: CGPoint(x: 600, y: 650), screens: [virtual, dell, mac], now: t0) == nil)
// 同じ画面の中の動きは何もしない
eb3.allSides = true
check("境目 画面の中", eb3.filter(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 20), screens: both, now: t0) == nil)

// キーの表示
check("キー表示 矢印", KeyCombo(kVK_LeftArrow, KeyCombo.co).label == "⌃⌥←")
check("キー表示 文字", KeyCombo(kVK_ANSI_D, KeyCombo.co | cmdKey | shiftKey, "D").label == "⌃⌥⇧⌘D")
check("メニュー用 文字", KeyCombo(kVK_ANSI_D, KeyCombo.co, "D").menuKey == "d")
check("メニュー用 リターン", KeyCombo(kVK_Return, KeyCombo.co).menuKey == "\r")
check("F キー", KeyCombo(kVK_F5, 0).label == "F5" && KeyCombo(kVK_F5, 0).isFunctionKey)
check("修飾キーの判定", !KeyCombo(kVK_ANSI_A, shiftKey, "A").hasModifier && KeyCombo(kVK_ANSI_A, optionKey, "A").hasModifier)
let kc = KeyCombo(kVK_ANSI_W, KeyCombo.co, "W")
check("キー 保存と読み込み", (try? JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(kc))) == kc)

// 画面の端の余白を 0、ウィンドウ間を 6 にしたとき
let e0 = Geometry.frame(for: NamedZone.leftThird.zone, in: area, gap: 6, edge: 0)
check("端の余白 0 左上", e0.minX == 0 && e0.minY == area.minY, "\(e0)")
check("端の余白 0 下", e0.maxY == area.maxY, "\(e0)")
let e1 = Geometry.frame(for: NamedZone.centerThird.zone, in: area, gap: 6, edge: 0)
check("端 0 でも間は 6", e1.minX - e0.maxX == 6, "\(e0) \(e1)")
let e2 = Geometry.frame(for: NamedZone.rightThird.zone, in: area, gap: 6, edge: 0)
check("端の余白 0 右", e2.maxX == area.maxX, "\(e2)")
check("全体 端 0", Geometry.frame(for: NamedZone.maximize.zone, in: area, gap: 6, edge: 0) == area)
check("端 0 の往復", Geometry.zone(for: e1, in: area).isClose(to: NamedZone.centerThird.zone))

// 配置案のひな形: 画面からはみ出さない・重ならない・名前が重ならない
for t in LayoutTemplate.builtIn {
    check("配置案 範囲 \(t.id)", t.zones.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.w <= 1.0001 && $0.y + $0.h <= 1.0001 })
    check("配置案 重なりなし \(t.id)", !t.hasOverlap)
}
check("配置案 ID", Set(LayoutTemplate.builtIn.map(\.id)).count == LayoutTemplate.builtIn.count)
check("配置案 フルスクリーン", LayoutTemplate.builtIn.first { $0.id == "full" }?.isFullScreen(0) == true
      && LayoutTemplate.builtIn.first { $0.id == "thirds" }?.isFullScreen(0) == false)
check("重なりの判定", LayoutTemplate(id: "x", name: "x", zones: [NamedZone.leftHalf.zone, NamedZone.leftThird.zone]).hasOverlap)

// フルスクリーン指定の保存と、古いデータ（指定なし）の読み込み
let fsSlot = Slot(bundleID: "com.apple.Safari", appName: "Safari", zone: NamedZone.maximize.zone, fullScreen: true)
let fsBack = try? JSONDecoder().decode(Slot.self, from: JSONEncoder().encode(fsSlot))
check("フルスクリーン指定 保存", fsBack?.fullScreen == true)
check("フルスクリーン指定 古いデータ", oldDecoded?.first?.slots.first?.fullScreen == false)
let builtinPreset = try? JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(Preset(name: "Mac", slots: [], screen: .builtin)))
check("MacBook 本体の画面 保存", builtinPreset?.screen == .builtin)

// アプリの最小幅に合わせて並び直す（MacBook 本体で 3 列にしたら、真ん中のアプリが 1/3 まで狭くならなかった）
do {
    let t = 1.0 / 3
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
    let three = [Zone(0, 0, t, 1), Zone(t, 0, t, 1), Zone(2 * t, 0, t, 1)]
    // 真ん中が 0.45 必要 → 左右が 0.275 ずつに細くなり、重ならず画面にぴったり収まる
    let f = Fit.refit(zones: three, minW: [0, 0.45, 0], minH: [0, 0, 0])
    check("最小幅 真ん中", near(f[1].w, 0.45), "\(f)")
    check("最小幅 左右を細く", near(f[0].w, 0.275) && near(f[2].w, 0.275), "\(f)")
    check("最小幅 すき間なく並ぶ", near(f[0].x, 0) && near(f[1].x, f[0].w) && near(f[2].x + f[2].w, 1), "\(f)")
    // 左も 0.3 必要 → 左は 0.3 より細くならず、3 つで画面にぴったり
    let g = Fit.refit(zones: three, minW: [0.3, 0.45, 0], minH: [0, 0, 0])
    check("最小幅 2 つ", g[0].w >= 0.3 - 1e-6 && near(g[1].w, 0.45) && near(g[2].x + g[2].w, 1)
          && near(g[1].x, g[0].w) && near(g[2].x, g[1].x + g[1].w), "\(g)")
    // 足りていれば変えない
    check("最小幅 変えない", Fit.refit(zones: three, minW: [0, 0, 0], minH: [0, 0, 0]) == three)
    // 6 分割（左は上下いっぱい・中央と右は上下）でも、右上が広くなれば中央の列が細くなる
    let six = [Zone(0, 0, t, 1), Zone(t, 0, t, 0.5), Zone(2 * t, 0, t, 0.5), Zone(t, 0.5, t, 0.5), Zone(2 * t, 0.5, t, 0.5)]
    let s6 = Fit.refit(zones: six, minW: [0, 0, 0.4, 0, 0], minH: [0, 0, 0, 0, 0])
    check("最小幅 6分割", near(s6[2].w, 0.4) && near(s6[4].w, 0.4) && near(s6[2].x + s6[2].w, 1)
          && s6[1].x + s6[1].w <= s6[2].x + 1e-6, "\(s6)")
    // 収まらないときも、画面からははみ出さない
    let n = Fit.refit(zones: three, minW: [0.5, 0.5, 0.5], minH: [0, 0, 0])
    check("最小幅 収まらない", near(n[2].x + n[2].w, 1), "\(n)")
}

// 配置パネルの警告・おすすめ
do {
    let t = 1.0 / 3
    let three = [Zone(0, 0, t, 1), Zone(t, 0, t, 1), Zone(2 * t, 0, t, 1)]
    check("警告 収まる", Fit.check(zones: three, minW: [0, 0, 0], minH: [0, 0, 0]) == [.ok, .ok, .ok])
    check("警告 隣を細く", Fit.check(zones: three, minW: [0, 0.45, 0], minH: [0, 0, 0]) == [.ok, .adjusted, .ok])
    let over = Fit.check(zones: three, minW: [0.5, 0.5, 0.5], minH: [0, 0, 0])
    check("警告 重なる", over.contains(.overlap), "\(over)")
    // MacBook（1512pt）の 1/3 の枠（約 500pt）に、最小 820pt のアプリ
    let fr = Fit.fraction(minPt: 820, zoneSize: t, frameSize: 500, areaSize: 1512)
    check("最小幅の割合", abs(fr - (t + 320.0 / 1512)) < 1e-9, "\(fr)")
    check("最小幅の割合 入る", Fit.fraction(minPt: 400, zoneSize: t, frameSize: 500, areaSize: 1512) == 0)
    let ch: [(name: String, width: Double)] = [("1/4", 378), ("1/3", 504), ("1/2", 756), ("2/3", 1008), ("全体", 1512)]
    check("おすすめ 1/2", Fit.recommend(minWidth: 600, choices: ch) == "1/2")
    check("おすすめ 1/4", Fit.recommend(minWidth: 300, choices: ch) == "1/4")
    check("おすすめ なし", Fit.recommend(minWidth: 2000, choices: ch) == nil)
}

// ほかのアプリを隠すか（4K が 0 番、MacBook 本体が 1 番）
do {
    let screens = [CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: 524, y: 1440, width: 1512, height: 982)]
    let on4K = CGRect(x: 100, y: 100, width: 800, height: 600)
    let onMac = CGRect(x: 600, y: 1500, width: 800, height: 600)
    check("隠す 4K だけ", HideRule.shouldHide(onScreen: [on4K], screens: screens, target: 0, offScreen: 0, minimized: 0))
    check("隠さない MacBook にもある", !HideRule.shouldHide(onScreen: [on4K, onMac], screens: screens, target: 0, offScreen: 0, minimized: 0))
    check("隠さない ほかのデスクトップにもある", !HideRule.shouldHide(onScreen: [on4K], screens: screens, target: 0, offScreen: 1, minimized: 0))
    check("隠す しまってあるだけ", HideRule.shouldHide(onScreen: [on4K], screens: screens, target: 0, offScreen: 1, minimized: 1))
    check("隠さない 見えていない", !HideRule.shouldHide(onScreen: [], screens: screens, target: 0, offScreen: 0, minimized: 0))
    // 古い保存データ（desktop がない）も読める
    let old = #"{"name":"古い","slots":[],"screen":"largest","hideOthers":true}"#.data(using: .utf8)!
    let p = try? JSONDecoder().decode(Preset.self, from: old)
    check("古いプリセット desktop", p?.desktop == 0 && p?.hideOthers == true)
}

// この画面を整理（手前 3 個を残す。4 番目の C はほかのデスクトップにもあるので隠さない）
check("整理 隠す", TidyRule.toHide(order: ["A", "B", "X", "C", "D", "E"], hideable: ["A", "B", "X", "D", "E"], keep: 3) == ["D", "E"])
check("整理 少ない", TidyRule.toHide(order: ["A", "B"], hideable: ["A", "B"], keep: 3).isEmpty)
check("整理 最低 1 個は残す", TidyRule.toHide(order: ["A", "B"], hideable: ["A", "B"], keep: 0) == ["B"])

check("結合 日本語", MenuTitle.isMergeAllWindows("すべてのウインドウを結合"))
check("結合 表記ゆれ", MenuTitle.isMergeAllWindows("すべてのウィンドウを結合"))
check("結合 英語", MenuTitle.isMergeAllWindows("Merge All Windows"))
check("結合 ちがう", !MenuTitle.isMergeAllWindows("ウインドウを閉じる"))

// 隣のウィンドウ（3 列 ＋ 右の列を上下）
do {
    let l = CGRect(x: 0, y: 0, width: 800, height: 1400)
    let c = CGRect(x: 800, y: 0, width: 800, height: 1400)
    let rt = CGRect(x: 1600, y: 0, width: 800, height: 700)
    let rb = CGRect(x: 1600, y: 700, width: 800, height: 700)
    let all = [l, c, rt, rb]
    check("隣 右", Neighbor.find(from: l, candidates: all, dir: .right) == 1)
    check("隣 左", Neighbor.find(from: c, candidates: all, dir: .left) == 0)
    check("隣 右上を優先せず近いほう", Neighbor.find(from: c, candidates: all, dir: .right) != nil)
    check("隣 下", Neighbor.find(from: rt, candidates: all, dir: .down) == 3)
    check("隣 上", Neighbor.find(from: rb, candidates: all, dir: .up) == 2)
    check("隣 なし", Neighbor.find(from: l, candidates: all, dir: .left) == nil)
    check("隣 同じ場所は除く", Neighbor.find(from: l, candidates: [l], dir: .right) == nil)
}

print(failed == 0 ? "\nすべて成功" : "\n\(failed) 件失敗")
exit(failed == 0 ? 0 : 1)
