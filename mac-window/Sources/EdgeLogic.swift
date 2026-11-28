import CoreGraphics
import Foundation

/// 画面の境目でカーソルを少し止める判定（テストできるよう、画面やイベントには触らない）。
///
/// 例: Dell（上）と MacBook（下）を上下に並べていると、Dell の下の端でカーソルが止まらずに MacBook へ抜けてしまい、
/// Dock が出にくい。そこで、境目をまたごうとしたら hold 秒だけ境目の手前で止める。押し続ければ通り抜けられる。
/// 上へ動かして境目をまたぐとき（MacBook → Dell）は、止まる場所が違う: Dell の下の端にカーソルを置いて、holdUp 秒そこに留める
/// （下へ動かすときに止まる場所と同じで、Dock が出る）。
/// 座標は左上原点・下向きが +y（CGEvent・アクセシビリティと同じ）。
struct EdgeBarrier {
    enum Edge: String { case top, bottom, left, right }

    /// 止める時間（秒）。下・左右の境目で、手前の画面の端に止める
    var hold: TimeInterval = 0.4
    /// 上へ動かして上の画面へ入るとき、上の画面の下端に留める時間（秒）。0 なら止めない
    var holdUp: TimeInterval = 0.4
    /// false: 上下の境目だけ止める（Dock を出しやすく）／ true: 上下左右すべて
    var allSides = false
    /// この時間押すのをやめたら、止めた時間の数え直し
    var resetAfter: TimeInterval = 0.5

    private(set) var holdingEdge: Edge?
    private var hitStart: Date?
    private var lastPush: Date?
    /// 上の画面の下端に着いてから、留めている間の状態（その画面・下端の y・いつまで）
    private var pin: (screen: CGRect, y: CGFloat, until: Date)?

    /// カーソルが prev から next へ動こうとしたとき、止めるなら止める位置を返す。そのまま通すなら nil
    mutating func filter(from prev: CGPoint, to next: CGPoint, screens: [CGRect], now: Date) -> CGPoint? {
        // 上の画面の下端に留めている間は、さらに上へ動こうとしても下端に押さえる（横には動ける）。
        // 時間がたつ・その画面を出る・もう下端にいない・下へ戻るときは、留めるのをやめる
        if let p = pin {
            if now >= p.until || !Self.contains(p.screen, prev) || prev.y < p.y - 1 {
                pin = nil
            } else if next.y < p.y && next.x >= p.screen.minX && next.x < p.screen.maxX {
                return CGPoint(x: next.x, y: p.y)
            } else if !Self.contains(p.screen, next) {
                pin = nil
            }
        }
        // 同じ画面の中の動きは何もしない。画面が重なっている（BetterDisplay の仮想画面・ミラーなど）ときも、
        // 前と今の位置を両方含む画面があれば「境目を越えた」とはみなさない（画面の途中で止まらないように）
        if screens.contains(where: { Self.contains($0, prev) && Self.contains($0, next) }) {
            if let last = lastPush, now.timeIntervalSince(last) > resetAfter { reset() }
            return nil
        }
        guard let a = screens.first(where: { Self.contains($0, prev) }) else { reset(); return nil }
        // 別の画面へ入るときだけ止める（どの画面でもない所へは、macOS が端で止める）
        guard let b = screens.first(where: { Self.contains($0, next) }) else { return nil }
        let edge = Self.edge(leaving: a, to: next)
        if !allSides && edge != .bottom && edge != .top { return nil }

        // 上へ動かして上の画面へ入るとき: 上の画面の下端にカーソルを置いて、holdUp 秒そこに留める
        if edge == .top {
            guard holdUp > 0 else { return nil }
            reset()
            let y = b.maxY - 1
            pin = (b, y, now.addingTimeInterval(holdUp))
            return CGPoint(x: min(max(next.x, b.minX), b.maxX - 1), y: y)
        }

        if let last = lastPush, now.timeIntervalSince(last) > resetAfter { reset() }
        if hitStart == nil || holdingEdge != edge {
            hitStart = now
            holdingEdge = edge
        }
        lastPush = now
        if let start = hitStart, now.timeIntervalSince(start) >= hold {
            reset()
            return nil  // 押し続けたので通す
        }
        return CGPoint(x: min(max(next.x, a.minX), a.maxX - 1), y: min(max(next.y, a.minY), a.maxY - 1))
    }

    mutating func reset() {
        hitStart = nil
        lastPush = nil
        holdingEdge = nil
    }

    static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }

    /// 画面 a からどの端を通って出ようとしているか
    static func edge(leaving a: CGRect, to p: CGPoint) -> Edge {
        if p.y >= a.maxY { return .bottom }
        if p.y < a.minY { return .top }
        if p.x >= a.maxX { return .right }
        return .left
    }
}
