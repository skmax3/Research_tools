import AppKit
import Combine

/// 画面の境目でカーソルを少し止める（判定は EdgeLogic.swift の EdgeBarrier）。
/// マウスの動き（mouseMoved）をイベントタップで受け取り、境目を越えそうなら境目の手前に戻す。
/// アクセシビリティの許可が必要（ウィンドウを動かすのと同じ許可）。
final class EdgeBarrierController {
    private let settings: AppSettings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var logic = EdgeBarrier()
    /// 画面ごとの範囲（メニューバー・Dock も含む全体。左上原点）
    private var screens: [CGRect] = []
    private var last: CGPoint?
    private var subs: Set<AnyCancellable> = []
    private var retryTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        updateScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.updateScreens() }
        // 設定でオン・オフしたら、すぐに反映する
        settings.$edgeBarrier.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subs)
    }

    var isRunning: Bool { tap != nil }

    /// 設定に合わせて開始・停止する。許可がまだなら、許可されるまで数秒ごとに試す
    func refresh() {
        if settings.edgeBarrier { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        guard WindowMover.trusted else {
            if retryTimer == nil {
                retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    guard let self, WindowMover.trusted else { return }
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    self.refresh()
                }
            }
            return
        }
        // ドラッグ中は止めないが、カーソルの位置を覚えておくために受け取る
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EdgeBarrierController>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        last = nil
        logic.reset()
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func updateScreens() {
        let h = NSScreen.screens.first?.frame.height ?? 0
        screens = NSScreen.screens.map { Geometry.flip($0.frame, primaryHeight: h) }
        logic.reset()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 処理が遅いと macOS がタップを止めるので、止められたら戻す
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let next = event.location
        guard type == .mouseMoved, screens.count > 1 else {
            last = next  // ドラッグなどは止めずに、位置だけ覚える
            return Unmanaged.passUnretained(event)
        }
        // 前の位置：覚えている位置が、この動きの量から逆算した位置と大きく違えば（ほかの方法でカーソルが動いた）、逆算のほうを使う。
        // 古い位置のままだと「境目を越えた」と勘違いして、境目ではない所へカーソルを引き戻してしまう
        let dx = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
        let back = CGPoint(x: next.x - dx, y: next.y - dy)
        var prev = back
        if let last, hypot(last.x - back.x, last.y - back.y) < 40 { prev = last }
        logic.hold = settings.edgeHold
        logic.holdUp = settings.edgeHoldUp
        logic.allSides = settings.edgeAllSides
        if let p = logic.filter(from: prev, to: next, screens: screens, now: Date()) {
            event.location = p
            CGWarpMouseCursorPosition(p)
            // カーソルを動かした直後に、マウスが一瞬効かなくなるのを防ぐ
            CGAssociateMouseAndMouseCursorPosition(1)
            last = p
        } else {
            last = next
        }
        return Unmanaged.passUnretained(event)
    }
}
