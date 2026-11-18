import AppKit
import CryptoKit

/// iPhone との同期。中継サーバー（clip-relay）に、端末側で暗号化したデータを置いて受け渡す。
/// 暗号の取り決めは SyncCrypto.swift（iPhone 用 Web アプリ clip-send/ と共通）。
final class SyncManager: ObservableObject {
    static let defaultRelay = "https://fwr-clip.fwrtools.workers.dev"
    static let pairPage = "https://skmax3.github.io/Research_tools/clip-send/"
    /// 中継サーバーの上限（8MB）に余裕を持たせた、送れる大きさ
    static let maxBytes = 7_500_000

    @Published private(set) var paired = false
    /// 中継サーバーと通信できているか
    @Published private(set) var connected = false
    /// 高速モード用の鍵を登録できなかった（別の鍵が先に登録されている）。ペアリングのやり直しが必要
    @Published private(set) var quickProblem = false
    /// 最後に iPhone から受け取った時刻と、サーバーに届いてから受け取るまでの時間（ペアリング画面に表示）
    @Published private(set) var lastReceived = ""

    /// iPhone から新しく届いたとき（件数）
    var onReceived: ((Int) -> Void)?
    /// iPhone へ送ったとき（成功か、表示するメッセージ）
    var onSent: ((Bool, String) -> Void)?

    private let store: ClipStore
    private let paster: Paster
    private var secret: String?
    private var keys: SyncCrypto.Keys?
    /// 高速モード用の秘密鍵。公開鍵だけをサーバーに登録し、秘密鍵はこの Mac の外に出さない
    private var quickKey: P256.KeyAgreement.PrivateKey?
    private var relay = SyncManager.defaultRelay
    private var polling = false
    private var ws: URLSessionWebSocketTask?
    private var reconnectDelay = 2.0
    private var timers: [Timer] = []
    private var started = false

    init(store: ClipStore, paster: Paster) {
        self.store = store
        self.paster = paster
        loadConfig()
    }

    // MARK: - 設定の保存（~/Library/Application Support/ClipShelf/sync.json。本人だけが読める権限）

