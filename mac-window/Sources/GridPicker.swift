import AppKit
import SwiftUI

/// キー入力を受け取れる、アプリを手前に出さないパネル（Spotlight のような小さな窓）
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// ⌃⌥W：手前のウィンドウの場所を、マス目をドラッグして決める
final class GridPickerController {
    private let mover: WindowMover
    private var panel: KeyPanel?
    private var preview: NSWindow?
    private var target: AXUIElement?
    private var area: CGRect = .zero
    private var observer: NSObjectProtocol?

    init(mover: WindowMover) { self.mover = mover }

    func toggle() {
        if panel != nil { close(); return }
        guard let w = WindowMover.focusedWindow(), let f = WindowMover.frame(of: w), let area = mover.area(for: f) else {
            NSSound.beep()
            return
        }
        target = w
        self.area = area
        let current = Geometry.zone(for: f, in: area)

        let view = GridHUD(
            aspect: area.width / max(area.height, 1),
            current: current,
            onChange: { [weak self] z in self?.showPreview(z) },
            onCommit: { [weak self] z in self?.commit(z) },
            onCancel: { [weak self] in self?.close() }
        )
        let host = NSHostingView(rootView: view)
        let width: CGFloat = 560
        let height = host.fittingSize.height > 0 ? host.fittingSize.height : 420
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.onCancel = { [weak self] in self?.close() }
        let screen = WindowMover.toCocoa(area)
        p.setFrameOrigin(NSPoint(x: screen.midX - width / 2, y: screen.midY - height / 2))
        panel = p
        p.makeKeyAndOrderFront(nil)
        // ほかの場所をクリックしたら閉じる
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) {
            [weak self] _ in self?.close()
        }
    }

    /// 選んでいる場所を、実際の画面の上に半透明で示す
    private func showPreview(_ z: Zone) {
        let frame = WindowMover.toCocoa(Geometry.frame(for: z, in: area, gap: CGFloat(mover.settings.gap)))
        if preview == nil {
            let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .floating
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            v.layer?.borderColor = NSColor.controlAccentColor.cgColor
            v.layer?.borderWidth = 3
            v.layer?.cornerRadius = 12
            w.contentView = v
            preview = w
        }
        preview?.setFrame(frame, display: true)
        preview?.orderFront(nil)
        panel?.orderFront(nil)
    }

    private func commit(_ z: Zone) {
        if let w = target { mover.place(w, zone: z, area: area) }
        // ドラッグの処理の途中で図（パネル）を片付けないよう、見えなくするだけにして、後で閉じる
        preview?.orderOut(nil)
        panel?.orderOut(nil)
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        preview?.orderOut(nil)
        preview = nil
        panel?.orderOut(nil)
        panel = nil
        target = nil
    }
}

private struct GridHUD: View {
    let aspect: CGFloat
    let current: Zone
    let onChange: (Zone) -> Void
    let onCommit: (Zone) -> Void
    let onCancel: () -> Void

    private let quick: [NamedZone] = [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                                      .leftHalf, .rightHalf, .centerHalf, .maximize]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ドラッグして場所を選ぶ").font(.headline)
                Spacer()
                Text("Esc で閉じる").font(.caption).foregroundStyle(.secondary)
            }
            GridSelector(cols: 12, rows: 6, highlight: current, highlightLabel: "いまの場所",
                         onChange: onChange, onCommit: onCommit)
                .aspectRatio(aspect, contentMode: .fit)
            // よく使う場所はボタンでも
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(quick) { z in
                    Button(z.title) { onCommit(z.zone) }
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)) }
    }
}
