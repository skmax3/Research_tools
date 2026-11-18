import AppKit
import ApplicationServices

/// アクセシビリティ API（AXUIElement）で、ほかのアプリのウィンドウを動かす。
/// 座標はすべて「左上原点・下向きが +y」（Geometry と同じ）。
final class WindowMover {
    let settings: AppSettings
    /// 「元の位置に戻す」ための記録（新しいものが後ろ）
    private var history: [(window: AXUIElement, frame: CGRect)] = []
    /// 続けて同じキーを押したときの切り替え用
    private var lastSnap: (window: AXUIElement, zones: [NamedZone], index: Int, time: Date)?

    init(settings: AppSettings) { self.settings = settings }

    private var gap: CGFloat { CGFloat(settings.gap) }

    // MARK: - 許可

    static var trusted: Bool { AXIsProcessTrusted() }

    /// システムの「アクセシビリティ」の許可を求めるダイアログを出す
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - 画面

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// 画面ごとの「使える範囲」（メニューバーと Dock を除く）
    static func areas() -> [CGRect] {
        NSScreen.screens.map { Geometry.flip($0.visibleFrame, primaryHeight: primaryHeight) }
    }

    /// 左上原点の枠 → macOS の画面座標（自分のウィンドウを置くとき）
    static func toCocoa(_ r: CGRect) -> CGRect { Geometry.flip(r, primaryHeight: primaryHeight) }

    static func largestArea() -> CGRect? {
        areas().max { $0.width * $0.height < $1.width * $1.height }
    }

