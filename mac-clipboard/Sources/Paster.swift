import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 選んだ項目をクリップボードに戻し、必要なら前面のアプリに ⌘V を送る。
final class Paster {
    private let store: ClipStore
    private let watcher: PasteboardWatcher

    init(store: ClipStore, watcher: PasteboardWatcher) {
        self.store = store
        self.watcher = watcher
    }

    /// - Parameter plain: true なら書式なしテキストとして入れる
    @discardableResult
    func copy(_ item: ClipItem, plain: Bool) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            if !plain, item.hasRTF, let rtf = try? Data(contentsOf: store.rtfURL(item.id)) {
                pb.setData(rtf, forType: .rtf)
            }
            pb.setString(item.text, forType: .string)
        case .image:
            guard let data = try? Data(contentsOf: store.imageURL(item.id)) else { return false }
            pb.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }  // 古いアプリ向け
        case .files:
            let urls = item.paths.map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pb.writeObjects(urls)
        }
        watcher.ownChange = pb.changeCount
        return true
    }

    /// ⌘V を押したことにする（キー入力を作って送る）。アクセシビリティの許可が必要。
    /// キー配置を変えるアプリでも使う技術。
    static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// 「アクセシビリティ」の許可を求めるシステムのダイアログを出す
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
