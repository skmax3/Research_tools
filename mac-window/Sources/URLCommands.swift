import AppKit
import ApplicationServices
import os

/// URL スキームまわりのログ（Console.app で subsystem「io.github.skmax3.madowari」を検索）
let urlLog = Logger(subsystem: "io.github.skmax3.madowari", category: "url")

/// 直前に前面だったアプリ（窓割り自身を除く）を、常に覚えておく。
///
/// `madowari://` の URL を開くと窓割りが前面になることがあり、そのままだと「手前のウィンドウ」が窓割り（ウィンドウなし）になってしまう。
/// そこで、URL を受けたら、覚えておいたアプリを前面に戻し、戻ったのを確かめてから操作を実行する。
/// 覚えるのは通常のアプリ（Dock に出るもの）だけ。Logi Options+ のアクションリングのような、前面にならない常駐アプリは覚えない。
final class FrontAppTracker {
    private(set) var last: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private let me = ProcessInfo.processInfo.processIdentifier

    init() {
        // URL で窓割りが起動したときのために、いまの前面アプリも覚えておく
        if let front = NSWorkspace.shared.frontmostApplication { remember(front) }
        // NSWorkspace の通知は、NSWorkspace 専用の NotificationCenter で受ける
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.remember(app) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func remember(_ app: NSRunningApplication) {
        guard app.processIdentifier != me, app.activationPolicy == .regular else { return }
        last = app
    }

    private func isFront(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// 覚えているアプリを前面に戻し、戻ったのを確かめてから body を実行する（最大 1 秒待つ。記録がなければそのまま実行）
    func restoreFront(then body: @escaping () -> Void) {
        guard let prev = last, !prev.isTerminated else {
            urlLog.info("直前のアプリの記録がないので、そのまま実行します")
            body()
            return
        }
        if isFront(prev) {
            settle(body)
            return
        }
        urlLog.info("前面を戻します: \(prev.localizedName ?? "?", privacy: .public)")
        // macOS 14 以降のアプリの前面は「譲り合い」。いま窓割りが前面なら、先に譲ってから相手を前面にする
        NSApp.yieldActivation(to: prev)
        prev.activate(from: NSRunningApplication.current, options: [])
        waitFront(prev, tries: 0, body)
    }

    private func waitFront(_ app: NSRunningApplication, tries: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            if self.isFront(app) { self.settle(body); return }
            if tries == 10 {
                // 0.2 秒たっても戻らなければ、アクセシビリティ経由でも前面にする（ウィンドウを動かすのと同じ許可で使える）
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                             kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            if tries >= 50 {
                urlLog.error("前面を戻せませんでした（\(app.localizedName ?? "?", privacy: .public)）。そのまま実行します")
                body()
                return
            }
            self.waitFront(app, tries: tries + 1, body)
        }
    }

    /// 前面になった直後は、フォーカスのあるウィンドウの情報が少し遅れることがあるので、一呼吸おいてから実行する
    private func settle(_ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { body() }
    }
}
