import Foundation

/// 履歴を残す決まり（件数と容量）。画面やファイルに触らない計算だけなので、Tests/main.swift で確かめられる。
///
/// - ピン留めは消さない（容量の合計には入れる）
/// - ピン留め以外は、新しい順に maxItems 件まで
/// - さらに、全体の大きさが maxBytes を超えていたら、ピン留め以外の古いものから消す
/// - いちばん新しい 1 件（いまコピーしたもの）は消さない
enum StoragePolicy {
    struct Entry {
        var pinned: Bool
        /// 画像・サムネイル・書式付きテキストのファイルの合計（バイト）
        var bytes: Int64
    }

    /// entries は新しい順。消すものの番号を返す。maxBytes が nil なら容量の上限なし
    static func toRemove(_ entries: [Entry], maxItems: Int, maxBytes: Int64?) -> Set<Int> {
        var remove = Set<Int>()
        var count = 0
        for (i, e) in entries.enumerated() where !e.pinned {
            count += 1
            if count > maxItems { remove.insert(i) }
        }
        guard let maxBytes else { return remove }
        var total = entries.indices.filter { !remove.contains($0) }.reduce(Int64(0)) { $0 + entries[$1].bytes }
        // 古いものから消していく
        for i in entries.indices.reversed() where total > maxBytes {
            guard i > 0, !entries[i].pinned, !remove.contains(i), entries[i].bytes > 0 else { continue }
            remove.insert(i)
            total -= entries[i].bytes
        }
        return remove
    }

    /// 大きい順に並べたときの番号（bytes は今の並びでの大きさ）。同じ大きさ・0 のものは、今の並びのまま後ろに置く
    static func sizeOrder(_ bytes: [Int64]) -> [Int] {
        bytes.indices.sorted { a, b in bytes[a] != bytes[b] ? bytes[a] > bytes[b] : a < b }
    }

    /// 古い画像を軽くする日数の選びかた（0 は「しない」）
    static let compressChoices = [3, 7, 30, 0]
    static let compressDefaultDays = 7

    static func compressLabel(days: Int) -> String {
        days == 0 ? "しない" : "\(days)日後"
    }

    /// date から days 日以上たっているか（days が 0 なら、いつまでも「古くない」）
    static func isOldEnough(_ date: Date, now: Date, days: Int) -> Bool {
        days > 0 && now.timeIntervalSince(date) >= Double(days) * 86400
    }

    /// 軽くした結果を採用するか。minSaving が 0.3 なら、3 割以上小さくなるときだけ
    static func worthwhile(original: Int, compressed: Int, minSaving: Double) -> Bool {
        original > 0 && compressed > 0 && Double(compressed) <= Double(original) * (1 - minSaving)
    }

    /// 選べる容量の上限（MB）。0 は「上限なし」
    static let choicesMB = [500, 1024, 2048, 5120, 0]
    static let defaultMB = 1024

    static func label(mb: Int) -> String {
        if mb == 0 { return "上限なし" }
        return mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB"
    }
}
