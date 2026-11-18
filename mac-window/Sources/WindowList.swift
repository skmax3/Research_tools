import AppKit
import ApplicationServices

/// 配置パネルに出す「開いているウィンドウ」1 つ分
struct WindowCandidate: Identifiable {
    let id: String
    let bundleID: String
    let appName: String
    let title: String
    /// nil = ウィンドウが見えないアプリ（別のデスクトップのフルスクリーン・ウィンドウを閉じている など）。
    /// 並べるときに、アプリを手前に出して（開き直して）ウィンドウを探す
    let window: AXUIElement?
    let isFullScreen: Bool
    let isMinimized: Bool
    let isHidden: Bool
    let screenName: String?

    /// 状態の短い説明（一覧に小さく出す）
    var badges: [String] {
        var b: [String] = []
        if window == nil { b.append("別のデスクトップ／ウィンドウなし") }
        if isFullScreen { b.append("フルスクリーン") }
        if isMinimized { b.append("しまってある") }
        if isHidden { b.append("隠れている") }
        if let screenName, window != nil { b.append(screenName) }
        return b
    }
}

enum WindowList {
    /// 開いているウィンドウを、手前にあるアプリから順に集める
    static func candidates() -> [WindowCandidate] {
        // 画面に見えているウィンドウの重なり順（手前から）で、アプリの順番を決める
        var order: [pid_t] = []
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            for w in info {
                guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      !order.contains(pid) else { continue }
                order.append(pid)
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleIdentifier != nil }
            .sorted { a, b in
                func rank(_ x: NSRunningApplication) -> Int {
                    if x.processIdentifier == front { return -1 }
                    return order.firstIndex(of: x.processIdentifier) ?? Int.max
                }
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                return (a.localizedName ?? "").localizedStandardCompare(b.localizedName ?? "") == .orderedAscending
            }

        let screens = WindowMover.screenInfos()
        var withWindows: [WindowCandidate] = []
        var withoutWindows: [WindowCandidate] = []
        for app in apps {
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? bid
            let wins = WindowMover.windowsMainFirst(pid: app.processIdentifier)
            if wins.isEmpty {
                withoutWindows.append(WindowCandidate(id: "app:\(bid)", bundleID: bid, appName: name, title: "",
                                                      window: nil, isFullScreen: false, isMinimized: false,
                                                      isHidden: app.isHidden, screenName: nil))
                continue
            }
            for (i, w) in wins.enumerated() {
                let title = (WindowMover.attribute(w, kAXTitleAttribute) as? String) ?? ""
                var screenName: String?
                if let f = WindowMover.frame(of: w), !screens.isEmpty {
                    screenName = screens[Geometry.bestScreenIndex(for: f, screens: screens.map(\.frame))].name
                }
                withWindows.append(WindowCandidate(id: "\(app.processIdentifier)-\(i)", bundleID: bid, appName: name,
                                                   title: title, window: w,
                                                   isFullScreen: WindowMover.isFullScreen(w),
                                                   isMinimized: WindowMover.isMinimized(w),
                                                   isHidden: app.isHidden, screenName: screenName))
            }
        }
        return withWindows + withoutWindows
    }
}