    private var configURL: URL { store.dir.appendingPathComponent("sync.json") }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let s = obj["secret"], let k = try? SyncCrypto.derive(secret: s) else { return }
        secret = s
        keys = k
        relay = UserDefaults.standard.string(forKey: "relayURL") ?? obj["relay"] ?? Self.defaultRelay
        if let q = obj["quick"], let raw = Data(base64Encoded: q),
           let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            quickKey = key
        } else {
            quickKey = P256.KeyAgreement.PrivateKey()  // 高速モードの追加前にペアリングした場合は、ここで作る
            saveConfig()
        }
        paired = true
    }

    private func saveConfig() {
        guard let secret else {
            try? FileManager.default.removeItem(at: configURL)
            return
        }
        var obj = ["secret": secret, "relay": relay]
        if let quickKey { obj["quick"] = quickKey.rawRepresentation.base64EncodedString() }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private var lastSeq: Int {
        get { UserDefaults.standard.integer(forKey: "syncLastSeq") }
        set { UserDefaults.standard.set(newValue, forKey: "syncLastSeq") }
    }

    // MARK: - ペアリング

    /// QR に入れるアドレス。秘密は # より後ろに入れるので、GitHub などのサーバーには送られない
    var pairingURL: String? {
        guard let secret else { return nil }
        let s = relay.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? relay
        return "\(Self.pairPage)#k=\(secret)&s=\(s)"
    }

    /// 高速モードの送信先。iPhone の「ショートカット」に貼り付ける。部屋ID を含むので、人に見せない
    var quickURL: String? {
        keys.map { "\(relay)/r/\($0.room)/quick" }
    }

    /// 秘密がなければ作る（ペアリング画面を開いたとき）
    func ensurePairing() {
        guard secret == nil else { return }
        let s = SyncCrypto.newSecret()
        guard let k = try? SyncCrypto.derive(secret: s) else { return }
        secret = s
        keys = k
        quickKey = P256.KeyAgreement.PrivateKey()
        lastSeq = 0
        saveConfig()
        paired = true
        start()
    }

    /// ペアリングを解除する。サーバー上の中身も消す。次にペアリング画面を開くと新しい鍵ができる
    func unpair() {
        if let keys { request("/r/\(keys.room)/items", method: "DELETE") { _ in } }
        stop()
        secret = nil
        keys = nil
        quickKey = nil
        quickProblem = false
        lastSeq = 0
        saveConfig()
        paired = false
        connected = false
    }

    // MARK: - 開始・停止

    func start() {
        guard keys != nil, !started else { return }
        started = true
        registerQuickKey()
        connect()
        poll()
        // WebSocket が切れていても届くように、30秒ごとにも確認する
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.poll() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.ws?.send(.string("ping")) { _ in }
        })
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// 高速モード用の公開鍵をサーバーに登録する（1回だけ登録でき、別の鍵での上書きはできない）
    private func registerQuickKey() {
        guard let keys, let quickKey else { return }
        request("/r/\(keys.room)/pub", method: "PUT", body: quickKey.publicKey.x963Representation) { [weak self] result in
            guard let self, case .success(let r) = result else { return }
            switch r.status {
            case 200, 201: self.quickProblem = false
            case 409: self.quickProblem = true
            default: break
            }
        }
    }

    private func stop() {
        started = false
        timers.forEach { $0.invalidate() }
        timers = []
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func didWake() {
        // スリープから戻ったら、つなぎ直して確認する（ネットワークが戻るまで少し待つ）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connect()
            self?.poll()
        }
    }

    // MARK: - 通信

    private struct Response {
        let data: Data
        let status: Int
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         completion: @escaping (Result<Response, Error>) -> Void) {
        guard let url = URL(string: relay + path) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("mac", forHTTPHeaderField: "x-device")
        if let body {
            req.httpBody = body
            req.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        }
        URLSession.shared.dataTask(with: req) { data, resp, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(Response(data: data ?? Data(), status: (resp as? HTTPURLResponse)?.statusCode ?? 0)))
                }
            }
        }.resume()
    }

    /// 中継サーバーに届くか確認する（ペアリング画面用）
    func checkRelay() {
        request("/") { [weak self] result in
            if case .success(let r) = result, r.status == 200 { self?.connected = true } else { self?.connected = false }
        }
    }

    private func connect() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        guard let keys else { return }
        let base = relay.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: base + "/r/\(keys.room)/ws") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        ws = task
        task.resume()
        listen(task)
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.ws === task else { return }
                switch result {
                case .success(let message):
                    self.reconnectDelay = 2
                    if case .string(let s) = message, s != "pong" { self.poll() }  // 新着の知らせ
                    self.listen(task)
                case .failure:
                    self.ws = nil
                    let delay = self.reconnectDelay
                    self.reconnectDelay = min(60, delay * 2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.started, self.ws == nil else { return }
                        self.connect()
                    }
                }
            }
        }
    }

    // MARK: - 受信（iPhone → Mac）

    private struct Incoming {
        let seq: Int
        let device: String
        let inline: Data?
        /// サーバーが受け取った時刻（ミリ秒）
        let sent: Double
    }

    func poll() {
        guard let keys, !polling else { return }
        polling = true
        request("/r/\(keys.room)/items?after=\(lastSeq)") { [weak self] result in
            guard let self else { return }
            guard case .success(let r) = result, r.status == 200,
                  let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
                  let list = obj["items"] as? [[String: Any]] else {
                self.polling = false
                self.connected = false
                return
            }
            let incoming: [Incoming] = list.compactMap { d in
                guard let seq = (d["seq"] as? NSNumber)?.intValue else { return nil }
                let inline = (d["data"] as? String).flatMap { SyncCrypto.fromBase64($0) }
                return Incoming(seq: seq, device: d["dev"] as? String ?? "", inline: inline,
                                sent: (d["t"] as? NSNumber)?.doubleValue ?? 0)
            }
            self.receive(incoming, index: 0, got: 0)
        }
    }

    private func receive(_ list: [Incoming], index: Int, got: Int) {
        guard let keys else { polling = false; return }
        guard index < list.count else {
            polling = false
            connected = true
            if got > 0 { received(got) }
            if list.count >= 50 { poll() }  // まだ続きがあるかもしれない
            return
        }
        let it = list[index]
        func next(_ added: Int) { receive(list, index: index + 1, got: got + added) }

        if it.device == "mac" {  // 自分が置いたもの
            advance(to: it.seq)
            next(0)
            return
        }
        let finish: (Data) -> Void = { [weak self] blob in
            guard let self else { return }
            self.advance(to: it.seq)
            if let opened = self.decrypt(blob), self.accept(opened) {
                self.noteReceived(it)
                next(1)
            } else {
                next(0)
            }
        }
        if let inline = it.inline {
            finish(inline)
        } else {
            request("/r/\(keys.room)/items/\(it.seq)") { [weak self] result in
                guard let self else { return }
                if case .success(let r) = result, r.status == 200 {
                    finish(r.data)
                } else if case .success(let r) = result, r.status == 404 {
                    self.advance(to: it.seq)  // 24時間たって消えた
                    next(0)
                } else {
                    self.polling = false  // 通信に失敗。あとでやり直す（ここまでで止める）
                    self.connected = false
                }
            }
        }
    }

    /// 「最後に受信」の表示を作る。サーバーに届いてから Mac が受け取るまでが短ければ、通知が速く届いている
    private func noteReceived(_ it: Incoming) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var text = "最後に受信: " + formatter.string(from: Date())
        let delay = Date().timeIntervalSince1970 - it.sent / 1000
        if it.sent > 0, delay >= 0, delay < 3600 {
            text += String(format: "（サーバーに届いてから %.1f 秒）", delay)
        }
        lastReceived = text
    }

    /// 先頭の1バイトで方式を見分ける（1: 端末で暗号化、2: 高速モード）
    private func decrypt(_ blob: Data) -> SyncCrypto.Opened? {
        guard let keys, let version = blob.first else { return nil }
        if version == 2 {
            guard let quickKey else { return nil }
            return try? SyncCrypto.openQuick(quickKey, blob)
        }
        return try? SyncCrypto.open(keys, blob)
    }

    private func advance(to seq: Int) {
        if seq > lastSeq { lastSeq = seq }
    }

    /// 復号できたものを履歴に入れる
    private func accept(_ opened: SyncCrypto.Opened) -> Bool {
        let body = opened.body
        switch opened.meta["k"] as? String {
        case "text":
            guard let text = String(data: body, encoding: .utf8), !text.isEmpty else { return false }
            var item = ClipItem(kind: .text)
            item.text = text
            item.app = "iPhone"
            item.appID = "ios"
            item.hash = ClipStore.hash(body)
            store.add(item)
            return true
        case "image":
            guard let img = NSImage(data: body) else { return false }
            let isJPEG = body.starts(with: [0xFF, 0xD8])
            let isPNG = body.starts(with: [0x89, 0x50, 0x4E, 0x47])
            // JPEG・PNG はそのまま保存する（写真を PNG にすると大きくなりすぎる）。HEIC などは JPEG にする
            var data = body
            var ext = isJPEG ? "jpg" : "png"
            if !isJPEG && !isPNG {
                if let jpg = ImageUtil.jpegData(img, maxSide: 4096, quality: 0.9) {
                    data = jpg
                    ext = "jpg"
                } else if let png = ImageUtil.pngData(img) {
                    data = png
                }
            }
            var item = ClipItem(kind: .image)
            (item.width, item.height) = ImageUtil.pixelSize(img)
            item.text = opened.meta["name"] as? String ?? ""
            item.app = "iPhone"
            item.appID = "ios"
            item.hash = ClipStore.hash(body)
            store.add(item, image: data, imageExt: ext, thumb: ImageUtil.thumbnail(img, maxSide: 360))
            return true
        default:
            return false
        }
    }

    private func received(_ count: Int) {
        if Settings.syncAutoCopy, let newest = store.items.first {
            paster.copy(newest, plain: false)
        }
        onReceived?(count)
    }

    // MARK: - 送信（Mac → iPhone）

    private struct Payload {
        let kind: String
        let name: String
        let mime: String
        let body: Data
    }

    private struct SendError: Error {
        let message: String
    }

    /// 選んだ項目を順に iPhone へ送る（テキストと画像。ファイルは1枚の画像のときだけ）
    func send(_ items: [ClipItem]) {
        guard keys != nil else {
            onSent?(false, "先にペアリングしてください")
            return
        }
        sendNext(items, index: 0, sent: 0, firstError: nil)
    }

    private func sendNext(_ items: [ClipItem], index: Int, sent: Int, firstError: String?) {
        guard index < items.count else {
            if sent == 0 {
                onSent?(false, firstError ?? "送れませんでした")
            } else {
                let note = firstError.map { "（一部は送れませんでした: \($0)）" } ?? ""
                onSent?(true, "\(sent)件を iPhone に送りました\(note)")
            }
            return
        }
        let item = items[index]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let prepared = self.prepare(item)
            DispatchQueue.main.async {
                func fail(_ message: String) {
                    self.sendNext(items, index: index + 1, sent: sent, firstError: firstError ?? message)
                }
                switch prepared {
                case .failure(let e):
                    fail(e.message)
                case .success(let p):
                    guard let keys = self.keys,
                          let sealed = try? SyncCrypto.seal(keys, kind: p.kind, name: p.name, mime: p.mime, body: p.body) else {
                        fail("暗号化できませんでした")
                        return
                    }
                    self.request("/r/\(keys.room)/items", method: "POST", body: sealed) { result in
                        if case .success(let r) = result, r.status == 201 {
                            self.connected = true
                            self.sendNext(items, index: index + 1, sent: sent + 1, firstError: firstError)
                        } else {
                            fail("通信できませんでした")
                        }
                    }
                }
            }
        }
    }

    private func prepare(_ item: ClipItem) -> Result<Payload, SendError> {
        switch item.kind {
        case .text:
            let body = Data(item.text.utf8)
            guard body.count <= Self.maxBytes else { return .failure(SendError(message: "テキストが大きすぎます")) }
            return .success(Payload(kind: "text", name: "", mime: "text/plain", body: body))
        case .image:
            return imagePayload(at: store.imageURL(item.id), name: item.text.isEmpty ? "画像" : item.text)
        case .files:
            guard item.paths.count == 1, item.category == .image else {
                return .failure(SendError(message: "テキストと画像以外は送れません"))
            }
            let url = URL(fileURLWithPath: item.paths[0])
            return imagePayload(at: url, name: url.lastPathComponent)
        }
    }

    private func imagePayload(at url: URL, name: String) -> Result<Payload, SendError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(SendError(message: "画像を読み込めません")) }
        let base = (name as NSString).deletingPathExtension
        let isJPEG = data.starts(with: [0xFF, 0xD8])
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if data.count <= Self.maxBytes, isJPEG || isPNG {
            return .success(Payload(kind: "image", name: base + (isJPEG ? ".jpg" : ".png"),
                                    mime: isJPEG ? "image/jpeg" : "image/png", body: data))
        }
        // HEIC や大きすぎる画像は、JPEG にして、収まるまで小さくする
        guard let img = NSImage(data: data) else { return .failure(SendError(message: "画像を読み込めません")) }
        for side in [4096.0, 3072, 2048, 1536] {
            if let jpg = ImageUtil.jpegData(img, maxSide: CGFloat(side), quality: 0.85), jpg.count <= Self.maxBytes {
                return .success(Payload(kind: "image", name: base + ".jpg", mime: "image/jpeg", body: jpg))
            }
        }
        return .failure(SendError(message: "画像が大きすぎます"))
    }
}
