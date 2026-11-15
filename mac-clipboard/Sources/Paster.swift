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

    /// 文字列をそのままクリップボードに入れる（変換結果の貼り付け用）
    func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        watcher.ownChange = pb.changeCount
    }

    /// 複数の項目を1回の貼り付けにまとめる。
    /// テキストだけ → 改行でつなぐ／ファイルだけ → まとめて／画像だけ → まとめて。種類が混ざっていたら false
    func copyTogether(_ items: [ClipItem]) -> Bool {
        let pb = NSPasteboard.general
        let kinds = Set(items.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return false }
        pb.clearContents()
        switch kind {
        case .text:
            pb.setString(items.map(\.text).joined(separator: "\n"), forType: .string)
        case .files:
            pb.writeObjects(items.flatMap(\.paths).map { URL(fileURLWithPath: $0) as NSURL })
        case .image:
            let images = items.compactMap { NSImage(contentsOf: store.imageURL($0.id)) }
            guard !images.isEmpty else { return false }
            pb.writeObjects(images)
        }
        watcher.ownChange = pb.changeCount
        return true
    }

    /// ⌘V を押したことにする（キー入力を作って送る）。アクセシビリティの許可が必要。
    /// キー配置を変えるアプリでも使う技術。
    static func sendPaste() { sendKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand) }

    /// Return キー（順番に貼るときのテキストの区切り）
    static func sendReturn() { sendKey(CGKeyCode(kVK_Return), flags: []) }

    static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
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
