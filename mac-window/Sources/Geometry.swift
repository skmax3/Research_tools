import CoreGraphics
import Foundation

/// 画面の中の「場所」。画面（メニューバーと Dock を除いた範囲）を 1×1 とした割合で表す。
/// 左上が (0, 0)、右下が (1, 1)。例: 左 1/3 = Zone(0, 0, 1/3, 1)
struct Zone: Codable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// ほぼ同じ場所か（保存した値の丸め誤差を許す）
    func isClose(to o: Zone, tol: Double = 0.01) -> Bool {
        abs(x - o.x) < tol && abs(y - o.y) < tol && abs(w - o.w) < tol && abs(h - o.h) < tol
    }
}

/// 名前の付いた場所（メニュー・ショートカット・プリセットで使う）
enum NamedZone: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case leftQuarter, centerHalf, rightQuarter
    case leftThirdTop, leftThirdBottom, centerThirdTop, centerThirdBottom, rightThirdTop, rightThirdBottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "左半分"
        case .rightHalf: return "右半分"
        case .topHalf: return "上半分"
        case .bottomHalf: return "下半分"
        case .leftThird: return "左 1/3"
        case .centerThird: return "中央 1/3"
        case .rightThird: return "右 1/3"
        case .leftTwoThirds: return "左 2/3"
        case .rightTwoThirds: return "右 2/3"
        case .leftQuarter: return "左 1/4"
        case .centerHalf: return "中央 1/2"
        case .rightQuarter: return "右 1/4"
        case .leftThirdTop: return "左 1/3 の上"
        case .leftThirdBottom: return "左 1/3 の下"
        case .centerThirdTop: return "中央 1/3 の上"
        case .centerThirdBottom: return "中央 1/3 の下"
        case .rightThirdTop: return "右 1/3 の上"
        case .rightThirdBottom: return "右 1/3 の下"
        case .topLeft: return "左上 1/4"
        case .topRight: return "右上 1/4"
        case .bottomLeft: return "左下 1/4"
        case .bottomRight: return "右下 1/4"
        case .maximize: return "全体（最大化）"
        case .center: return "中央に大きく"
        }
    }

    /// メニューでのまとまり
    var group: String {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return "半分"
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: return "3 列"
        case .leftQuarter, .centerHalf, .rightQuarter: return "1/4 ・ 1/2 ・ 1/4"
        case .leftThirdTop, .leftThirdBottom, .centerThirdTop, .centerThirdBottom, .rightThirdTop, .rightThirdBottom:
            return "6 分割（3 列 × 上下）"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "4 分割"
        case .maximize, .center: return "全体"
        }
    }

    static var groups: [String] {
        var seen: [String] = []
        for z in allCases where !seen.contains(z.group) { seen.append(z.group) }
        return seen
    }

    var zone: Zone {
        let t = 1.0 / 3.0
        switch self {
        case .leftHalf: return Zone(0, 0, 0.5, 1)
        case .rightHalf: return Zone(0.5, 0, 0.5, 1)
        case .topHalf: return Zone(0, 0, 1, 0.5)
        case .bottomHalf: return Zone(0, 0.5, 1, 0.5)
        case .leftThird: return Zone(0, 0, t, 1)
        case .centerThird: return Zone(t, 0, t, 1)
        case .rightThird: return Zone(2 * t, 0, t, 1)
        case .leftTwoThirds: return Zone(0, 0, 2 * t, 1)
        case .rightTwoThirds: return Zone(t, 0, 2 * t, 1)
        case .leftQuarter: return Zone(0, 0, 0.25, 1)
        case .centerHalf: return Zone(0.25, 0, 0.5, 1)
        case .rightQuarter: return Zone(0.75, 0, 0.25, 1)
        case .leftThirdTop: return Zone(0, 0, t, 0.5)
        case .leftThirdBottom: return Zone(0, 0.5, t, 0.5)
        case .centerThirdTop: return Zone(t, 0, t, 0.5)
        case .centerThirdBottom: return Zone(t, 0.5, t, 0.5)
        case .rightThirdTop: return Zone(2 * t, 0, t, 0.5)
        case .rightThirdBottom: return Zone(2 * t, 0.5, t, 0.5)
        case .topLeft: return Zone(0, 0, 0.5, 0.5)
        case .topRight: return Zone(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return Zone(0, 0.5, 0.5, 0.5)
        case .bottomRight: return Zone(0.5, 0.5, 0.5, 0.5)
        case .maximize: return Zone(0, 0, 1, 1)
        case .center: return Zone(0.2, 0.1, 0.6, 0.8)
        }
    }

    /// その場所に名前があれば返す
    static func named(_ z: Zone) -> NamedZone? {
        allCases.first { $0.zone.isClose(to: z) }
    }
}

