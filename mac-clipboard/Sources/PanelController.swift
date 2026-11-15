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

/// パネルの表示状態
final class PanelState: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selected = 0 } }
    }
    /// カーソル（枠が付いているカード）の位置
    @Published var selected = 0
    /// 複数選択した項目（選んだ順）
    @Published var picked: [UUID] = []
    /// 種類で絞り込み（nil ならすべて）
    @Published var kind: ClipCategory? {
        didSet { if kind != oldValue { selected = 0 } }
    }
    /// アプリで絞り込み（ClipItem.appKey。nil ならすべて）
    @Published var app: String? {
        didSet { if app != oldValue { selected = 0 } }
    }
    /// アプリごとにまとめて並べる
    @Published var sortByApp = false
    @Published var focusToken = 0
    /// 自動貼り付けがオンなのに、アクセシビリティの許可がない
    @Published var needsTrust = false

    func togglePick(_ id: UUID) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
    }
}

/// パネルからの操作をまとめたもの（PanelView から呼ぶ）
struct PanelActions {
    var paste: (ClipItem) -> Void
    var pastePicked: (_ together: Bool) -> Void
    var transform: (ClipItem, TextTransform) -> Void
    var openTrust: () -> Void
    var sendToPhone: ([ClipItem]) -> Void
}

