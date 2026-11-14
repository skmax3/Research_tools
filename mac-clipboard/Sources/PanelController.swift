import AppKit
import SwiftUI

/// キー入力を先に受け取れるパネル。
/// nonactivatingPanel なので、出しても今使っているアプリは前面のまま（だから選んだあとそのアプリに貼り付けられる）。
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event) { return }
        super.sendEvent(event)
    }
}

/// パネルの表示状態（検索文字・選択中の番号）
final class PanelState: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selected = 0 } }
    }
    @Published var selected = 0
    @Published var focusToken = 0
}

/// 画面の下からせり上がる履歴パネル
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ClipStore
    private let paster: Paster
    private let state = PanelState()
    private var panel: KeyPanel!
    private var visible = false
    private let panelHeight: CGFloat = 290
    private var askedTrust = false

    init(store: ClipStore, paster: Paster) {
        self.store = store
        self.paster = paster
        super.init()
        build()
    }

    private func build() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: panelHeight),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        let view = PanelView(store: store, state: state) { [weak self] item, plain in
            self?.pick(item, plain: plain)
        }
        let host = NSHostingView(rootView: view)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
    }

    // MARK: - 表示

    func toggle() { visible ? hide() : show() }

    func show() {
        if visible { return }
        state.query = ""
        state.selected = 0

        // マウスがある画面の、Dock より上に出す
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let margin: CGFloat = 10
        let target = NSRect(x: vf.minX + margin, y: vf.minY + margin, width: vf.width - margin * 2, height: panelHeight)
        var start = target
        start.origin.y -= 40

        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        visible = true
        state.focusToken += 1

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(target, display: true)
            self.panel.animator().alphaValue = 1
        }
    }

    func hide(then completion: (() -> Void)? = nil) {
        guard visible else { completion?(); return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            completion?()
        })
    }

    /// ほかの場所をクリックしたら閉じる
    func windowDidResignKey(_ notification: Notification) {
        if visible { hide() }
    }

    // MARK: - 操作

    private var currentItems: [ClipItem] { ClipFilter.apply(store.items, query: state.query) }

    private func pick(_ item: ClipItem, plain: Bool) {
        guard paster.copy(item, plain: plain) else { NSSound.beep(); return }
        store.moveToTop(item.id)
        hide { [weak self] in
            guard let self, Settings.autoPaste else { return }
            if Paster.trusted {
                // パネルが消えて元のアプリにキー入力が戻るのを少し待ってから ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.sendPaste() }
            } else if !self.askedTrust {
                // 許可がない間はコピーまで。最初の1回だけ許可を求める
                self.askedTrust = true
                Paster.requestTrust()
            }
        }
    }

    /// true を返したキーはパネルで使い、検索欄には渡さない
    private func handleKey(_ e: NSEvent) -> Bool {
        let items = currentItems
        let cmd = e.modifierFlags.contains(.command)
        let opt = e.modifierFlags.contains(.option)
        switch Int(e.keyCode) {
        case 53:  // Esc
            hide()
            return true
        case 123:  // ←
            state.selected = max(0, state.selected - 1)
            return true
        case 124:  // →
            state.selected = min(max(0, items.count - 1), state.selected + 1)
            return true
        case 36, 76:  // Return / Enter（⌥ で書式なし）
            if items.indices.contains(state.selected) { pick(items[state.selected], plain: opt) }
            return true
        case 51 where cmd:  // ⌘⌫ 削除
            if items.indices.contains(state.selected) {
                store.delete(items[state.selected].id)
                state.selected = min(state.selected, max(0, items.count - 2))
            }
            return true
        case 35 where cmd:  // ⌘P ピン留め
            if items.indices.contains(state.selected) { store.togglePin(items[state.selected].id) }
            return true
        default:
            break
        }
        // ⌘1〜⌘9 でその番号を貼り付け
        if cmd, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            if items.count >= n { pick(items[n - 1], plain: opt) }
            return true
        }
        return false
    }
}
