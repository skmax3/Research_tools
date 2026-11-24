import io.github.skmax3.clipshelf.core.MiniJson;
import io.github.skmax3.clipshelf.core.PairCode;
import io.github.skmax3.clipshelf.core.RelayClient;
import io.github.skmax3.clipshelf.core.SyncCrypto;
import io.github.skmax3.clipshelf.core.WebSocketClient;

import java.io.OutputStream;
import java.math.BigInteger;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.ECPrivateKey;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Android アプリの「Java だけで書いた部分」（暗号・ペアリングコード・中継サーバーとの通信）のテスト。
 *
 * 使い方:
 *   javac -d /tmp/out ../app/src/main/java/io/github/skmax3/clipshelf/core/*.java CoreTest.java
 *   java -cp /tmp/out CoreTest                              … 固定の値のテスト（GitHub Actions で実行）
 *   java -cp /tmp/out CoreTest --online http://127.0.0.1:8799 … ローカルの中継サーバー（npx wrangler dev --local --port 8799）での通信テスト
 *
 * 固定の値は、iPhone 用ページ（clip-send/test/crypto-vector.mjs）と、サーバー（clip-relay/test/quick.mjs）が作ったもの。
 * Mac（Swift）・Windows（C#）のテストと同じ値で、どの実装でも同じ結果になることを確かめる。
 */
public class CoreTest {
    static int failed = 0;

    static void check(String name, Object got, Object want) {
        if (String.valueOf(got).equals(String.valueOf(want))) {
            System.out.println("PASS " + name);
        } else {
            failed++;
            System.out.println("FAIL " + name + "\n  got:  " + got + "\n  want: " + want);
        }
    }