/// 座標の計算。座標はすべて「左上原点・下向きが +y」（アクセシビリティ API と同じ）で扱う。
enum Geometry {
    /// macOS の画面座標（左下原点・上向き）⇄ アクセシビリティの座標（左上原点・下向き）。
    /// 同じ式で行きも帰りも変換できる。primaryHeight はメインの画面（メニューバーのある画面）の高さ
    static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 場所 z に置くときのウィンドウの枠。ウィンドウどうしの間は gap、画面の端との間は edge（省略すると gap）
    static func frame(for z: Zone, in area: CGRect, gap: CGFloat, edge: CGFloat? = nil) -> CGRect {
        let edge = edge ?? gap
        let e = 0.002
        let x0 = area.minX + CGFloat(z.x) * area.width
        let x1 = area.minX + CGFloat(z.x + z.w) * area.width
        let y0 = area.minY + CGFloat(z.y) * area.height
        let y1 = area.minY + CGFloat(z.y + z.h) * area.height
        let l = z.x <= e ? edge : gap / 2
        let r = z.x + z.w >= 1 - e ? edge : gap / 2
        let t = z.y <= e ? edge : gap / 2
        let b = z.y + z.h >= 1 - e ? edge : gap / 2
        // 端を別々に丸めて、隣のウィンドウとの間がずれないようにする
        let left = (x0 + l).rounded(), right = (x1 - r).rounded()
        let top = (y0 + t).rounded(), bottom = (y1 - b).rounded()
        return CGRect(x: left, y: top, width: max(40, right - left), height: max(40, bottom - top))
    }

    /// ウィンドウの枠 → 画面の中の割合（今の配置を保存するとき・別の画面へ移すとき）。
    /// 画面の端から snap 以内なら、端にぴったり付いているとみなす
    static func zone(for f: CGRect, in area: CGRect, snap: Double = 0.02) -> Zone {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        var x0 = clamp(Double((f.minX - area.minX) / area.width))
        var x1 = clamp(Double((f.maxX - area.minX) / area.width))
        var y0 = clamp(Double((f.minY - area.minY) / area.height))
        var y1 = clamp(Double((f.maxY - area.minY) / area.height))
        if x0 < snap { x0 = 0 }
        if y0 < snap { y0 = 0 }
        if x1 > 1 - snap { x1 = 1 }
        if y1 > 1 - snap { y1 = 1 }
        // よく使う区切り（1/4, 1/3, 1/2, 2/3, 3/4）の近く（約 1 マス分のすき間）なら、そこに合わせる
        let marks = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75]
        func toMark(_ v: Double) -> Double {
            for m in marks where abs(v - m) < 0.008 { return m }
            return round3(v)
        }
        x0 = toMark(x0); x1 = toMark(x1); y0 = toMark(y0); y1 = toMark(y1)
        return Zone(x0, y0, max(0.05, x1 - x0), max(0.05, y1 - y0))
    }

    /// 2 つの枠がほぼ同じか（アプリによっては指定どおりの大きさにならないので、少しの差は許す）
    static func approxEqual(_ a: CGRect, _ b: CGRect, tol: CGFloat = 12) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// 同じキーを続けて押したときに切り替える：今の枠が候補 i と同じなら i+1、どれとも違えば 0
    static func nextIndex(current: CGRect, candidates: [CGRect]) -> Int {
        guard !candidates.isEmpty else { return 0 }
        if let i = candidates.firstIndex(where: { approxEqual($0, current) }) {
            return (i + 1) % candidates.count
        }
        return 0
    }

    /// ウィンドウがいちばん多く重なっている画面の番号（重なりがなければ中心がいちばん近い画面）
    static func bestScreenIndex(for f: CGRect, screens: [CGRect]) -> Int {
        guard !screens.isEmpty else { return 0 }
        var best = 0
        var bestArea: CGFloat = -1
        for (i, s) in screens.enumerated() {
            let r = s.intersection(f)
            let a = r.isNull ? 0 : r.width * r.height
            if a > bestArea { best = i; bestArea = a }
        }
        if bestArea > 0 { return best }
        func dist(_ s: CGRect) -> CGFloat { hypot(s.midX - f.midX, s.midY - f.midY) }
        return screens.indices.min { dist(screens[$0]) < dist(screens[$1]) } ?? 0
    }

    /// 今の場所 z の「列」の中で上半分・下半分にする。すでにそうなっていれば横幅いっぱいの上半分・下半分
    static func verticalHalf(of z: Zone, top: Bool) -> Zone {
        let y = top ? 0.0 : 0.5
        let inColumn = Zone(z.x, y, z.w, 0.5)
        return z.isClose(to: inColumn) ? Zone(0, y, 1, 0.5) : inColumn
    }

    /// マス目（cols × rows）の (c0, r0) から (c1, r1) までをドラッグしたときの場所
    static func gridZone(c0: Int, r0: Int, c1: Int, r1: Int, cols: Int, rows: Int) -> Zone {
        let a = max(0, min(c0, c1)), b = min(cols - 1, max(c0, c1))
        let p = max(0, min(r0, r1)), q = min(rows - 1, max(r0, r1))
        return Zone(Double(a) / Double(cols), Double(p) / Double(rows),
                    Double(b - a + 1) / Double(cols), Double(q - p + 1) / Double(rows))
    }

    /// 図の上の点（0〜size）がどのマスか
    static func cell(at p: CGPoint, size: CGSize, cols: Int, rows: Int) -> (c: Int, r: Int) {
        let c = Int((p.x / max(size.width, 1)) * CGFloat(cols))
        let r = Int((p.y / max(size.height, 1)) * CGFloat(rows))
        return (min(max(c, 0), cols - 1), min(max(r, 0), rows - 1))
    }
}

