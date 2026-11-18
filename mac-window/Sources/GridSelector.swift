import SwiftUI

/// 図に薄く表示する、ほかのウィンドウの場所
struct LabeledZone: Identifiable {
    let id: UUID
    let zone: Zone
    let label: String
    var color: Color = .gray
}

/// 画面を表す図。マス目をドラッグすると場所を選べる
struct GridSelector: View {
    var cols = 12
    var rows = 6
    /// 今選んでいる場所（強調表示）
    var highlight: Zone?
    var highlightLabel = ""
    /// ほかの場所（薄く表示）
    var others: [LabeledZone] = []
    var onChange: (Zone) -> Void = { _ in }
    var onCommit: (Zone) -> Void = { _ in }

    @State private var dragging: Zone?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let cw = size.width / CGFloat(cols)
            let ch = size.height / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                // マス目
                ForEach(0..<(cols * rows), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: max(1, cw - 3), height: max(1, ch - 3))
                        .offset(x: CGFloat(i % cols) * cw + 1.5, y: CGFloat(i / cols) * ch + 1.5)
                }
                ForEach(others) { o in
                    zoneBox(o.zone, size: size, fill: o.color.opacity(0.35), stroke: o.color.opacity(0.8), label: o.label)
                }
                if let z = dragging ?? highlight {
                    zoneBox(z, size: size, fill: Color.accentColor.opacity(0.45), stroke: Color.accentColor,
                            label: dragging == nil ? highlightLabel : "")
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let z = zone(from: v.startLocation, to: v.location, size: size)
                        if z != dragging {
                            dragging = z
                            onChange(z)
                        }
                    }
                    .onEnded { v in
                        let z = zone(from: v.startLocation, to: v.location, size: size)
                        dragging = nil
                        onCommit(z)
                    }
            )
        }
    }

    private func zone(from a: CGPoint, to b: CGPoint, size: CGSize) -> Zone {
        let s = Geometry.cell(at: a, size: size, cols: cols, rows: rows)
        let e = Geometry.cell(at: b, size: size, cols: cols, rows: rows)
        return Geometry.gridZone(c0: s.c, r0: s.r, c1: e.c, r1: e.r, cols: cols, rows: rows)
    }

    private func zoneBox(_ z: Zone, size: CGSize, fill: Color, stroke: Color, label: String) -> some View {
        let inset: CGFloat = 2
        let w = max(4, CGFloat(z.w) * size.width - inset * 2)
        let h = max(4, CGFloat(z.h) * size.height - inset * 2)
        return RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: 1.5) }
            .overlay {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            }
            .frame(width: w, height: h)
            .offset(x: CGFloat(z.x) * size.width + inset, y: CGFloat(z.y) * size.height + inset)
            .allowsHitTesting(false)
    }
}
