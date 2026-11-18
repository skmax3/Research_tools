import CoreGraphics
import Foundation

/// 画面の境目でカーソルを少し止める判定（テストできるよう、画面やイベントには触らない）。
///
/// 例: Dell（上）と MacBook（下）を上下に並べていると、Dell の下の端でカーソルが止まらずに MacBook へ抜けてしまい、
/// Dock が出にくい。そこで、境目をまたごうとしたら hold 秒だけ境目の手前で止める。押し続ければ通り抜けられる。
/// 座標は左上原点・下向きが +y（CGEvent・アクセシビリティと同じ）。
struct EdgeBarrier {
    enum Edge: String { case top, bottom, left, right }

    /// 止める時間（秒）
    var hold: TimeInterval = 0.4
    /// false: 下の境目だけ止める（Dock が下にあるとき）／ true: 上下左右すべて
    var allSides = false
    /// この時間押すのをやめたら、止めた時間の数え直し
    var resetAfter: TimeInterval = 0.5

    private(set) var holdingEdge: Edge?
    private var hitStart: Date?
    private var lastPush: Date?

    /// カーソルが prev から next へ動こうとしたとき、止めるなら止める位置を返す。そのまま通すなら nil
    mutating func filter(from prev: CGPoint, to next: CGPoint, screens: [CGRect], now: Date) -> CGPoint? {
        guard let a = screens.first(where: { Self.contains($0, prev) }) else { reset(); return nil }
        if Self.contains(a, next) {
            if let last = lastPush, now.timeIntervalSince(last) > resetAfter { reset() }
            return nil
        }
        // 別の画面へ入るときだけ止める（どの画面でもない所へは、macOS が端で止める）
        guard screens.contains(where: { Self.contains($0, next) }) else { return nil }
        let edge = Self.edge(leaving: a, to: next)
        if !allSides && edge != .bottom { return nil }

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