// MARK: - アプリの最小サイズに合わせて並びを直す

/// アプリによっては「これ以上狭くできない」最小の幅があり、MacBook 本体のような小さな画面で 3 列にすると、
/// 1/3 より広いまま残って隣のウィンドウに重なる。そのときは、狭くできるほかの列を細くして、全体を画面に収める。
enum Fit {
    /// 1 方向（横なら x と幅）の並び直し。
    /// - starts / sizes: 各ウィンドウの場所（割合）
    /// - mins: 各ウィンドウに必要な大きさ（割合）。分からない・足りているものは 0
    /// - 戻り値: 直した starts / sizes。どうしても収まらない（最小の合計が画面より大きい）ときは、できるところまで
    static func refit(starts: [Double], sizes: [Double], mins: [Double]) -> (starts: [Double], sizes: [Double]) {
        let eps = 1e-6
        // 境目（列の区切り）の一覧
        var edges: [Double] = []
        for v in zip(starts, sizes).flatMap({ [$0.0, $0.0 + $0.1] }) where !edges.contains(where: { abs($0 - v) < 1e-4 }) {
            edges.append(v)
        }
        edges.sort()
        guard edges.count >= 2 else { return (starts, sizes) }
        func index(_ v: Double) -> Int { edges.firstIndex { abs($0 - v) < 1e-4 } ?? 0 }
        let spans = zip(starts, sizes).map { (index($0.0), index($0.0 + $0.1)) }
        var cols = (1..<edges.count).map { edges[$0] - edges[$0 - 1] }
        let floor = 0.05  // 列をこれ以上は細くしない（割合）

        func sum(_ s: (Int, Int)) -> Double { cols[s.0..<s.1].reduce(0, +) }

        var changed = false
        for _ in 0..<20 {
            // いちばん足りないウィンドウ
            let deficits = spans.indices.map { mins[$0] - sum(spans[$0]) }
            guard let i = deficits.indices.max(by: { deficits[$0] < deficits[$1] }), deficits[i] > eps else { break }
            let need = deficits[i]
            let mine = Set(spans[i].0..<spans[i].1)
            // ほかの列が細くなれる量（その列を含むウィンドウの余裕と、列の最小）
            var slack = cols.indices.map { k -> Double in
                guard !mine.contains(k) else { return 0 }
                var s = cols[k] - floor
                for (j, sp) in spans.enumerated() where (sp.0..<sp.1).contains(k) && mins[j] > 0 {
                    s = min(s, sum(sp) - mins[j])
                }
                return max(s, 0)
            }
            let total = slack.reduce(0, +)
            guard total > eps else { break }
            let take = min(need, total)
            for k in slack.indices { slack[k] = slack[k] / total * take; cols[k] -= slack[k] }
            let myWidth = mine.reduce(0) { $0 + cols[$1] }
            for k in mine { cols[k] += myWidth > eps ? take * cols[k] / myWidth : take / Double(mine.count) }
            changed = true
            if take < need - eps { break }
        }
        guard changed else { return (starts, sizes) }
        var e = [edges[0]]
        for c in cols { e.append(e.last! + c) }
        return (spans.map { e[$0.0] }, spans.map { e[$0.1] - e[$0.0] })
    }

    /// 場所の一覧と、ウィンドウに必要な幅・高さ（割合。0 は「足りている」）から、直した場所を返す
    static func refit(zones: [Zone], minW: [Double], minH: [Double]) -> [Zone] {
        let x = refit(starts: zones.map(\.x), sizes: zones.map(\.w), mins: minW)
        let y = refit(starts: zones.map(\.y), sizes: zones.map(\.h), mins: minH)
        return zones.indices.map { Zone(x.starts[$0], y.starts[$0], x.sizes[$0], y.sizes[$0]) }
    }
}
