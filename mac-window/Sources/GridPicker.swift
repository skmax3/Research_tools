import AppKit
import SwiftUI

/// キー入力を受け取れる、アプリを手前に出さないパネル（Spotlight のような小さな窓）
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onKey: ((String) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if let c = event.charactersIgnoringModifiers, onKey?(c) == true { return }
        super.keyDown(with: event)
    }
}

/// ⌃⌥W：配置パネル。手前のウィンドウを、マス目のドラッグ・よく使う場所・プリセット・AI と並べる から選んで動かす。
/// ショートカットを覚えていなくても、マウスだけで全部の機能が使える
final class GridPickerController {
    private let mover: WindowMover
    private var panel: KeyPanel?
    private var preview: NSWindow?
    private var target: AXUIElement?
    private var area: CGRect = .zero
    private var observer: NSObjectProtocol?

    /// プリセット・AI はパネルを閉じてから App 側で実行する
    var onPreset: ((Int) -> Void)?
    var onAI: (() -> Void)?

    init(mover: WindowMover) { self.mover = mover }

    func toggle() {
        if panel != nil { close(); return }
        let w = WindowMover.focusedWindow()
        let f = w.flatMap { WindowMover.frame(of: $0) }
        // ウィンドウがない（デスクトップを選んでいる）ときも、プリセットと AI は使えるように開く
        guard let area = f.flatMap({ mover.area(for: $0) }) ?? WindowMover.mouseArea() else { NSSound.beep(); return }
        target = w
        self.area = area
        let current = f.map { Geometry.zone(for: $0, in: area) }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName

        let view = PanelHUD(
            aspect: area.width / max(area.height, 1),
            current: current,
            targetName: w == nil ? nil : appName,
            presets: mover.settings.presets,
            aiName: mover.settings.aiName,
            onChange: { [weak self] z in self?.showPreview(z) },
            onCommit: { [weak self] z in self?.commit(z) },
            onPreset: { [weak self] i in self?.finish { self?.onPreset?(i) } },
            onAI: { [weak self] in self?.finish { self?.onAI?() } },
            onCancel: { [weak self] in self?.close() }
        )
        let host = NSHostingView(rootView: view)
        let width: CGFloat = 600
        let fit = host.fittingSize
        let height = fit.height > 0 ? fit.height : 520
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.onCancel = { [weak self] in self?.close() }
        // 数字キー 1〜9 でもプリセットを選べる
        p.onKey = { [weak self] c in
            guard let n = Int(c), n >= 1, n <= 9, let self, n <= self.mover.settings.presets.count else { return false }
            self.finish { self.onPreset?(n - 1) }
            return true
        }
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
        guard target != nil else { return }
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
        guard let w = target else { NSSound.beep(); return }
        let area = self.area
        finish { [weak self] in self?.mover.place(w, zone: z, area: area) }
    }

    /// パネルを見えなくしてから action を実行し、後で片付ける
    /// （ドラッグやボタンの処理の途中でパネルを捨てると落ちることがあるため）
    private func finish(_ action: @escaping () -> Void) {
        preview?.orderOut(nil)
        panel?.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            self?.close()
            action()
        }
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

private struct PanelHUD: View {
    let aspect: CGFloat
    let current: Zone?
    let targetName: String?
    let presets: [Preset]
    let aiName: String
    let onChange: (Zone) -> Void
    let onCommit: (Zone) -> Void
    let onPreset: (Int) -> Void
    let onAI: () -> Void
    let onCancel: () -> Void

    private let quick: [NamedZone] = [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                                      .leftHalf, .rightHalf, .centerHalf, .leftQuarter, .maximize]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.split.3x1").foregroundStyle(.secondary)
                Text(targetName.map { "「\($0)」を動かす" } ?? "配置パネル").font(.headline)
                Spacer()
                Text("Esc で閉じる").font(.caption).foregroundStyle(.secondary)
            }

            if targetName != nil {
                Text("マス目をドラッグして場所を選ぶ").font(.caption).foregroundStyle(.secondary)
                GridSelector(cols: 12, rows: 6, highlight: current, highlightLabel: "いまの場所",
                             onChange: onChange, onCommit: onCommit)
                    .aspectRatio(aspect, contentMode: .fit)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(quick) { z in
                        Button { onCommit(z.zone) } label: {
                            VStack(spacing: 3) {
                                ZoneIcon(zones: [z.zone], size: CGSize(width: 36, height: 20))
                                Text(z.title).font(.caption2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("動かすウィンドウがありません。プリセットか AI を選べます。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Text("配置プリセット（数字キーでも選べる）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { onAI() } label: { Label("AI と並べる（\(aiName)）", systemImage: "sparkles") }
                    .controlSize(.small)
            }
            if presets.isEmpty {
                Text("プリセットはまだありません。メニューの「設定…」から作れます。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(Array(presets.prefix(9).enumerated()), id: \.element.id) { i, p in
                        Button { onPreset(i) } label: {
                            HStack(spacing: 8) {
                                Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                ZoneIcon(zones: p.slots.map(\.zone), size: CGSize(width: 40, height: 22),
                                         colors: slotColors)
                                Text(p.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)) }
    }
}
