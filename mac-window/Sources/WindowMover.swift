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

    /// 場所 z に置くときの枠（ウィンドウ間のすき間と、画面の端の余白を設定から）
    func frameFor(_ z: Zone, in area: CGRect) -> CGRect {
        Geometry.frame(for: z, in: area, gap: gap, edge: CGFloat(settings.edgeGap))
    }

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

    /// つながっている画面の一覧（名前・使える範囲・全体・本体の画面か）
    struct ScreenInfo {
        let name: String
        let area: CGRect      // メニューバーと Dock を除く（左上原点）
        let frame: CGRect     // 画面全体（左上原点）
        let builtin: Bool     // MacBook 本体の画面
    }

    static func screenInfos() -> [ScreenInfo] {
        NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let builtin = CGDisplayIsBuiltin(id) != 0
            return ScreenInfo(name: builtin ? "MacBook 本体" : s.localizedName,
                              area: Geometry.flip(s.visibleFrame, primaryHeight: primaryHeight),
                              frame: Geometry.flip(s.frame, primaryHeight: primaryHeight), builtin: builtin)
        }
    }

    static func builtinArea() -> CGRect? { screenInfos().first(where: \.builtin)?.area }

    /// プリセットの「並べる画面」の範囲（その画面がなければ一番大きい画面）
    static func area(for target: ScreenTarget) -> CGRect? {
        switch target {
        case .largest: return largestArea()
        case .mouse: return mouseArea()
        case .builtin: return builtinArea() ?? largestArea()
        }
    }

    /// マウスのある画面を、プリセットの「並べる画面」で表す
    static func mouseScreenTarget() -> ScreenTarget {
        let p = NSEvent.mouseLocation
        guard let i = NSScreen.screens.firstIndex(where: { NSMouseInRect(p, $0.frame, false) }) else { return .largest }
        let infos = screenInfos()
        guard i < infos.count else { return .largest }
        if infos[i].builtin { return .builtin }
        return largestArea() == infos[i].area ? .largest : .mouse
    }

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

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
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

    // MARK: - アプリの最小サイズ

    static func bundleID(of w: AXUIElement) -> String? {
        NSRunningApplication(processIdentifier: pid(of: w))?.bundleIdentifier
    }

    /// (a) ウィンドウを一瞬だけ小さくして、止まった大きさを最小サイズとして覚える（すぐ元に戻す）。
    /// フルスクリーン・しまってあるウィンドウは測らない
    @discardableResult
    func measureMinSize(_ w: AXUIElement) -> MinSize? {
        guard let bid = Self.bundleID(of: w), !Self.isFullScreen(w), !Self.isMinimized(w),
              let original = Self.frame(of: w) else { return nil }
        var tiny = CGSize(width: 1, height: 1)
        guard let v = AXValueCreate(.cgSize, &tiny) else { return nil }
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
        let shrunk = Self.frame(of: w)
        Self.setFrame(w, original)
        guard let shrunk, shrunk.width > 0, shrunk.height > 0 else { return nil }
        let m = MinSize(w: Double(shrunk.width), h: Double(shrunk.height))
        settings.minSizes[bid] = m
        return m
    }

    /// (b) 置いたあとの実際の大きさから、最小サイズを覚え直す。
    /// 指定より大きく残った → それが最小。指定どおり小さくなった → 覚えていた最小より小さくできる
    func learnMinSize(_ w: AXUIElement, target: CGRect) {
        guard let bid = Self.bundleID(of: w), let actual = Self.frame(of: w) else { return }
        let known = settings.minSizes[bid]
        var m = known ?? MinSize(w: 0, h: 0)
        if actual.width > target.width + 2 { m.w = Double(actual.width) }
        else if Double(target.width) < m.w - 1 { m.w = Double(actual.width) }
        if actual.height > target.height + 2 { m.h = Double(actual.height) }
        else if Double(target.height) < m.h - 1 { m.h = Double(actual.height) }
        guard m != known, known != nil || m.w > 0 || m.h > 0 else { return }
        settings.minSizes[bid] = m
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

    // MARK: - ステージマネージャ

    /// 2 つ以上のアプリを並べるときに、ステージマネージャがオンならオフにしてから body を実行する。
    /// オンのままだと、アプリを手前に出すたびに前のアプリが左の帯にしまわれて、最後の 1 つしか残らないため
    func whenStageManagerOff(appCount: Int, _ body: @escaping () -> Void) {
        guard appCount >= 2, StageManager.isOn else { body(); return }
        guard settings.stageManagerOff else {
            // オフにしない設定のときは、そのまま並べる（最後のアプリしか残らないことがある）
            body()
            return
        }
        if StageManager.set(false) {
            if let area = Self.mouseArea() { onMoved?("ステージマネージャをオフにしました", area) }
            // しまわれていたウィンドウが元の場所に戻るアニメーションを待つ
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { body() }
        } else {
            alert("ステージマネージャをオフにできませんでした",
                  "コントロールセンター（メニューバー右上）の「ステージマネージャ」を押してオフにしてから、もう一度並べてください。")
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
            let frames = zones.map { self.frameFor($0.zone, in: area) }
            var i = Geometry.nextIndex(current: cur, candidates: frames)
            // アプリの最小サイズなどで指定どおりにならなかったときも、続けて押せば次へ進むようにする
            if i == 0, let last = self.lastSnap, CFEqual(last.window, w), last.zones == zones,
               Date().timeIntervalSince(last.time) < 3 {
                i = (last.index + 1) % zones.count
            }
            self.move(w, to: frames[i])
            self.learnMinSize(w, target: frames[i])
            self.keepInside(w, area: area)
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
            self.move(w, to: self.frameFor(z, in: area))
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
            self.move(w, to: self.frameFor(z, in: all[j]))
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
            self.move(w, to: self.frameFor(zone, in: area))
            self.learnMinSize(w, target: self.frameFor(zone, in: area))
            self.keepInside(w, area: area)
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
        // 2 つのアプリを並べるので、ステージマネージャがオンならオフにしてから
        whenStageManagerOff(appCount: 2) { [weak self] in
            self?.pairWork(work, bid: bid, zones: zones)
        }
    }

    private func pairWork(_ work: AXUIElement, bid: String, zones: (ai: Zone, work: Zone)) {
        whenWindowed(work) { [weak self] in
            guard let self else { return }
            guard let area = Self.frame(of: work).flatMap({ self.area(for: $0) }) ?? Self.largestArea() else { return }
            self.move(work, to: self.frameFor(zones.work, in: area))
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
            self.move(w, to: self.frameFor(zone, in: area))
            Self.raise(w)
            // AI を見えるようにしたあと、操作は作業中のウィンドウに戻す
            if let work {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.raise(work) }
            }
            self.onMoved?("AI と並べました", area)
        }
    }

    // MARK: - 配置プリセット・配置パネル

    /// 並べる 1 つ分。window があればそのウィンドウ、なければ bundleID のアプリを起動（開き直し）してそのウィンドウを使う
    struct ArrangeItem {
        var window: AXUIElement?
        var bundleID: String
        var zone: Zone
        var fullScreen = false
    }

    /// プリセットどおりに並べる。デスクトップの指定があれば、先に切り替えてから
    func apply(_ preset: Preset) {
        guard preset.desktop > 0 else { applyNow(preset, desktopOnly: false); return }
        guard Desktops.switchTo(preset.desktop) else {
            alert("デスクトップ \(preset.desktop) へ切り替えられませんでした",
                  "システム設定 → キーボード → キーボードショートカット… → Mission Control で、"
                  + "「デスクトップ \(preset.desktop) へ切り替え」をオンにしてください。\n"
                  + "デスクトップが \(preset.desktop) 個ない場合は、Mission Control（F3）の右上の「＋」で増やします。")
            return
        }
        // 切り替えのアニメーションが終わってから、そのデスクトップのウィンドウを探す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.applyNow(preset, desktopOnly: true)
        }
    }

    /// desktopOnly: 今のデスクトップに見えているウィンドウだけを使う（ほかのデスクトップのウィンドウを使うと、
    /// macOS がそちらへ切り替えてしまうため）。ウィンドウがここにない起動中のアプリは飛ばす
    private func applyNow(_ preset: Preset, desktopOnly: Bool) {
        guard let area = Self.area(for: preset.screen) else { return }
        let map = desktopOnly ? Desktops.windowMap().onScreen : [:]
        // 同じアプリが何行かあるときは、そのアプリのウィンドウを上から順に割り当てる
        var count: [String: Int] = [:]
        var items: [ArrangeItem] = []
        var skipped: [String] = []
        for s in preset.slots {
            let k = count[s.bundleID, default: 0]
            count[s.bundleID, default: 0] += 1
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID)
            var wins = running.flatMap { Self.windowsMainFirst(pid: $0.processIdentifier) }
            if desktopOnly { wins = wins.filter { Desktops.isOnCurrentDesktop($0, onScreen: map) } }
            if k < wins.count {
                items.append(ArrangeItem(window: wins[k], bundleID: s.bundleID, zone: s.zone, fullScreen: s.fullScreen))
            } else if s.launch && (!desktopOnly || running.isEmpty) {
                items.append(ArrangeItem(window: nil, bundleID: s.bundleID, zone: s.zone, fullScreen: s.fullScreen))
            } else if desktopOnly && !running.isEmpty {
                skipped.append(s.appName)
            }
        }
        if items.isEmpty {
            onMoved?(skipped.isEmpty ? "並べるウィンドウがありません" : "このデスクトップにありません：\(skipped.joined(separator: "・"))", area)
            return
        }
        arrange(items, area: area, name: skipped.isEmpty ? preset.name : "\(preset.name)（なし：\(skipped.joined(separator: "・"))）",
                hideOthers: preset.hideOthers)
    }

    /// 並べるアプリ（keep）以外で、並べる画面（area）の今のデスクトップだけにウィンドウがあるアプリを隠す。
    /// 隠す（⌘H）はアプリ全体にかかるので、ほかの画面・ほかのデスクトップにもウィンドウがあるアプリは隠さない
    func hideOthers(keep: Set<String>, area: CGRect) {
        let infos = Self.screenInfos()
        guard let target = infos.firstIndex(where: { $0.area == area }) else { return }
        let frames = infos.map(\.frame)
        let map = Desktops.windowMap()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app != NSRunningApplication.current
            && !keep.contains(app.bundleIdentifier ?? "") {
            let pid = app.processIdentifier
            let minimized = Self.windows(pid: pid).filter(Self.isMinimized).count
            if HideRule.shouldHide(onScreen: map.onScreen[pid] ?? [], screens: frames, target: target,
                                   offScreen: map.offScreen[pid] ?? 0, minimized: minimized) {
                app.hide()
            }
        }
    }

    /// この画面を整理：マウスのある画面の今のデスクトップで、手前から settings.tidyKeep 個のアプリだけ残し、ほかを隠す。
    /// 手前のアプリ（いま使っているもの）は必ず残す。ほかの画面・デスクトップにもウィンドウがあるアプリは隠さない
    func tidy() {
        let infos = Self.screenInfos()
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.firstIndex(where: { NSMouseInRect(mouse, $0.frame, false) }),
              target < infos.count else { return }
        let frames = infos.map(\.frame)
        // 1. 同じアプリのウィンドウが 2 つ以上あれば、1 つのウィンドウのタブにまとめる（Finder など）
        let many = settings.tidyMerge ? Self.appsWithManyWindows(screens: frames, target: target) : []
        guard !many.isEmpty else { hideRest(target: target, merged: []); return }
        let front = NSWorkspace.shared.frontmostApplication
        mergeWindows(of: many, merged: []) { [weak self] merged in
            // まとめ終わったら、もとのアプリを手前に戻してから 2. へ
            front?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.hideRest(target: target, merged: merged) }
        }
    }

    /// その画面の今のデスクトップに、ウィンドウが 2 つ以上見えているアプリ
    private static func appsWithManyWindows(screens: [CGRect], target: Int) -> [pid_t] {
        let me = ProcessInfo.processInfo.processIdentifier
        var order: [pid_t] = []
        for (pid, rects) in Desktops.windowMap().onScreen where pid != me {
            let n = rects.filter { Geometry.bestScreenIndex(for: $0, screens: screens) == target }.count
            if n >= 2 { order.append(pid) }
        }
        return order.filter { pid in
            NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        }
    }

    /// アプリを 1 つずつ手前に出して、メニューの「ウインドウ → すべてのウインドウを結合」を押す。
    /// その項目がないアプリ（Chrome など）は飛ばす
    private func mergeWindows(of pids: [pid_t], merged: [String], _ done: @escaping ([String]) -> Void) {
        guard let pid = pids.first else { done(merged); return }
        let rest = Array(pids.dropFirst())
        guard let app = NSRunningApplication(processIdentifier: pid),
              Self.findMenuItem(pid: pid, matching: MenuTitle.isMergeAllWindows) != nil else {
            mergeWindows(of: rest, merged: merged, done)
            return
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            var merged = merged
            if let item = Self.findMenuItem(pid: pid, matching: MenuTitle.isMergeAllWindows),
               AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                merged.append(app.localizedName ?? "アプリ")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.mergeWindows(of: rest, merged: merged, done) }
        }
    }

    /// アプリのメニューバーから、名前が合う（押せる）項目を探す
    static func findMenuItem(pid: pid_t, matching: (String) -> Bool) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        func children(_ el: AXUIElement) -> [AXUIElement] {
            (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        for top in children(bar as! AXUIElement) {          // 「ファイル」「ウインドウ」など
            for menu in children(top) {                       // そのメニュー
                for item in children(menu) {
                    guard let title = attribute(item, kAXTitleAttribute) as? String, matching(title) else { continue }
                    if (attribute(item, kAXEnabledAttribute) as? Bool) == false { return nil }
                    return item
                }
            }
        }
        return nil
    }

    /// 2. 手前から settings.tidyKeep 個のアプリを残し、ほかを隠す
    private func hideRest(target: Int, merged: [String]) {
        let infos = Self.screenInfos()
        guard target < infos.count else { return }
        let frames = infos.map(\.frame)
        let me = ProcessInfo.processInfo.processIdentifier
        let regular = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != me }
            .map(\.processIdentifier))
        // その画面に見えているアプリを、手前から順に（CGWindowList は手前から並ぶ）
        let map = Desktops.windowMap()
        var order: [pid_t] = []
        // いま使っているアプリは、この画面にあれば必ず残す
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, regular.contains(front),
           (map.onScreen[front] ?? []).contains(where: { Geometry.bestScreenIndex(for: $0, screens: frames) == target }) {
            order.append(front)
        }
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            for w in info {
                guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, regular.contains(pid),
                      !order.contains(pid),
                      let b = w[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 100, r.height > 100,
                      Geometry.bestScreenIndex(for: r, screens: frames) == target else { continue }
                order.append(pid)
            }
        }
        let hideable = Set(order.filter { pid in
            HideRule.shouldHide(onScreen: map.onScreen[pid] ?? [], screens: frames, target: target,
                                offScreen: map.offScreen[pid] ?? 0,
                                minimized: Self.windows(pid: pid).filter(Self.isMinimized).count)
        })
        let hide = TidyRule.toHide(order: order, hideable: hideable, keep: settings.tidyKeep)
        for pid in hide { NSRunningApplication(processIdentifier: pid)?.hide() }
        var parts: [String] = []
        if !merged.isEmpty { parts.append("\(merged.joined(separator: "・")) のウィンドウをタブにまとめました") }
        if !hide.isEmpty { parts.append("\(hide.count) 個のアプリを隠しました") }
        onMoved?(parts.isEmpty ? "整理するものはありません" : parts.joined(separator: "\n"), infos[target].area)
    }

    /// 隠れているアプリを全部表示する（メニュー）
    static func unhideAll() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.isHidden {
            app.unhide()
        }
    }

    /// まとめて並べる。後ろの行から 1 つずつ並べて手前に出すので、最後に 1 行目がいちばん手前になる。
    /// フルスクリーンの解除・アプリの起動を待つことがあるので、1 つ終わってから次へ進む
    func arrange(_ items: [ArrangeItem], area: CGRect, name: String, hideOthers: Bool = false) {
        lastSnap = nil
        guard !items.isEmpty else { NSSound.beep(); return }
        if hideOthers { self.hideOthers(keep: Set(items.map(\.bundleID)), area: area) }
        let apps = Set(items.map { $0.window.map { "pid:\(Self.pid(of: $0))" } ?? $0.bundleID })
        whenStageManagerOff(appCount: apps.count) { [weak self] in
            self?.arrangeNow(items, area: area, name: name)
        }
    }

    private func arrangeNow(_ items: [ArrangeItem], area: CGRect, name: String) {
        var used: [AXUIElement] = items.compactMap(\.window)
        var queue = Array(items.reversed())
        var toFullScreen: [AXUIElement] = []
        var placed: [(window: AXUIElement, zone: Zone)] = []

        func next() {
            guard !queue.isEmpty else {
                // アプリの最小サイズで指定より大きく残ったウィンドウがあれば、ほかを細くして重ならないようにする
                refit(placed, area: area, current: placed.map(\.zone),
                      minW: placed.map { _ in 0 }, minH: placed.map { _ in 0 }, round: 0) { [weak self] in
                    self?.finishArrange(toFullScreen, area: area, name: name)
                }
                return
            }
            let item = queue.removeFirst()
            resolve(item, used: used, attempt: 0) { [weak self] w in
                guard let self else { return }
                guard let w else { next(); return }
                used.append(w)
                NSRunningApplication(processIdentifier: Self.pid(of: w))?.unhide()
                self.whenWindowed(w) {
                    self.move(w, to: self.frameFor(item.zone, in: area))
                    Self.raise(w)
                    if item.fullScreen { toFullScreen.append(w) } else { placed.append((w, item.zone)) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { next() }
                }
            }
        }
        next()
    }

    private func finishArrange(_ toFullScreen: [AXUIElement], area: CGRect, name: String) {
        // フルスクリーンにする指定のウィンドウは、並べ終わってから
        for (k, w) in toFullScreen.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + 0.8 * Double(k)) {
                AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanTrue)
            }
        }
        onMoved?(name, area)
    }

    /// 並べたあと、実際の大きさを読んで、指定より大きく残ったもの（アプリの最小サイズ）があれば並び直す。
    /// 並び直すと別のウィンドウが最小サイズに当たることがあるので、最大 3 回くり返す
    private func refit(_ placed: [(window: AXUIElement, zone: Zone)], area: CGRect, current: [Zone],
                       minW: [Double], minH: [Double], round: Int, _ done: @escaping () -> Void) {
        guard placed.count >= 2, area.width > 0, area.height > 0 else { done(); return }
        var minW = minW, minH = minH
        var grew = false
        for (i, p) in placed.enumerated() {
            guard let actual = Self.frame(of: p.window) else { continue }
            let target = frameFor(current[i], in: area)
            learnMinSize(p.window, target: target)
            if actual.width > target.width + 2 {
                let need = current[i].w + Double((actual.width - target.width) / area.width)
                if need > minW[i] + 1e-4 { minW[i] = need; grew = true }
            }
            if actual.height > target.height + 2 {
                let need = current[i].h + Double((actual.height - target.height) / area.height)
                if need > minH[i] + 1e-4 { minH[i] = need; grew = true }
            }
        }
        guard grew, round < 3 else {
            for p in placed { keepInside(p.window, area: area) }
            done()
            return
        }
        let zones = Fit.refit(zones: placed.map(\.zone), minW: minW, minH: minH)
        for (i, p) in placed.enumerated() { Self.setFrame(p.window, frameFor(zones[i], in: area)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refit(placed, area: area, current: zones, minW: minW, minH: minH, round: round + 1, done)
        }
    }

    /// 画面からはみ出したウィンドウ（アプリの最小サイズで大きく残ったとき）を、画面の中へずらす
    func keepInside(_ w: AXUIElement, area: CGRect) {
        guard let f = Self.frame(of: w) else { return }
        var o = f.origin
        if f.maxX > area.maxX { o.x = max(area.minX, area.maxX - f.width) }
        if f.maxY > area.maxY { o.y = max(area.minY, area.maxY - f.height) }
        guard o != f.origin else { return }
        var p = o
        if let pos = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos) }
    }

    /// 並べるウィンドウを決める。アプリだけ指定のときは起動（開き直し）して、まだ使っていないウィンドウが出るのを待つ
    private func resolve(_ item: ArrangeItem, used: [AXUIElement], attempt: Int, _ done: @escaping (AXUIElement?) -> Void) {
        if let w = item.window { done(w); return }
        let wins = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID)
            .flatMap { Self.windowsMainFirst(pid: $0.processIdentifier) }
        if let w = wins.first(where: { c in !used.contains(where: { CFEqual($0, c) }) }) {
            done(w)
            return
        }
        if attempt == 0 { _ = Self.launch(item.bundleID) }
        guard attempt < 20 else { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resolve(item, used: used, attempt: attempt + 1, done)
        }
    }

    static func pid(of w: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        return pid
    }

    /// 今の画面の配置を読み取る（「今の配置をプリセットに保存」）
    func captureSlots(screen: ScreenTarget) -> [Slot] {
        guard let area = Self.area(for: screen) else { return [] }
        let all = Self.areas()
        var found: [(frame: CGRect, slot: Slot)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app != NSRunningApplication.current {
            guard let bid = app.bundleIdentifier else { continue }
            for w in Self.windows(pid: app.processIdentifier) where !Self.isMinimized(w) {
                guard let f = Self.frame(of: w), all[Geometry.bestScreenIndex(for: f, screens: all)] == area else { continue }
                let slot = Slot(bundleID: bid, appName: app.localizedName ?? bid, zone: Geometry.zone(for: f, in: area),
                                fullScreen: Self.isFullScreen(w))
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
