import Carbon.HIToolbox
import Foundation

/// どのアプリを使っていても効くショートカット（グローバルホットキー）。
/// Carbon の RegisterEventHotKey を使うので、アクセシビリティの許可はいらない。
/// （キー配置を変えるアプリを作るときは、より低いレベルの CGEventTap を使うことになる）
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: キーの番号（例 kVK_ANSI_X）。キーボードの文字ではなく「物理的な位置」
    ///   - modifiers: cmdKey, shiftKey, optionKey, controlKey の組み合わせ
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        guard HotKey.installHandler() else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4950), id: id) // 'CLIP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

    private static func installHandler() -> Bool {
        if handlerInstalled { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if err == noErr, let action = HotKey.actions[hk.id] {
                DispatchQueue.main.async { action() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
        return handlerInstalled
    }
}