    static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x));
        return s.toString();
    }

    static byte[] fromHex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    interface Action {
        void run() throws Exception;
    }

    static boolean throwsError(Action a) {
        try {
            a.run();
            return false;
        } catch (Exception e) {
            return true;
        }
    }

    static byte[] utf8(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        offline();
        if (args.length >= 2 && args[0].equals("--online")) online(args[1]);
        if (failed > 0) {
            System.out.println(failed + " 件失敗");
            System.exit(1);
        }
        System.out.println("すべて成功");
    }

    // ---------------------------------------------------------------- 固定の値のテスト

    static void offline() throws Exception {
        // ---- 端末で暗号化する方式（方式 1）----
        String vecSecret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
        String vecRoom = "yPw6bue3EVsxQB8TPGB-HA";
        String vecMeta = "{\"k\":\"text\",\"name\":\"\",\"mime\":\"text/plain\"}";
        String vecBody = "こんにちは, clip!";
        String vecNonceHex = "000102030405060708090a0b";
        String vecSealedHex = "01000102030405060708090a0b7715f50bcb4cd950d51bc4cdda6bd8f671145bf5a1efd5a27a1f2991c52b183940310f6d6bdf7fbbd1ead04782c961d91c8e7215a0805ac880c782d5e23ab38677bdb2f863b8c33e4f067c0818ed497221987d2f";

        SyncCrypto.Keys keys = SyncCrypto.derive(vecSecret);
        check("部屋ID", keys.room, vecRoom);
        byte[] sealed = SyncCrypto.seal(keys, utf8(vecMeta), utf8(vecBody), fromHex(vecNonceHex));
        check("暗号文が Web 版・Mac 版・Windows 版と一致", hex(sealed), vecSealedHex);

        SyncCrypto.Opened opened = SyncCrypto.open(keys, fromHex(vecSealedHex));
        check("Web 版の暗号文を復号（本体）", new String(opened.body, StandardCharsets.UTF_8), vecBody);
        check("Web 版の暗号文を復号（種類）", opened.kind, "text");

        byte[] a = SyncCrypto.seal(keys, "image", "a.jpg", "image/jpeg", new byte[] {1, 2, 3, (byte) 255});
        byte[] b = SyncCrypto.seal(keys, "image", "a.jpg", "image/jpeg", new byte[] {1, 2, 3, (byte) 255});
        check("nonce は毎回違う", Arrays.equals(a, b), false);
        SyncCrypto.Opened back = SyncCrypto.open(keys, a);
        check("往復（本体）", hex(back.body), "010203ff");
        check("往復（名前）", back.name, "a.jpg");
        check("往復（形式）", back.mime, "image/jpeg");
        SyncCrypto.Opened special = SyncCrypto.open(keys, SyncCrypto.seal(keys, "text", "引用\"符\\と改行\n", "text/plain", utf8("x")));
        check("名前に特殊な文字があっても往復できる", special.name, "引用\"符\\と改行\n");

        byte[] tampered = fromHex(vecSealedHex);
        tampered[tampered.length - 1] ^= 1;
        check("改ざんは復号できない", throwsError(() -> SyncCrypto.open(keys, tampered)), true);
        SyncCrypto.Keys other = SyncCrypto.derive(SyncCrypto.newSecret());
        check("別の鍵では復号できない", throwsError(() -> SyncCrypto.open(other, fromHex(vecSealedHex))), true);
        check("別の秘密は別の部屋ID", other.room.equals(keys.room), false);
        check("部屋IDは22文字", keys.room.length(), 22);
        check("短い秘密は拒否", throwsError(() -> SyncCrypto.derive("short")), true);

        byte[] big = new byte[3 * 1024 * 1024 + 5];
        for (int i = 0; i < big.length; i++) big[i] = (byte) (i * 7);
        check("3MBの往復", Arrays.equals(SyncCrypto.open(keys, SyncCrypto.seal(keys, "image", "big.png", "image/png", big)).body, big), true);

        // ---- 高速モード（方式 2。サーバーのコードが作った暗号文）----
        String quickPrivateHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
        String quickPublicHex = "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354";
        String quickBody = "ショートカット, quick!";
        String quickSealedHex = "02045142f48a7c80caf47544a428fc57d272a6c678ad5e93ffcba36666a99639e51dd1bdb6fb598144567a2657e8ff3619fbaa0cd2a040c19ab22af910c705a757ba32333435363738393a3b3c3dafe2cdb9a9657b9efb6f60e5d0be037c5a235c218b07897ef820877373b1c402aa78749039c8e032ffd4057a61316f031e1579d2b31fc6b42a4c544403be5582d43be73117746ed28afef4306d031f17d75de7fc475332a76b2fdb";

        byte[] quickKey = fromHex(quickPublicHex + quickPrivateHex);  // 04‖X‖Y‖D
        SyncCrypto.Opened q = SyncCrypto.openQuick(quickKey, fromHex(quickSealedHex));
        check("quick: サーバーが作った暗号文を復号（本体）", new String(q.body, StandardCharsets.UTF_8), quickBody);
        check("quick: 復号（種類）", q.kind, "text");
        byte[] quickBad = fromHex(quickSealedHex);
        quickBad[quickBad.length - 1] ^= 1;
        check("quick: 改ざんは復号できない", throwsError(() -> SyncCrypto.openQuick(quickKey, quickBad)), true);
        check("quick: 別の鍵では復号できない", throwsError(() -> SyncCrypto.openQuick(newQuickKey()[0], fromHex(quickSealedHex))), true);
        check("quick: 形式の違う鍵は拒否", throwsError(() -> SyncCrypto.openQuick(new byte[10], fromHex(quickSealedHex))), true);

        // ---- ペアリングコード ----
        String quickCode = SyncCrypto.base64Url(quickKey);
        PairCode full = PairCode.parse("k=" + vecSecret + "&s=https%3A%2F%2Fexample.workers.dev&q=" + quickCode);
        check("コード: 秘密", full.secret, vecSecret);
        check("コード: 中継サーバー", full.relay, "https://example.workers.dev");
        check("コード: 高速モードの鍵", full.quick, quickCode);
        PairCode url = PairCode.parse("https://skmax3.github.io/Research_tools/clip-send/#k=" + vecSecret + "&s=https%3A%2F%2Ffwr-clip.fwrtools.workers.dev");
        check("iPhone 用コード（アドレス全体）: 秘密", url.secret, vecSecret);
        check("iPhone 用コード: 高速モードの鍵なし", url.quick, "");
        check("秘密だけでも読める（中継は既定）", PairCode.parse("  " + vecSecret + "\n").relay, PairCode.DEFAULT_RELAY);
        check("ホスト名だけの中継は https を補う", PairCode.parse("k=" + vecSecret + "&s=relay.example.com").relay, "https://relay.example.com");
        check("形の違う高速モードの鍵は無視する", PairCode.parse("k=" + vecSecret + "&q=AAAA").quick, "");
        check("でたらめは拒否", PairCode.parse("でたらめ") == null, true);
        check("空は拒否", PairCode.parse("") == null && PairCode.parse(null) == null, true);
        check("短い秘密は拒否", PairCode.parse("k=short") == null, true);

        // ---- 小さな JSON ----
        Map<String, Object> json = MiniJson.parseObject("{\"items\":[{\"seq\":3,\"t\":1.5e3,\"dev\":\"mac\",\"data\":\"AQID\"}],\"now\":1,\"ok\":true,\"n\":null,\"s\":\"a\\u3042\\n\\\"\"}");
        check("JSON: 入れ子", ((Map<?, ?>) ((List<?>) json.get("items")).get(0)).get("dev"), "mac");
        check("JSON: 数値", ((Map<?, ?>) ((List<?>) json.get("items")).get(0)).get("t"), 1500.0);
        check("JSON: 真偽値・null", json.get("ok") + "," + json.get("n"), "true,null");
        check("JSON: 文字列のエスケープ", json.get("s"), "aあ\n\"");
        check("JSON: 壊れたものは拒否", throwsError(() -> MiniJson.parse("{\"a\":")), true);
        check("JSON: 余計な文字は拒否", throwsError(() -> MiniJson.parse("{} x")), true);
    }

    /** テスト用: P-256 の鍵を作り、04‖X‖Y‖D の 97 バイトと、公開鍵だけの 65 バイトを返す */
    static byte[][] newQuickKey() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        KeyPair pair = generator.generateKeyPair();
        ECPublicKey pub = (ECPublicKey) pair.getPublic();
        ECPrivateKey priv = (ECPrivateKey) pair.getPrivate();
        byte[] x = fixed(pub.getW().getAffineX(), 32);
        byte[] y = fixed(pub.getW().getAffineY(), 32);
        byte[] d = fixed(priv.getS(), 32);
        byte[] publicKey = new byte[65];
        publicKey[0] = 4;
        System.arraycopy(x, 0, publicKey, 1, 32);
        System.arraycopy(y, 0, publicKey, 33, 32);
        byte[] full = new byte[97];
        System.arraycopy(publicKey, 0, full, 0, 65);
        System.arraycopy(d, 0, full, 65, 32);
        return new byte[][] {full, publicKey};
    }

    static byte[] fixed(BigInteger v, int length) {
        byte[] raw = v.toByteArray();
        byte[] out = new byte[length];
        int copy = Math.min(raw.length, length);
        System.arraycopy(raw, raw.length - copy, out, length - copy, copy);
        return out;
    }

    // ---------------------------------------------------------------- 中継サーバーとの通信（ローカル）

    static int http(String method, String url, byte[] body) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setRequestMethod(method);
        if (body != null) {
            c.setDoOutput(true);
            try (OutputStream out = c.getOutputStream()) {
                out.write(body);
            }
        }
        int code = c.getResponseCode();
        c.disconnect();
        return code;
    }

    static void online(String base) throws Exception {
        System.out.println("--- 中継サーバー " + base + " ---");
        String secret = SyncCrypto.newSecret();
        SyncCrypto.Keys keys = SyncCrypto.derive(secret);
        RelayClient relay = new RelayClient(base, keys.room, "android-test");

        // 空の部屋
        check("最初は空", relay.list(0).size(), 0);

        // WebSocket: つないで、新着の知らせを受け取る。ping には pong が返る
        LinkedBlockingQueue<String> messages = new LinkedBlockingQueue<>();
        WebSocketClient ws = new WebSocketClient(relay.webSocketUrl(), messages::add);
        ws.connect(10_000);
        Thread reader = new Thread(() -> {
            try {
                ws.readLoop();
            } catch (Exception e) {
                // 閉じたとき
            }
        });
        reader.setDaemon(true);
        reader.start();
        ws.sendText("ping");
        check("ws: ping に pong が返る", messages.poll(5, TimeUnit.SECONDS), "pong");

        // 送って、一覧で見える。Web 版・Mac 版と同じ形式の暗号文
        byte[] first = SyncCrypto.seal(keys, "text", "", "text/plain", utf8("Androidから"));
        check("置ける", relay.post(first), true);
        String notice = messages.poll(5, TimeUnit.SECONDS);
        check("ws: 新着の知らせが届く", notice != null && notice.contains("\"dev\":\"android-test\""), true);

        List<RelayClient.Item> items = relay.list(0);
        check("一覧に出る", items.size() + "," + items.get(0).device, "1,android-test");
        SyncCrypto.Opened o = SyncCrypto.open(keys, items.get(0).inline != null ? items.get(0).inline : relay.get(items.get(0).seq));
        check("読み戻せる（小さい項目は一覧に中身が入る）", new String(o.body, StandardCharsets.UTF_8), "Androidから");

        // 大きい項目（3MB）は、個別に取る
        byte[] bigBody = new byte[3 * 1024 * 1024];
        for (int i = 0; i < bigBody.length; i++) bigBody[i] = (byte) (i * 31);
        check("3MB を置ける", relay.post(SyncCrypto.seal(keys, "image", "big.png", "image/png", bigBody)), true);
        List<RelayClient.Item> after = relay.list(items.get(0).seq);
        check("大きい項目は、一覧に中身が入らない", after.size() + "," + (after.get(0).inline == null), "1,true");
        SyncCrypto.Opened bigBack = SyncCrypto.open(keys, relay.get(after.get(0).seq));
        check("3MB がバイト単位で一致", Arrays.equals(bigBack.body, bigBody), true);
        check("消えた（存在しない）項目は null", relay.get(99999) == null, true);

        // 高速モード: 公開鍵を登録 → サーバーに平文で送る → サーバーが暗号化 → 鍵で復号
        byte[][] qk = newQuickKey();
        String pubUrl = base + "/r/" + keys.room + "/pub";
        check("高速モード: 公開鍵を登録できる", http("PUT", pubUrl, qk[1]), 201);
        check("高速モード: 別の鍵での上書きは拒否", http("PUT", pubUrl, newQuickKey()[1]), 409);
        long lastSeq = after.get(0).seq;
        check("高速モード: テキストを送れる", http("POST", base + "/r/" + keys.room + "/quick", utf8("ショートカットから😀")), 201);
        List<RelayClient.Item> quickItems = relay.list(lastSeq);
        check("高速モード: 一覧に出る", quickItems.size() + "," + quickItems.get(0).device, "1,iphone-quick");
        byte[] blob = quickItems.get(0).inline != null ? quickItems.get(0).inline : relay.get(quickItems.get(0).seq);
        check("高速モード: 先頭が 2（方式 2）", blob[0], (byte) 2);
        SyncCrypto.Opened quick = SyncCrypto.openQuick(qk[0], blob);
        check("高速モード: サーバーが作った暗号文を、Java で復号できる", new String(quick.body, StandardCharsets.UTF_8), "ショートカットから😀");
        check("高速モード: 通常の鍵では開けない", throwsError(() -> SyncCrypto.open(keys, blob)), true);

        ws.close();
        System.out.println("--- 通信のテストはここまで ---");
    }
}
