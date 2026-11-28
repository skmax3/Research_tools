import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// アプリの入口。Dock には出さず、メニューバーに常駐する（Info.plist の LSUIElement）。
@main
enum ClipShelfMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = ClipStore()
    private var watcher: PasteboardWatcher!
    private var paster: Paster!
    private var panel: PanelController!
    private var sync: SyncManager!
    private let front = FrontAppTracker()
    /// 起動の直後に、準備ができる前に届いた URL
    private var pendingLinks: [DeepLink] = []
    private var pairing: PairingWindowController!
    private var flashToken = 0
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    // メニューの項目（チェック状態を更新するために保持）
    private let autoPasteItem = NSMenuItem(title: "選んだら自動で貼り付け", action: #selector(AppDelegate.toggleAutoPaste), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "記録を一時停止", action: #selector(AppDelegate.togglePause), keyEquivalent: "")
    /// 履歴の容量（使用量と上限）。サブメニューで上限を選ぶ
    private let storageItem = NSMenuItem(title: "履歴の容量", action: nil, keyEquivalent: "")
    private let storageMenu = NSMenu()
    private let compressItem = NSMenuItem(title: "古い画像を軽くする", action: nil, keyEquivalent: "")
    private let compressMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(AppDelegate.toggleLogin), keyEquivalent: "")
    private let autoSendItem = NSMenuItem(title: "コピーしたら、ほかの端末へ自動で送る", action: #selector(AppDelegate.toggleAutoSend), keyEquivalent: "")
    private let urlActionsItem = NSMenuItem(title: "URL からの貼り付け・送信・変換を許可（Logi Options+ など）", action: #selector(AppDelegate.toggleURLActions), keyEquivalent: "")
    private let pairItem = NSMenuItem(title: "端末のペアリング…", action: #selector(AppDelegate.openPairing), keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "最新版にアップデート…", action: #selector(AppDelegate.update), keyEquivalent: "")
    private let trustItem = NSMenuItem(title: "自動貼り付けを許可する（アクセシビリティ）…", action: #selector(AppDelegate.openAccessibility), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // すでに別のクリップ棚が動いていたら終了させる（Xcode から実行したときと、インストール版が二重に動かないように）
        let me = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other.processIdentifier != me.processIdentifier {
            other.terminate()
        }

        store.load()
        watcher = PasteboardWatcher(store: store)
        watcher.start()
        paster = Paster(store: store, watcher: watcher)
        sync = SyncManager(store: store, paster: paster)
        pairing = PairingWindowController(sync: sync)
        sync.onReceived = { [weak self] count, from in
            self?.flashStatus(symbol: "tray.and.arrow.down.fill", title: " \(from)から\(count)件", seconds: 4)
            NSSound(named: "Tink")?.play()
        }
        sync.onSent = { [weak self] ok, message in
            self?.flashStatus(symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                              title: ok ? " 送信しました" : " \(message)", seconds: ok ? 3 : 6)
        }
        // コピーしたら、ほかの端末へ自動で送る（設定がオンのときだけ。テキストと画像）
        watcher.onCaptured = { [weak self] item in
            guard let self, Settings.syncAutoSend, self.sync.paired else { return }
            if Self.isSendable(item) { self.sync.send([item], quiet: true) }
        }
        panel = PanelController(store: store, paster: paster, sync: sync, front: front) { [weak self] in self?.pairing.show() }
        setupStatusItem()
        sync.start()

        // 古い画像を軽くする。起動の直後は忙しいので少し待ち、そのあとは1時間ごとに確かめる
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.store.recompressOldImages(olderThanDays: Settings.compressAfterDays)
        }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.store.recompressOldImages(olderThanDays: Settings.compressAfterDays)
        }

        // ⇧⌘X でパネルを出す（Carbon のホットキー。アクセシビリティの許可は不要）
        registerHotKey(retry: true)

        // 準備ができる前に届いた URL を処理する
        let waiting = pendingLinks
        pendingLinks = []
        waiting.forEach(handle)
    }

    // MARK: - URL スキーム（clipshelf://open[?kind=image]。Logi Options+ のアクションリングなどから）

    func application(_ application: NSApplication, open urls: [URL]) {
        for link in urls.compactMap(DeepLink.parse) {
            if panel == nil { pendingLinks.append(link) } else { handle(link) }
        }
    }

    /// ほかの端末へ送れるもの（テキストと画像）
    private static func isSendable(_ item: ClipItem) -> Bool {
        item.kind == .text || item.kind == .image
            || (item.kind == .files && item.category == .image && item.paths.count == 1)
    }

    private func handle(_ link: DeepLink) {
        // 開くだけのものは、いつでも動く。貼る・送る・変える・止めるものは、メニューで許可したときだけ
        // （ウェブページなどが勝手に呼べないように）
        if link.needsPermission, !Settings.urlActions {
            flashStatus(symbol: "hand.raised.fill", title: " URL の操作は未許可", seconds: 5)
            NSSound.beep()
            return
        }
        switch link {
        case .open(let kind):
            // 知らない kind は nil（絞り込みなし）
            panel.show(kind: kind.flatMap(ClipCategory.init(rawValue:)))
        case .paste(let index, let kind):
            if !panel.pasteFromHistory(index: index, kind: kind.flatMap(ClipCategory.init(rawValue:))) { NSSound.beep() }
        case .transform(let type):
            guard let t = TextTransform(rawValue: type), panel.transformLatestText(t) else { NSSound.beep(); return }
        case .send:
            guard sync.paired else { pairing.show(); return }
            guard let item = store.items.first, Self.isSendable(item) else { NSSound.beep(); return }
            sync.send([item])
        case .pause(let mode):
            watcher.paused = mode == .toggle ? !watcher.paused : mode == .on
            flashStatus(symbol: watcher.paused ? "pause.circle.fill" : "play.circle.fill",
                        title: watcher.paused ? " 記録を一時停止" : " 記録を再開", seconds: 3)
        }
    }

    @objc private func toggleURLActions() { Settings.urlActions.toggle() }

    private func registerHotKey(retry: Bool) {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.panel.toggle()
        }
        if hotKey != nil { return }
        if retry {
            // 終了させた古いクリップ棚がまだショートカットを持っていることがあるので、少し待ってやり直す
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.registerHotKey(retry: false) }
        } else {
            alert("⇧⌘X を登録できませんでした", "ほかのアプリが同じショートカットを使っている可能性があります。メニューバーのアイコンからも開けます。")
        }
    }

    // MARK: - メニューバー

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "クリップ棚")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "履歴を開く", action: #selector(openPanel), keyEquivalent: "x")
        open.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(autoPasteItem)
        menu.addItem(pauseItem)
        menu.addItem(loginItem)
        menu.addItem(trustItem)
        menu.addItem(.separator())
        menu.addItem(autoSendItem)
        menu.addItem(pairItem)
        menu.addItem(urlActionsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "保存フォルダを開く", action: #selector(openFolder), keyEquivalent: ""))
        for mb in StoragePolicy.choicesMB {
            let it = NSMenuItem(title: StoragePolicy.label(mb: mb), action: #selector(setStorageLimit(_:)), keyEquivalent: "")
            it.tag = mb
            it.target = self
            storageMenu.addItem(it)
        }
        storageItem.submenu = storageMenu
        menu.addItem(storageItem)
        for days in StoragePolicy.compressChoices {
            let it = NSMenuItem(title: StoragePolicy.compressLabel(days: days), action: #selector(setCompressDays(_:)), keyEquivalent: "")
            it.tag = days
            it.target = self
            compressMenu.addItem(it)
        }
        compressItem.submenu = compressMenu
        menu.addItem(compressItem)
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "ピン留め以外の履歴を消去…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "クリップ棚を終了", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        autoPasteItem.state = Settings.autoPaste ? .on : .off
        pauseItem.state = watcher.paused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateItem.isHidden = Self.updateScript == nil
        pairItem.title = "端末のペアリング…（iPhone・Windows・Android）"
        pairItem.state = sync.paired && sync.connected ? .on : .off
        autoSendItem.state = Settings.syncAutoSend ? .on : .off
        urlActionsItem.state = Settings.urlActions ? .on : .off
        let used = ByteCountFormatter.string(fromByteCount: store.totalBytes(), countStyle: .file)
        storageItem.title = "履歴の容量: \(used) ／ 上限 \(StoragePolicy.label(mb: Settings.maxStorageMB))"
        for it in storageMenu.items { it.state = it.tag == Settings.maxStorageMB ? .on : .off }
        var compressTitle = "古い画像を軽くする: \(StoragePolicy.compressLabel(days: Settings.compressAfterDays))"
        if store.recompressedBytes > 0 {
            compressTitle += "（これまでに \(ByteCountFormatter.string(fromByteCount: store.recompressedBytes, countStyle: .file)) 減）"
        }
        compressItem.title = compressTitle
        for it in compressMenu.items { it.state = it.tag == Settings.compressAfterDays ? .on : .off }
        trustItem.title = Paster.trusted ? "自動貼り付け: 許可済み" : "自動貼り付けを許可する（アクセシビリティ）…"
    }

    @objc private func openPanel() { panel.show() }

    /// 容量の上限を変える。下げたときは、超えた分（ピン留め以外の古いもの）をすぐ消す
    @objc private func setStorageLimit(_ sender: NSMenuItem) {
        Settings.maxStorageMB = sender.tag
        store.enforceLimits()
    }

    /// 古い画像を軽くするまでの日数を変える。すぐ片付ける
    @objc private func setCompressDays(_ sender: NSMenuItem) {
        Settings.compressAfterDays = sender.tag
        store.recompressOldImages(olderThanDays: sender.tag)
    }

    @objc private func openPairing() { pairing.show() }

    /// コピーしたら、ほかの端末へ自動で送る。パスワードなども送ってしまうので、最初はオフ
    @objc private func toggleAutoSend() {
        if !Settings.syncAutoSend, !sync.paired {
            pairing.show()  // 先にペアリングが必要
            return
        }
        Settings.syncAutoSend.toggle()
    }

    /// メニューバーのアイコンを一時的に変えて、届いた・送ったことを知らせる
    private func flashStatus(symbol: String, title: String, seconds: Double) {
        guard let button = statusItem.button else { return }
        flashToken += 1
        let token = flashToken
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.flashToken == token, let b = self.statusItem.button else { return }
            let normal = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "クリップ棚")
            normal?.isTemplate = true
            b.image = normal
            b.title = ""
        }
    }

    @objc private func toggleAutoPaste() { Settings.autoPaste.toggle() }

    @objc private func togglePause() { watcher.paused.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("ログイン時の起動を設定できませんでした",
                  "アプリを「アプリケーション」フォルダに入れてから、もう一度試してください。\n\n詳細: \(error.localizedDescription)")
        }
    }

    @objc private func openAccessibility() {
        Paster.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(store.dir) }

    /// install.sh が記録したリポジトリの場所にある update.command
    private static var updateScript: URL? {
        guard let repo = UserDefaults.standard.string(forKey: "repoPath") else { return nil }
        let url = URL(fileURLWithPath: repo).appendingPathComponent("mac-clipboard/scripts/update.command")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// .command ファイルを開くとターミナルで実行される（取得 → ビルド → 入れ替え → 再起動）
    @objc private func update() {
        guard let url = Self.updateScript else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "ピン留め以外の履歴を消去しますか？"
        a.informativeText = "この操作は元に戻せません。"
        a.addButton(withTitle: "消去")
        a.addButton(withTitle: "キャンセル")
        if a.runModal() == .alertFirstButtonReturn { store.clearUnpinned() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// 小さな設定値（UserDefaults に保存）
enum Settings {
    static var autoPaste: Bool {
        get { UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }

    /// 履歴の容量の上限（MB）。0 なら上限なし。超えたらピン留め以外の古いものから消す
    /// 古い画像（PNG）を軽い JPEG にするまでの日数。0 は「しない」
    static var compressAfterDays: Int {
        get { UserDefaults.standard.object(forKey: "compressAfterDays") as? Int ?? StoragePolicy.compressDefaultDays }
        set { UserDefaults.standard.set(newValue, forKey: "compressAfterDays") }
    }

    static var maxStorageMB: Int {
        get { UserDefaults.standard.object(forKey: "maxStorageMB") as? Int ?? StoragePolicy.defaultMB }
        set { UserDefaults.standard.set(newValue, forKey: "maxStorageMB") }
    }

    /// コピーしたら、ほかの端末へ自動で送る（最初はオフ。パスワードマネージャーが「記録しないで」と印を付けたコピーは、そもそも記録されない）
    static var syncAutoSend: Bool {
        get { UserDefaults.standard.object(forKey: "syncAutoSend") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "syncAutoSend") }
    }

    /// URL（clipshelf://paste・send・transform・pause）での操作を許可する（最初はオフ。open は、この設定に関係なく動く）
    static var urlActions: Bool {
        get { UserDefaults.standard.object(forKey: "urlActions") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "urlActions") }
    }

    /// ほかの端末から届いたものを、Mac のクリップボードにも入れる
    static var syncAutoCopy: Bool {
        get { UserDefaults.standard.object(forKey: "syncAutoCopy") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "syncAutoCopy") }
    }
}
