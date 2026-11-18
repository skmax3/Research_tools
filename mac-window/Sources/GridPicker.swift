import AppKit
import SwiftUI

/// キー入力を受け取れる、アプリを手前に出さないパネル（Spotlight のような窓）
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// ⌃⌥W：配置パネル（画面は LayoutBoard.swift）。
/// 「配置案から並べる」: 配置案を選び、開いているウィンドウを枠にドラッグして、まとめて並べる。
/// 「手前のウィンドウだけ動かす」: マス目のドラッグ・ボタンで、手前のウィンドウ 1 つを動かす
final class GridPickerController {
    private let mover: WindowMover
    private var panel: KeyPanel?
    private var preview: NSWindow?
    private var model: LayoutBoardModel?
    private var observer: NSObjectProtocol?

    var onAI: (() -> Void)?

    init(mover: WindowMover) { self.mover = mover }

    func toggle() {
        if panel != nil { close(); return }
        let screens = WindowMover.screenInfos()
        guard !screens.isEmpty else { NSSound.beep(); return }

        // 手前のウィンドウ（「手前のウィンドウだけ動かす」用）
        let w = WindowMover.focusedWindow()
        let f = w.flatMap { WindowMover.frame(of: $0) }
        let targetArea = f.flatMap { mover.area(for: $0) }
        let zone = f.flatMap { frame in targetArea.map { Geometry.zone(for: frame, in: $0) } }

        // パネルを出す画面・最初に並べる画面は、マウスのある画面
        let mouse = NSEvent.mouseLocation
        let index = NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0

        let model = LayoutBoardModel(settings: mover.settings, screens: screens, screenIndex: min(index, screens.count - 1),
                                     target: w, targetName: w == nil ? nil : NSWorkspace.shared.frontmostApplication?.localizedName,
                                     targetZone: zone, targetArea: targetArea)
        self.model = model

        let view = LayoutBoardView(
            model: model,
            aiName: mover.settings.aiName,
            onArrange: { [weak self] in self?.arrange() },
            onSave: { [weak self] in self?.save() },
            onAI: { [weak self] in self?.finish { self?.onAI?() } },
            onSingleChange: { [weak self] z in self?.showPreview(z) },
            onSingleCommit: { [weak self] z in self?.commitSingle(z) }
        )
        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 1060, height: 680)
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.onCancel = { [weak self] in self?.close() }
        // ↩ で並べる
        p.onKey = { [weak self] e in
            guard let self, e.keyCode == 36 || e.keyCode == 76, self.model?.mode == .layout else { return false }
            self.arrange()
            return true
        }
        let screen = WindowMover.toCocoa(screens[min(index, screens.count - 1)].frame)
        p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
        panel = p
        p.makeKeyAndOrderFront(nil)
        // ほかの場所をクリックしたら閉じる
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) {
            [weak self] _ in self?.close()
        }
    }

    /// 配置案どおりにまとめて並べる
    private func arrange() {
        guard let model else { return }
        let items = model.items()
        guard !items.isEmpty else { NSSound.beep(); return }
        let area = model.area
        let name = model.choice.name
        finish { [weak self] in self?.mover.arrange(items, area: area, name: name) }
    }

    /// 今の枠の割り当てを、配置プリセットとして保存する（名前は設定で変えられる）
    private func save() {
        guard let model else { return }
        let slots = model.slotsForPreset()
        guard !slots.isEmpty else { NSSound.beep(); return }
        let apps = slots.map(\.appName).prefix(3).joined(separator: " ＋ ")
        let preset = Preset(name: "\(model.choice.name)：\(apps)", slots: slots, screen: model.screenTarget)
        mover.settings.presets.append(preset)
        let n = mover.settings.presets.count
        let key = n <= Shortcut.presetKeys.count ? mover.settings.combo(for: Shortcut.presetKeys[n - 1])?.label : nil
        model.rebuildChoices()
        model.choiceID = "preset-\(preset.id.uuidString)"
        mover.onMoved?(key.map { "プリセットに保存しました（\($0)）" } ?? "プリセットに保存しました", model.area)
    }

    /// 選んでいる場所を、実際の画面の上に半透明で示す（手前のウィンドウだけ動かすとき）
    private func showPreview(_ z: Zone) {
        guard let area = model?.targetArea else { return }
        let frame = WindowMover.toCocoa(mover.frameFor(z, in: area))
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

    private func commitSingle(_ z: Zone) {
        guard let w = model?.target, let area = model?.targetArea else { NSSound.beep(); return }
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
        model = nil
    }
}
