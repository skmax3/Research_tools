import AppKit
import SwiftUI

/// 動かしたときに、場所の名前を画面の真ん中に一瞬出す（どのキーで何が起きたか覚えやすくする）
final class Toast {
    private var panel: NSPanel?
    private var token = 0

    /// area: 出す画面の範囲（左上原点）
    func show(_ text: String, in area: CGRect, zone: Zone? = nil) {
        token += 1
        let my = token
        let host = NSHostingView(rootView: ToastView(text: text, zone: zone))
        let size = host.fittingSize
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        let screen = WindowMover.toCocoa(area)
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                          width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.token == my, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.token == my else { return }
                self.panel?.orderOut(nil)
            })
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }
}

private struct ToastView: View {
    let text: String
    let zone: Zone?

    var body: some View {
        HStack(spacing: 12) {
            if let zone {
                ZoneIcon(zones: [zone], size: CGSize(width: 48, height: 27))
            }
            Text(text).font(.title3.weight(.semibold))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 画面の中の場所を表す小さな図（メニュー・通知・配置パネルで使う）
struct ZoneIcon: View {
    let zones: [Zone]
    var size = CGSize(width: 32, height: 18)
    var colors: [Color] = [.accentColor]

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).stroke(Color.secondary, lineWidth: 1)
            ForEach(Array(zones.enumerated()), id: \.offset) { i, z in
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors[i % colors.count])
                    .frame(width: max(2, CGFloat(z.w) * size.width - 3), height: max(2, CGFloat(z.h) * size.height - 3))
                    .offset(x: CGFloat(z.x) * size.width + 1.5, y: CGFloat(z.y) * size.height + 1.5)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// メニュー用の図（NSImage）
enum ZoneImage {
    static let palette: [NSColor] = [.systemOrange, .systemBlue, .systemGreen, .systemPurple, .systemPink,
                                     .systemTeal, .systemYellow, .systemRed, .systemIndigo, .systemMint]

    static func make(_ zones: [Zone], colors: [NSColor] = [.controlAccentColor], size: NSSize = NSSize(width: 28, height: 16)) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            NSColor.secondaryLabelColor.setStroke()
            frame.lineWidth = 1
            frame.stroke()
            for (i, z) in zones.enumerated() {
                let r = NSRect(x: CGFloat(z.x) * rect.width + 1.5, y: CGFloat(z.y) * rect.height + 1.5,
                               width: max(1, CGFloat(z.w) * rect.width - 3), height: max(1, CGFloat(z.h) * rect.height - 3))
                colors[i % colors.count].setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
    }

    static func preset(_ p: Preset) -> NSImage {
        make(p.slots.map(\.zone), colors: palette)
    }
}