    static func mouseArea() -> CGRect? {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) {
            return Geometry.flip(s.visibleFrame, primaryHeight: primaryHeight)
        }
        return areas().first
    }

    func area(for frame: CGRect) -> CGRect? {
        let a = Self.areas()
        guard !a.isEmpty else { return nil }
        return a[Geometry.bestScreenIndex(for: frame, screens: a)]
    }

    // MARK: - ウィンドウの読み書き

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    /// いちばん手前のアプリの、いま操作しているウィンドウ
    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        if let v = attribute(el, kAXFocusedWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        if let v = attribute(el, kAXMainWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        return windows(pid: app.processIdentifier).first
    }

    /// アプリの普通のウィンドウ（パネルやダイアログは除く）
    static func windows(pid: pid_t) -> [AXUIElement] {
        let el = AXUIElementCreateApplication(pid)
        guard let v = attribute(el, kAXWindowsAttribute), let list = v as? [AXUIElement] else { return [] }
        return list.filter { w in
            (attribute(w, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
        }
    }

    /// アプリのメインのウィンドウを先頭にした一覧
    static func windowsMainFirst(pid: pid_t) -> [AXUIElement] {
        var list = windows(pid: pid)
        let el = AXUIElementCreateApplication(pid)
        if let v = attribute(el, kAXMainWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
            let main = v as! AXUIElement
            if let i = list.firstIndex(where: { CFEqual($0, main) }), i > 0 {
                list.insert(list.remove(at: i), at: 0)
            }
        }
        return list
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        (attribute(w, kAXMinimizedAttribute) as? Bool) ?? false
    }

    static func frame(of w: AXUIElement) -> CGRect? {
        guard let pv = attribute(w, kAXPositionAttribute), let sv = attribute(w, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        let app = AXUIElementCreateApplication(pid)
        // Chrome などは、この設定がオンだと動きがなめらかになる代わりに、移動が遅く・不正確になる。動かす間だけオフにする
        let enhanced = (attribute(app, "AXEnhancedUserInterface") as? Bool) ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        var p = r.origin
        var s = r.size
        guard let pos = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) else { return }
        // 大きさ → 位置 → 大きさ の順にすると、画面をまたぐ移動や、小さな画面から大きな画面への移動でも正しく入る
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
    }

    /// ウィンドウを手前に出す（アプリごと手前にする）
    static func raise(_ w: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        NSRunningApplication(processIdentifier: pid)?.unhide()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    /// 記録を残してから動かす
    func move(_ w: AXUIElement, to r: CGRect) {
        if Self.isMinimized(w) {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if let cur = Self.frame(of: w) {
            history.append((w, cur))
            if history.count > 100 { history.removeFirst() }
        }
        Self.setFrame(w, r)
    }

    // MARK: - フルスクリーン

    static func isFullScreen(_ w: AXUIElement) -> Bool {
        (attribute(w, "AXFullScreen") as? Bool) ?? false
    }

    /// フルスクリーン（緑のボタンで全画面にした状態）なら解除して、元の画面に戻ってから body を実行する。
    /// フルスクリーンのままだと、位置や大きさを変えられないため
    func whenWindowed(_ w: AXUIElement, _ body: @escaping () -> Void) {
        guard settings.exitFullScreen, Self.isFullScreen(w) else { body(); return }
        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
        waitWindowed(w, tries: 0, body)
    }

    private func waitWindowed(_ w: AXUIElement, tries: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if Self.isFullScreen(w) && tries < 20 {
                self?.waitWindowed(w, tries: tries + 1, body)
            } else {
                // 解除のアニメーション（画面が横に流れる動き）が終わるのを待ってから動かす
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { body() }
            }
        }
    }

    // MARK: - ショートカットの操作

    /// 動かしたときに呼ぶ（場所の名前と、その画面の範囲）。App.swift が画面に名前を一瞬出す
    var onMoved: ((String, CGRect) -> Void)?

    /// 手前のウィンドウを場所へ。同じキーを続けて押すと zones の順に切り替える
    func snap(_ zones: [NamedZone]) {
        guard let w = Self.focusedWindow() else { NSSound.beep(); return }
        whenWindowed(w) { [weak self] in
            guard let self, let cur = Self.frame(of: w), let area = self.area(for: cur) else { NSSound.beep(); return }
            let frames = zones.map { Geometry.frame(for: $0.zone, in: area, gap: self.gap) }
            var i = Geometry.nextIndex(current: cur, candidates: frames)
            // アプリの最小サイズなどで指定どおりにならなかったときも、続けて押せば次へ進むようにする
            if i == 0, let last = self.lastSnap, CFEqual(last.window, w), last.zones == zones,
               Date().timeIntervalSince(last.time) < 3 {
                i = (last.index + 1) % zones.count
            }
            self.move(w, to: frames[i])
            self.lastSnap = (w, zones, i, Date())
            self.onMoved?(zones[i].title, area)
        }
    }

    /// 今いる列の中で上半分・下半分にする
    func half(top: Bool) {
        guard let w = Self.focusedWindow() else { NSSound.beep(); return }
        whenWindowed(w) { [weak self] in
            guard let self, let cur = Self.frame(of: w), let area = self.area(for: cur) else { NSSound.beep(); return }
            let z = Geometry.verticalHalf(of: Geometry.zone(for: cur, in: area), top: top)
            self.move(w, to: Geometry.frame(for: z, in: area, gap: self.gap))
            self.lastSnap = nil
            self.onMoved?(NamedZone.named(z)?.title ?? (top ? "上半分" : "下半分"), area)
        }
    }

    /// 隣の画面へ、同じ割合のまま移す
    func moveToDisplay(step: Int) {
        guard let w = Self.focusedWindow() else { NSSound.beep(); return }
        whenWindowed(w) { [weak self] in
            guard let self, let cur = Self.frame(of: w) else { NSSound.beep(); return }
            let all = Self.areas().sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
            guard all.count > 1 else { NSSound.beep(); return }
            let i = Geometry.bestScreenIndex(for: cur, screens: all)
            let j = (i + step + all.count) % all.count
            let z = Geometry.zone(for: cur, in: all[i])
            self.move(w, to: Geometry.frame(for: z, in: all[j], gap: self.gap))
            self.lastSnap = nil
            self.onMoved?(step < 0 ? "左の画面へ" : "右の画面へ", all[j])
        }
    }

    /// 最後に動かす前の位置に戻す
    func undo() {
        guard let w = Self.focusedWindow(),
              let i = history.lastIndex(where: { CFEqual($0.window, w) }) else { NSSound.beep(); return }
        let f = history[i].frame
        history.remove(at: i)
        Self.setFrame(w, f)
        lastSnap = nil
        if let area = self.area(for: f) { onMoved?("元の位置に戻しました", area) }
    }

    /// マス目で指定した場所へ（配置パネルから）
    func place(_ w: AXUIElement, zone: Zone, area: CGRect) {
        whenWindowed(w) { [weak self] in
            guard let self else { return }
            self.move(w, to: Geometry.frame(for: zone, in: area, gap: self.gap))
            self.lastSnap = nil
            self.onMoved?(NamedZone.named(zone)?.title ?? "マス目で指定した場所", area)
        }
    }

    // MARK: - AI と並べる

    /// 作業中のウィンドウの横に AI のウィンドウを並べる。AI が起動していなければ起動する
    func pairWithAI() {
        let bid = settings.aiBundleID
        let zones = AIPairing.zones(aiOnLeft: settings.aiOnLeft, fraction: settings.aiFraction)
        let front = NSWorkspace.shared.frontmostApplication
        let isOther = front?.bundleIdentifier != bid && front?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        lastSnap = nil
        guard isOther, let work = Self.focusedWindow() else {
            // 作業中のウィンドウがない（AI が手前・設定画面から）ときは、AI だけ並べる
            guard let area = Self.largestArea() else { return }
            placeAI(bid: bid, zone: zones.ai, area: area, work: nil, attempt: 0)
            return
        }
        whenWindowed(work) { [weak self] in
            guard let self else { return }
            guard let area = Self.frame(of: work).flatMap({ self.area(for: $0) }) ?? Self.largestArea() else { return }
            self.move(work, to: Geometry.frame(for: zones.work, in: area, gap: self.gap))
            self.placeAI(bid: bid, zone: zones.ai, area: area, work: work, attempt: 0)
        }
    }

    private func placeAI(bid: String, zone: Zone, area: CGRect, work: AXUIElement?, attempt: Int) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        let wins = apps.flatMap { Self.windowsMainFirst(pid: $0.processIdentifier) }
        guard let w = wins.first(where: { !Self.isMinimized($0) }) ?? wins.first else {
            // 起動していない・ウィンドウがない → 起動（開き直す）して、ウィンドウが出るのを待つ
            if attempt == 0, !Self.launch(bid) {
                alert("AI のアプリが見つかりません", "設定の「AI と並べる」で、使っている AI のアプリを選んでください。")
                return
            }
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.placeAI(bid: bid, zone: zone, area: area, work: work, attempt: attempt + 1)
                }
            }
            return
        }
        whenWindowed(w) { [weak self] in
            guard let self else { return }
            self.move(w, to: Geometry.frame(for: zone, in: area, gap: self.gap))
            Self.raise(w)
            // AI を見えるようにしたあと、操作は作業中のウィンドウに戻す
            if let work {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.raise(work) }
            }
            self.onMoved?("AI と並べました", area)
        }
    }

    // MARK: - 配置プリセット

    /// プリセットどおりに並べる。起動待ちのアプリ・フルスクリーン解除待ちのウィンドウは、準備ができたら並べる
    func apply(_ preset: Preset) {
        guard let area = preset.screen == .largest ? Self.largestArea() : Self.mouseArea() else { return }
        // 同じアプリが何行かあるときは、そのアプリのウィンドウを上から順に割り当てる
        var count: [String: Int] = [:]
        var jobs: [(slot: Slot, index: Int)] = []
        for s in preset.slots {
            jobs.append((s, count[s.bundleID, default: 0]))
            count[s.bundleID, default: 0] += 1
        }
        if preset.hideOthers {
            let keep = Set(preset.slots.map(\.bundleID))
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                && !keep.contains(app.bundleIdentifier ?? "") && app != NSRunningApplication.current {
                app.hide()
            }
        }
        lastSnap = nil
        place(jobs, area: area, attempt: 0, launched: [])
        onMoved?(preset.name, area)
    }

    private func place(_ jobs: [(slot: Slot, index: Int)], area: CGRect, attempt: Int, launched: Set<String>) {
        var launched = launched
        var waiting: [(slot: Slot, index: Int)] = []
        var placed: [AXUIElement] = []
        for job in jobs {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: job.slot.bundleID)
            let wins = apps.flatMap { Self.windowsMainFirst(pid: $0.processIdentifier) }
            if job.index < wins.count {
                apps.forEach { $0.unhide() }
                let w = wins[job.index]
                if settings.exitFullScreen && Self.isFullScreen(w) {
                    // フルスクリーンを解除して、次の回で並べる
                    AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
                    waiting.append(job)
                    continue
                }
                move(w, to: Geometry.frame(for: job.slot.zone, in: area, gap: gap))
                placed.append(w)
            } else if job.slot.launch {
                if !launched.contains(job.slot.bundleID) {
                    _ = Self.launch(job.slot.bundleID)
                    launched.insert(job.slot.bundleID)
                }
                waiting.append(job)
            }
        }
        // 後ろの行から順に手前に出し、最後に 1 行目のウィンドウがいちばん手前になるようにする
        for (k, w) in placed.reversed().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(k)) { Self.raise(w) }
        }
        if !waiting.isEmpty && attempt < 20 {
            // フルスクリーン解除のアニメーションにも間に合うよう、少し長めに待つ
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.place(waiting, area: area, attempt: attempt + 1, launched: launched)
            }
        }
    }

    /// 今の画面の配置を読み取る（「今の配置をプリセットに保存」）
    func captureSlots(screen: ScreenTarget) -> [Slot] {
        guard let area = screen == .largest ? Self.largestArea() : Self.mouseArea() else { return [] }
        let all = Self.areas()
        var found: [(frame: CGRect, slot: Slot)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app != NSRunningApplication.current {
            guard let bid = app.bundleIdentifier else { continue }
            for w in Self.windows(pid: app.processIdentifier) where !Self.isMinimized(w) {
                guard let f = Self.frame(of: w), all[Geometry.bestScreenIndex(for: f, screens: all)] == area else { continue }
                let slot = Slot(bundleID: bid, appName: app.localizedName ?? bid, zone: Geometry.zone(for: f, in: area))
                found.append((f, slot))
            }
        }
        return found.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }.map(\.slot)
    }

    // MARK: - その他

    /// アプリを起動する（起動済みなら手前に出す。ウィンドウがなければ多くのアプリは新しく開く）
    @discardableResult
    static func launch(_ bid: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        return true
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
