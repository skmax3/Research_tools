import AppKit
import Carbon.HIToolbox

/// デスクトップ（操作スペース・Mission Control の上に並ぶもの）まわり。
///
/// macOS には、ほかのアプリがデスクトップを作る・ウィンドウを別のデスクトップへ移す公開の方法がない
/// （macOS 14.5 以降は非公開の方法も止められている）。窓割りができるのは次の 2 つ:
/// - 「デスクトップ N へ切り替え」のキー（システム設定のキーボードショートカット）を押して切り替える
/// - 今のデスクトップに見えているウィンドウを調べる（CGWindowList）
enum Desktops {
    /// システム設定の「デスクトップ N へ切り替え」（com.apple.symbolichotkeys の 118〜126）
    private static func hotKey(_ n: Int) -> (enabled: Bool, keyCode: CGKeyCode, flags: CGEventFlags)? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any],
              let entry = all[String(117 + n)] as? [String: Any] else { return nil }
        let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? false)
        guard let value = entry["value"] as? [String: Any], let params = value["parameters"] as? [NSNumber],
              params.count >= 3 else { return (enabled: enabled, keyCode: defaultKey(n), flags: CGEventFlags.maskControl) }
        return (enabled: enabled, keyCode: CGKeyCode(params[1].intValue), flags: CGEventFlags(rawValue: UInt64(params[2].intValue)))
    }

    private static func defaultKey(_ n: Int) -> CGKeyCode {
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return CGKeyCode(keys[max(0, min(n - 1, 8))])
    }

    /// 切り替えのキーがオフになっているか（オフなら案内を出す）
    static func shortcutDisabled(_ n: Int) -> Bool { hotKey(n).map { !$0.enabled } ?? false }

    /// デスクトップ n（1〜9）へ切り替える。キーがオフなら false
    @discardableResult
    static func switchTo(_ n: Int) -> Bool {
        guard (1...9).contains(n) else { return false }
        let k = hotKey(n) ?? (enabled: true, keyCode: defaultKey(n), flags: CGEventFlags.maskControl)  // 設定がまだなければ、初期の ⌃数字 を試す
        guard k.enabled else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: k.keyCode, keyDown: down)
            e?.flags = k.flags
            e?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// 今のデスクトップに見えているウィンドウ（アプリの pid → 枠。左上原点）と、見えていないウィンドウの数
    static func windowMap() -> (onScreen: [pid_t: [CGRect]], offScreen: [pid_t: Int]) {
        var on: [pid_t: [CGRect]] = [:]
        var off: [pid_t: Int] = [:]
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return (on, off) }
        for w in info {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 100, r.height > 100 else { continue }
            if (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true {
                on[pid, default: []].append(r)
            } else {
                off[pid, default: 0] += 1
            }
        }
        return (on, off)
    }

    /// ウィンドウが今のデスクトップに見えているか（アクセシビリティの枠と、見えているウィンドウの枠を比べる）
    static func isOnCurrentDesktop(_ w: AXUIElement, onScreen: [pid_t: [CGRect]]) -> Bool {
        guard let f = WindowMover.frame(of: w) else { return false }
        return (onScreen[WindowMover.pid(of: w)] ?? []).contains { Geometry.approxEqual($0, f, tol: 4) }
    }
}
