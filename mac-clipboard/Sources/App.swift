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
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    // メニューの項目（チェック状態を更新するために保持）
    private let autoPasteItem = NSMenuItem(title: "選んだら自動で貼り付け", action: #selector(AppDelegate.toggleAutoPaste), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "記録を一時停止", action: #selector(AppDelegate.togglePause), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(AppDelegate.toggleLogin), keyEquivalent: "")
    private let trustItem = NSMenuItem(title: "自動貼り付けを許可する（アクセシビリティ）…", action: #selector(AppDelegate.openAccessibility), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.load()
        watcher = PasteboardWatcher(store: store)
        watcher.start()
        paster = Paster(store: store, watcher: watcher)
        panel = PanelController(store: store, paster: paster)
        setupStatusItem()

        // ⇧⌘X でパネルを出す（Carbon のホットキー。アクセシビリティの許可は不要）
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.panel.toggle()
        }
        if hotKey == nil {
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
        menu.addItem(NSMenuItem(title: "保存フォルダを開く", action: #selector(openFolder), keyEquivalent: ""))
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
        trustItem.title = Paster.trusted ? "自動貼り付け: 許可済み" : "自動貼り付けを許可する（アクセシビリティ）…"
    }

    @objc private func openPanel() { panel.show() }

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
}
