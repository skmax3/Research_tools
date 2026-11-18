import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

/// アプリの入口。Dock には出さず、メニューバーに常駐する（Info.plist の LSUIElement）。
@main
enum MadoWariMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = AppSettings()
    private var mover: WindowMover!
    private var panel: GridPickerController!
    private var barrier: EdgeBarrierController!
    private var toast = Toast()
    private var settingsWindow: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var subs: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // すでに別の窓割りが動いていたら終了させる（Xcode から実行したときと、インストール版が二重に動かないように）
        let me = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other.processIdentifier != me.processIdentifier {
            other.terminate()
        }

        mover = WindowMover(settings: settings)
        mover.onMoved = { [weak self] text, area in
            guard let self, self.settings.showToast else { return }
            self.toast.show(text, in: area)
        }
        panel = GridPickerController(mover: mover)
        panel.onAI = { [weak self] in self?.perform(.ai) }
        barrier = EdgeBarrierController(settings: settings)
        barrier.refresh()
        settingsWindow = SettingsWindowController(settings: settings, actions: SettingsActions(
            apply: { [weak self] p in self?.whenTrusted { self?.mover.apply(p) } },
            capture: { [weak self] screen in self?.capture(screen) ?? [] },
            tryAI: { [weak self] in self?.whenTrusted { self?.mover.pairWithAI() } },
            openAccessibility: { [weak self] in self?.openAccessibility() }
        ))
        setupStatusItem()
        registerHotKeys(retry: true)

        // 設定でキーを変えたら登録し直す。キーを記録している間はショートカットを止める
        settings.$shortcutOverrides.combineLatest(settings.$disabledShortcuts, settings.$isRecordingShortcut)
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.isRecordingShortcut { self.hotKeys = [] } else { self.registerHotKeys(retry: false) }
            }
            .store(in: &subs)

        if !WindowMover.trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.askTrust(first: true) }
        }
    }

    // MARK: - ショートカット

    private func registerHotKeys(retry: Bool) {
        hotKeys = []
        var failed: [String] = []
        for s in Shortcut.all {
            guard let c = settings.combo(for: s) else { continue }
            let action = s.action
            if let hk = HotKey(keyCode: UInt32(c.keyCode), modifiers: UInt32(c.modifiers), action: { [weak self] in
                self?.perform(action)
            }) {
                hotKeys.append(hk)
            } else {
                failed.append(c.label)
            }
        }
        if failed.isEmpty { return }
        if retry {
            // 終了させた古い窓割りがまだショートカットを持っていることがあるので、少し待ってやり直す
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.registerHotKeys(retry: false) }
        } else {
            alert("一部のショートカットを登録できませんでした",
                  "\(failed.joined(separator: "  "))\n\nほかのアプリ（Rectangle など）が同じキーを使っている可能性があります。設定の「ショートカット」でキーを変えられます。")
        }
    }

    private func perform(_ action: WindowAction) {
        if case .toggleBarrier = action {
            settings.edgeBarrier.toggle()
            if let area = WindowMover.mouseArea() {
                toast.show(settings.edgeBarrier ? "境目でカーソルを止める：オン" : "境目でカーソルを止める：オフ", in: area)
            }
            return
        }
        whenTrusted { [self] in
            switch action {
            case .snap(let zones): mover.snap(zones)
            case .half(let top): mover.half(top: top)
            case .display(let step): mover.moveToDisplay(step: step)
            case .undo: mover.undo()
            case .panel: panel.toggle()
            case .ai: mover.pairWithAI()
            case .preset(let i):
                if i < settings.presets.count { mover.apply(settings.presets[i]) } else { NSSound.beep() }
            case .toggleBarrier: break
            case .tidy: mover.tidy()
            }
        }
    }

    /// アクセシビリティが許可されていれば実行。なければ案内を出す
    private func whenTrusted(_ body: () -> Void) {
        if WindowMover.trusted { body() } else { askTrust(first: false) }
    }

    private func askTrust(first: Bool) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = first ? "窓割りへようこそ" : "アクセシビリティの許可が必要です"
        a.informativeText = """
        ほかのアプリのウィンドウを動かすには、「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で \
        MadoWari をオンにしてください。

        許可したあとは、⌃⌥W の配置パネル、⌃⌥← / → などのショートカット、メニューバーのアイコン（縦に割った四角）から使えます。
        """
        a.addButton(withTitle: "許可の設定を開く")
        a.addButton(withTitle: "あとで")
        if a.runModal() == .alertFirstButtonReturn { openAccessibility() }
    }

    private func openAccessibility() {
        WindowMover.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        barrier.refresh()  // 許可されたら、境目の機能も自動で動き出す
    }

    // MARK: - メニューバー

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "窓割り")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// メニューを開くたびに作り直す（プリセットの名前・キー・許可の状態を反映する）
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !WindowMover.trusted {
            menu.addItem(item("⚠️ アクセシビリティを許可する…", #selector(openAccessibilityFromMenu)))
            menu.addItem(.separator())
        }

        if let s = Shortcut.named("panel") {
            let it = item("配置パネルを開く…", #selector(runShortcut(_:)), shortcut: s)
            it.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: nil)
            menu.addItem(it)
        }
        if let s = Shortcut.named("ai") {
            let it = item("AI と並べる（\(settings.aiName)）", #selector(runShortcut(_:)), shortcut: s)
            it.image = ZoneImage.make([AIPairing.zones(aiOnLeft: settings.aiOnLeft, fraction: settings.aiFraction).ai],
                                      colors: [.systemOrange])
            menu.addItem(it)
        }
        menu.addItem(.separator())

        menu.addItem(header("配置プリセット"))
        for (i, p) in settings.presets.enumerated() {
            let shortcut = i < Shortcut.presetKeys.count ? Shortcut.presetKeys[i] : nil
            let it = item(p.name, #selector(applyPreset(_:)), shortcut: shortcut)
            it.tag = i
            it.image = ZoneImage.preset(p)
            menu.addItem(it)
        }
        menu.addItem(item("今の配置をプリセットに保存（マウスのある画面）", #selector(saveCurrentLayout)))
        menu.addItem(item("この画面を整理（手前の \(settings.tidyKeep) 個だけ残す）", #selector(runShortcut(_:)),
                          shortcut: Shortcut.named("tidy")))
        menu.addItem(item("隠したアプリを全部表示", #selector(unhideAll)))
        menu.addItem(.separator())

        let moveMenu = NSMenu()
        for s in Shortcut.windowKeys {
            let it = item(s.title, #selector(runShortcut(_:)), shortcut: s)
            if case .snap(let zones) = s.action, let first = zones.first {
                it.image = ZoneImage.make([first.zone])
            }
            moveMenu.addItem(it)
        }
        let moveItem = NSMenuItem(title: "手前のウィンドウを動かす", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)

        let barrierItem = item("境目でカーソルを止める", #selector(runShortcut(_:)), shortcut: Shortcut.named("barrier"))
        barrierItem.state = settings.edgeBarrier ? .on : .off
        menu.addItem(barrierItem)
        let stageItem = item("ステージマネージャ", #selector(toggleStageManager))
        stageItem.state = StageManager.isOn ? .on : .off
        menu.addItem(stageItem)
        menu.addItem(.separator())

        menu.addItem(item("設定…", #selector(openSettings), key: ","))
        let login = item("ログイン時に起動", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if Self.updateScript != nil {
            menu.addItem(item("最新版にアップデート…", #selector(update)))
        }
        menu.addItem(.separator())
        menu.addItem(item("窓割りを終了", #selector(quit), key: "q"))
    }

    private func header(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    /// shortcut を渡すと、メニューの右側に今のキーを表示する（押せるのはメニューを開いている間だけ。普段はショートカットで直接）
    private func item(_ title: String, _ action: Selector, shortcut: Shortcut? = nil, key: String = "") -> NSMenuItem {
        let combo = shortcut.flatMap { settings.combo(for: $0) }
        let it = NSMenuItem(title: title, action: action, keyEquivalent: combo?.menuKey ?? key)
        if let combo { it.keyEquivalentModifierMask = combo.menuModifiers }
        if let shortcut { it.representedObject = ShortcutBox(shortcut) }
        it.target = self
        return it
    }

    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ShortcutBox else { return }
        // メニューが閉じて、元のアプリが手前に戻ってから動かす
        DispatchQueue.main.async { [weak self] in self?.perform(box.shortcut.action) }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        perform(.preset(sender.tag))
    }

    @objc private func saveCurrentLayout() {
        whenTrusted { [self] in
            // マウスのある画面の配置を保存する（4K モニターでも MacBook 本体でも）
            let target = WindowMover.mouseScreenTarget()
            let slots = capture(target)
            guard !slots.isEmpty else {
                alert("ウィンドウが見つかりませんでした", "保存したい画面にマウスを置き、ウィンドウを並べてから、もう一度試してください。")
                return
            }
            let n = settings.presets.count + 1
            settings.presets.append(Preset(name: "保存した配置 \(n)", slots: slots, screen: target))
            let key = n <= Shortcut.presetKeys.count ? settings.combo(for: Shortcut.presetKeys[n - 1])?.label : nil
            NSApp.activate()
            let a = NSAlert()
            a.messageText = "今の配置を保存しました（\(slots.count) 個のウィンドウ）"
            a.informativeText = key.map { "\($0) で呼び出せます。設定で名前や並べ方を変えられます。" }
                ?? "設定でプリセットの順番を上げると、ショートカットで呼び出せます。"
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "設定を開く")
            if a.runModal() == .alertSecondButtonReturn { settingsWindow.show() }
        }
    }

    private func capture(_ screen: ScreenTarget) -> [Slot] {
        guard WindowMover.trusted else { askTrust(first: false); return [] }
        return mover.captureSlots(screen: screen)
    }

    /// ステージマネージャのオン・オフ（コントロールセンターのボタンと同じ）
    @objc private func toggleStageManager() {
        let on = !StageManager.isOn
        if StageManager.set(on) {
            if let area = WindowMover.mouseArea() { toast.show(on ? "ステージマネージャ：オン" : "ステージマネージャ：オフ", in: area) }
        } else {
            alert("ステージマネージャを切り替えられませんでした", "コントロールセンター（メニューバー右上）の「ステージマネージャ」から切り替えてください。")
        }
    }

    @objc private func unhideAll() { WindowMover.unhideAll() }

    @objc private func openAccessibilityFromMenu() { openAccessibility() }

    @objc private func openSettings() { settingsWindow.show() }

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

    /// install.sh が記録したリポジトリの場所にある update.command
    private static var updateScript: URL? {
        guard let repo = UserDefaults.standard.string(forKey: "repoPath") else { return nil }
        let url = URL(fileURLWithPath: repo).appendingPathComponent("mac-window/scripts/update.command")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// .command ファイルを開くとターミナルで実行される（取得 → ビルド → 入れ替え → 再起動）
    @objc private func update() {
        guard let url = Self.updateScript else { return }
        NSWorkspace.shared.open(url)
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

/// NSMenuItem.representedObject に入れるための入れ物
private final class ShortcutBox {
    let shortcut: Shortcut
    init(_ s: Shortcut) { shortcut = s }
}
