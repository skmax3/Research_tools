import AppKit

/// 「直前に前面だったアプリ」を覚えておく。貼り付け先はこのアプリ。
///
/// ⇧⌘X のときは、パネルが nonactivating なので、使っていたアプリがそのまま前面にいる。
/// 一方、URL（clipshelf://open）で開くと、macOS がクリップ棚を前面にしたり、呼び出し元（Logi のエージェントなど）が
/// 前面になったりして、⌘V が違うアプリに届いてしまう。そこで、貼る前に、覚えておいたアプリを前面に戻す。
final class FrontAppTracker {
    private(set) var target: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        record(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.record(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// 自分以外の、Dock に出る通常のアプリだけを覚える（メニューバーだけのアプリ・裏方のエージェントは貼り付け先にしない）
    private func record(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated else { return }
        target = app
    }

    /// 貼り付け先を前面にして（すでに前面なら何もせず）、できたら body を呼ぶ。
    /// 前面にできなかったら、違うアプリに貼ってしまわないよう body は呼ばず、音を鳴らす。
    /// 貼り付け先を一度も覚えていないとき（起動直後など）は、今のままで body を呼ぶ。
    func restoreTarget(then body: @escaping () -> Void) {
        guard let target, !target.isTerminated else { body(); return }
        let isFront = { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
        if isFront() { body(); return }

        if let url = target.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        } else {
            target.activate()
        }
        // 前面になるのを待つ（最大およそ 0.8 秒）
        func wait(_ left: Int) {
            if isFront() { body(); return }
            if left <= 0 { NSSound.beep(); return }  // 貼れなかった。クリップボードには入っているので、⌘V は自分で押せる
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { wait(left - 1) }
        }
        wait(20)
    }
}
