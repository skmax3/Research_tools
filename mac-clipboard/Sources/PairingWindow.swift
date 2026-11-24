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

/// 手順の説明（小さい字・左寄せ）
private func guide(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
}

struct PairingView: View {
    @ObservedObject var sync: SyncManager
    @State private var copied = false
    @State private var confirmReset = false
    @State private var quickCopied = false
    @State private var deviceCopied = false

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
                    if let deviceCode = sync.deviceCode {
                        Button(deviceCopied ? "コピーしました" : "Windows・Android アプリ用のコードをコピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceCode, forType: .string)
                            deviceCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { deviceCopied = false }
                        }
                        Text("Windows・Android のアプリの最初の画面に貼り付けます。このコードには高速モードの鍵が入っているので、自分の端末以外には送らないでください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            if let quick = sync.quickURL {
                Divider()
                VStack(spacing: 6) {
                    Text("ショートカットで1タップ送信（iPhone → Mac）").font(.headline)
                    Text("ブラウザを開かずに、背面タップなどで、コピーしたテキスト・画像をそのまま送れます。")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Text(quick)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(6)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(quickCopied ? "コピーしました" : "ショートカット用のアドレスをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(quick, forType: .string)
                        quickCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { quickCopied = false }
                    }
                    DisclosureGroup("① コピーしたものを送るショートカットの作り方") {
                        guide("""
                        1. iPhone の「ショートカット」アプリで ＋ から新規作成
                        2. アクション「クリップボードを取得」を追加
                        3. アクション「URLの内容を取得」を追加し、URL にコピーしたアドレスを貼り付ける
                        4. 「URLの内容を取得」の ＞ を開き、方法を「POST」、リクエスト本文を「ファイル」にして、ファイルに「クリップボード」を選ぶ
                        5. 最後に「通知を表示」を追加し、「送りました」と入力（送れたことが分かります）
                        6. 名前を「Macへ送る」にして完了
                        """)
                    }
                    DisclosureGroup("② 写真・文章を共有メニューから送る（コピー不要）") {
                        guide("""
                        1. 新規作成して、右上の ⓘ →「共有シートに表示」をオン。受け入れる種類は「画像」「テキスト」「URL」だけにする
                        2. アクション「各項目を繰り返す」（名前は OS により違うことがあります）を追加し、入力に「ショートカットの入力」を選ぶ
                        3. 繰り返しの中に「URLの内容を取得」を追加。URL にアドレス、方法「POST」、本文「ファイル」、ファイルに「繰り返しの項目」
                        4. 名前を「Macへ写真を送る」にして完了
                        使うとき: 写真アプリで写真を選ぶ → 共有ボタン →「Macへ写真を送る」（複数枚もまとめて送れます）
                        """)
                    }
                    DisclosureGroup("背面タップ以外の起動のしかた") {
                        guide("""
                        ・ホーム画面: ショートカットの ⓘ →「ホーム画面に追加」。アイコンをタップするだけ
                        ・コントロールセンター: 画面右上から引き下げて長押し →「コントロールを追加」→「ショートカット」（iOS 18 以降）
                        ・アクションボタン（iPhone 15 Pro 以降）: 設定 → アクションボタン →「ショートカット」
                        ・ロック画面のウィジェット、「Hey Siri、Macへ送る」でも起動できます
                        """)
                    }
                    if sync.quickProblem {
                        Text("⚠️ この部屋では高速モードの鍵を登録できませんでした。下の「ペアリングを解除」で、やり直してください。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("注意: この方法だけは、サーバーのプログラムが受け取った内容を、保存する直前に Mac 専用の鍵で暗号化します（保存されるのは暗号文で、Mac だけが読めます。通信は HTTPS）。このアドレスは人に見せないでください。機密は送らない運用をおすすめします。")
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
            if !sync.lastReceived.isEmpty {
                Text(sync.lastReceived).font(.caption).foregroundStyle(.secondary)
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
