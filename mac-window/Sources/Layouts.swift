import Foundation

/// 配置パネルで選ぶ「配置案」のひな形（アプリは決めず、場所だけ）。
/// 配置案を増やすときは、ここに 1 行足す（テストが範囲と重なりを確かめる）
struct LayoutTemplate: Identifiable {
    let id: String
    let name: String
    let zones: [Zone]
    /// 並べたあとフルスクリーンにする枠
    var fullScreen: [Bool] = []

    func isFullScreen(_ i: Int) -> Bool { i < fullScreen.count && fullScreen[i] }

    private static func z(_ n: NamedZone) -> Zone { n.zone }

    static let builtIn: [LayoutTemplate] = [
        LayoutTemplate(id: "max", name: "1 つを大きく", zones: [z(.maximize)]),
        LayoutTemplate(id: "full", name: "フルスクリーン", zones: [z(.maximize)], fullScreen: [true]),
        LayoutTemplate(id: "halves", name: "左右に半分ずつ", zones: [z(.leftHalf), z(.rightHalf)]),
        LayoutTemplate(id: "third-two", name: "1/3 ＋ 2/3", zones: [z(.leftThird), z(.rightTwoThirds)]),
        LayoutTemplate(id: "two-third", name: "2/3 ＋ 1/3", zones: [z(.leftTwoThirds), z(.rightThird)]),
        LayoutTemplate(id: "thirds", name: "3 列", zones: [z(.leftThird), z(.centerThird), z(.rightThird)]),
        LayoutTemplate(id: "quarter-half", name: "1/4 ＋ 1/2 ＋ 1/4", zones: [z(.leftQuarter), z(.centerHalf), z(.rightQuarter)]),
        LayoutTemplate(id: "third-stack", name: "1/3 ＋ 2/3 を上下",
                       zones: [z(.leftThird), Zone(1.0 / 3, 0, 2.0 / 3, 0.5), Zone(1.0 / 3, 0.5, 2.0 / 3, 0.5)]),
        LayoutTemplate(id: "thirds-right-stack", name: "3 列（右を上下）",
                       zones: [z(.leftThird), z(.centerThird), z(.rightThirdTop), z(.rightThirdBottom)]),
        LayoutTemplate(id: "six", name: "6 分割（3 列 × 上下）",
                       zones: [z(.leftThirdTop), z(.centerThirdTop), z(.rightThirdTop),
                               z(.leftThirdBottom), z(.centerThirdBottom), z(.rightThirdBottom)]),
        LayoutTemplate(id: "four", name: "4 分割", zones: [z(.topLeft), z(.topRight), z(.bottomLeft), z(.bottomRight)]),
        LayoutTemplate(id: "rows", name: "上下に半分ずつ", zones: [z(.topHalf), z(.bottomHalf)]),
    ]

    /// 重なっている枠があるか（テスト用）
    var hasOverlap: Bool {
        for i in zones.indices {
            for j in zones.indices where j > i {
                let a = zones[i], b = zones[j]
                let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
                let h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
                if w > 0.001 && h > 0.001 { return true }
            }
        }
        return false
    }
}