/// 画面の下からせり上がる履歴パネル
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ClipStore
    private let paster: Paster
    private let sync: SyncManager
    private let onNeedPairing: () -> Void
    private let state = PanelState()
    private var panel: KeyPanel!
    private var visible = false
    private let panelHeight: CGFloat = 364
    private var askedTrust = false

    init(store: ClipStore, paster: Paster, sync: SyncManager, onNeedPairing: @escaping () -> Void) {
        self.store = store
        self.paster = paster
        self.sync = sync
        self.onNeedPairing = onNeedPairing
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

        let actions = PanelActions(
            paste: { [weak self] item in self?.pasteOne(item, plain: false) },
            pastePicked: { [weak self] together in self?.pastePicked(together: together) },
            transform: { [weak self] item, t in self?.transform(item, t) },
            openTrust: {
                Paster.requestTrust()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            },
            sendToPhone: { [weak self] items in self?.sendToPhone(items) }
        )
        let host = NSHostingView(rootView: PanelView(store: store, state: state, actions: actions))
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
        state.picked = []
        state.needsTrust = Settings.autoPaste && !Paster.trusted

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

    // MARK: - 貼り付け

    private var currentItems: [ClipItem] { ClipFilter.apply(store.items, state: state) }

    /// 自動貼り付けができるか確認。できなければ（最初の1回だけ）許可を求める
    private func canAutoPaste() -> Bool {
        guard Settings.autoPaste else { return false }
        if Paster.trusted { return true }
        if !askedTrust {
            askedTrust = true
            Paster.requestTrust()
        }
        return false
    }

    private func pasteOne(_ item: ClipItem, plain: Bool) {
        guard paster.copy(item, plain: plain) else { NSSound.beep(); return }
        store.moveToTop(item.id)
        hide { [weak self] in
            guard let self, self.canAutoPaste() else { return }
            // パネルが消えて元のアプリにキー入力が戻るのを少し待ってから ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.sendPaste() }
        }
    }

    /// テキストを変換して貼り付ける。変換結果は履歴にも新しい項目として残す
    private func transform(_ item: ClipItem, _ t: TextTransform) {
        guard item.kind == .text else { NSSound.beep(); return }
        let out = t.apply(item.text)
        guard !out.isEmpty else { NSSound.beep(); return }
        paster.copyText(out)
        var new = ClipItem(kind: .text)
        new.text = out
        new.app = "クリップ棚"
        new.appID = Bundle.main.bundleIdentifier ?? ""
        new.hash = ClipStore.hash(Data(out.utf8))
        store.add(new)
        hide { [weak self] in
            guard let self, self.canAutoPaste() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.sendPaste() }
        }
    }

    /// iPhone へ送る。まだペアリングしていなければ、ペアリング画面を開く
    private func sendToPhone(_ items: [ClipItem]) {
        guard !items.isEmpty else { return }
        guard sync.paired else {
            hide { [weak self] in self?.onNeedPairing() }
            return
        }
        state.picked = []
        sync.send(items)
        hide()
    }

    /// ⌘T で出す変換メニュー
    private var menuItem: ClipItem?

    private func showTransformMenu(for item: ClipItem) {
        guard item.kind == .text, let view = panel.contentView else { NSSound.beep(); return }
        menuItem = item
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "変換して貼り付け"))
        for t in TextTransform.allCases {
            if t == .markdown { menu.addItem(.separator()) }
            let mi = NSMenuItem(title: t.title, action: #selector(transformPicked(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t.rawValue
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 24, y: view.bounds.height - 44), in: view)
    }

    @objc private func transformPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = TextTransform(rawValue: raw),
              let item = menuItem else { return }
        transform(item, t)
    }

    /// 複数選択した項目を貼る。together=true なら1回にまとめる（種類が混ざっていたら順番に）
    private func pastePicked(together: Bool) {
        let list = state.picked.compactMap { id in store.items.first { $0.id == id } }
        guard !list.isEmpty else { return }
        state.picked = []
        if list.count == 1 { pasteOne(list[0], plain: false); return }

        if together, paster.copyTogether(list) {
            hide { [weak self] in
                guard let self, self.canAutoPaste() else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.sendPaste() }
            }
            return
        }
        hide { [weak self] in
            guard let self else { return }
            if self.canAutoPaste() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.pasteSequence(list, index: 0) }
            } else {
                // 自動で貼れないときは、テキストだけでもまとめてコピーしておく
                _ = self.paster.copyTogether(list.filter { $0.kind == .text })
            }
        }
    }

    /// 1件ずつ「コピー → ⌘V」を繰り返す。テキストが続くときは間で改行する
    private func pasteSequence(_ list: [ClipItem], index: Int) {
        guard index < list.count else { return }
        let item = list[index]
        let needReturn = index > 0 && list[index - 1].kind == .text && item.kind == .text
        if needReturn { Paster.sendReturn() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (needReturn ? 0.06 : 0)) {
            self.paster.copy(item, plain: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Paster.sendPaste()
                // 画像やファイルは貼り付けに時間がかかるアプリが多いので長めに待つ
                let wait = item.kind == .text ? 0.2 : 0.45
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.pasteSequence(list, index: index + 1) }
            }
        }
    }

    // MARK: - キー操作

    /// true を返したキーはパネルで使い、検索欄には渡さない
    private func handleKey(_ e: NSEvent) -> Bool {
        // 日本語入力の変換中は、矢印・Enter・Space を変換に使わせる
        if let tv = panel.firstResponder as? NSTextView, tv.hasMarkedText() { return false }

        let items = currentItems
        let cmd = e.modifierFlags.contains(.command)
        let opt = e.modifierFlags.contains(.option)
        let shift = e.modifierFlags.contains(.shift)
        let cur: ClipItem? = items.indices.contains(state.selected) ? items[state.selected] : nil

        switch Int(e.keyCode) {
        case 53:  // Esc: 選択があれば解除、なければ閉じる
            if state.picked.isEmpty { hide() } else { state.picked = [] }
            return true
        case 123:  // ←
            state.selected = max(0, state.selected - 1)
            if shift, let c = items.indices.contains(state.selected) ? items[state.selected] : nil,
               !state.picked.contains(c.id) { state.picked.append(c.id) }
            return true
        case 124:  // →
            state.selected = min(max(0, items.count - 1), state.selected + 1)
            if shift, let c = items.indices.contains(state.selected) ? items[state.selected] : nil,
               !state.picked.contains(c.id) { state.picked.append(c.id) }
            return true
        case 36, 76:  // Return / Enter
            if !state.picked.isEmpty {
                pastePicked(together: shift)  // ⇧Enter でまとめて
            } else if let cur {
                pasteOne(cur, plain: opt)  // ⌥Enter で書式なし
            }
            return true
        case 49 where !cmd:  // Space: 複数選択に入れる／外す
            if let cur { state.togglePick(cur.id) }
            return true
        case 48:  // Tab: 種類の絞り込みを切り替え
            let all: [ClipCategory?] = [nil] + ClipCategory.allCases.map { Optional($0) }
            let i = all.firstIndex(where: { $0 == state.kind }) ?? 0
            state.kind = all[(i + (shift ? all.count - 1 : 1)) % all.count]
            return true
        case 0 where cmd:  // ⌘A: 表示中をすべて選択
            state.picked = items.map(\.id)
            return true
        case 51 where cmd:  // ⌘⌫ 削除
            if let cur {
                store.delete(cur.id)
                state.picked.removeAll { $0 == cur.id }
                state.selected = min(state.selected, max(0, items.count - 2))
            }
            return true
        case 17 where cmd:  // ⌘T 変換メニュー
            if let cur { showTransformMenu(for: cur) }
            return true
        case 34 where cmd:  // ⌘I iPhone へ送る（複数選択中は選んだものを全部）
            let list = state.picked.isEmpty
                ? (cur.map { [$0] } ?? [])
                : state.picked.compactMap { id in store.items.first { $0.id == id } }
            sendToPhone(list)
            return true
        case 35 where cmd:  // ⌘P ピン留め
            if let cur { store.togglePin(cur.id) }
            return true
        default:
            break
        }
        // ⌘1〜⌘9 でその番号を貼り付け
        if cmd, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            if items.count >= n { pasteOne(items[n - 1], plain: opt) }
            return true
        }
        return false
    }
}
