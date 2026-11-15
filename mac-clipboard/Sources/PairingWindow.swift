import AppKit
import CoreImage
import SwiftUI

/// QR コードの画像を作る（CoreImage の標準機能）
enum QRCode {
    static func image(_ text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(size / output.extent.width))  // 整数倍にして、にじまないようにする
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// 「iPhone とペアリング」の画面
final class PairingWindowController {
    private var window: NSWindow?
    private let sync: SyncManager

    init(sync: SyncManager) {
        self.sync = sync
    }

    func show() {
        sync.ensurePairing()
        sync.checkRelay()
        if window == nil {
            let host = NSHostingController(rootView: PairingView(sync: sync))
            let w = NSWindow(contentViewController: host)
            w.title = "iPhone とペアリング"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PairingView: View {
    @ObservedObject var sync: SyncManager
    @State private var copied = false
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 14) {
            Text("iPhone とペアリング").font(.title2.bold())

            if let url = sync.pairingURL {
                if let qr = QRCode.image(url, size: 240) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("iPhone のカメラで QR を読み取り、表示されたリンクを開いてください。\n「ペアリングしました」と出れば完了です。")
                    .font(.callout)
                    .multilineTextAlignment(.center)

                VStack(spacing: 6) {
                    Button(copied ? "コピーしました" : "ペアリングコードをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    Text("ホーム画面に追加したアプリで使うときは、このコードを iPhone の最初の画面に貼り付けます（メモや自分宛てのメッセージなどで iPhone に送れます）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Divider()

            HStack(spacing: 6) {
                Circle().fill(sync.connected ? Color.green : Color.orange).frame(width: 9, height: 9)
                Text(sync.connected ? "中継サーバーに接続できています" : "中継サーバーに接続できていません")
                    .font(.callout)
            }

            Toggle("iPhone から届いたら、Mac のクリップボードにも入れる", isOn: Binding(
                get: { Settings.syncAutoCopy },
                set: { Settings.syncAutoCopy = $0 }
            ))
            .font(.callout)

            Text("写真や文章は、端末で暗号化してから送ります。中継サーバーは鍵を持たないので、中身は読めません（24時間で自動的に消えます）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("ペアリングを解除する（鍵を作り直す）", role: .destructive) { confirmReset = true }
                .font(.callout)
        }
        .padding(22)
        .frame(width: 400)
        .confirmationDialog("ペアリングを解除しますか？", isPresented: $confirmReset) {
            Button("解除して、新しい QR を作る", role: .destructive) {
                sync.unpair()
                sync.ensurePairing()
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("今の iPhone とのペアリングは使えなくなります。新しい QR を、iPhone で読み取り直してください。")
        }
    }
}
