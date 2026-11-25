package io.github.skmax3.clipshelf.core;

import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Mac のクリップ棚が出す「Windows・Android アプリ用コード」（k=…&s=…&q=…）を読む。
 * iPhone 用のペアリングコード（アドレス全体、# 以降だけ、秘密だけ）も読める（その場合は高速モードの鍵なし）。
 */
public final class PairCode {
    public static final String DEFAULT_RELAY = "https://fwr-clip.fwrtools.workers.dev";
    private static final Pattern SECRET = Pattern.compile("^[A-Za-z0-9_-]{43}$");

    public final String secret;
    public final String relay;
    /** 高速モードの鍵（base64url）。なければ空 */
    public final String quick;

    private PairCode(String secret, String relay, String quick) {
        this.secret = secret;
        this.relay = relay;
        this.quick = quick;
    }

    /** iPhone 用ページ。ペアリング用リンクの行き先 */
    public static final String PAIR_PAGE = "https://skmax3.github.io/Research_tools/clip-send/";

    /** この端末で新しく始める（新しい鍵を作る） */
    public static PairCode fresh() {
        return new PairCode(SyncCrypto.newSecret(), DEFAULT_RELAY, "");
    }

    /**
     * ペアリング用リンク（どの端末でも共通の形）。iPhone はタップで、Android・Windows は貼り付けでペアリングできる。
     * 鍵が入っているので、自分の端末以外には送らないこと
     */
    public static String link(String secret, String relay, String quick) {
        try {
            return PAIR_PAGE + "#k=" + secret + "&s=" + URLEncoder.encode(relay, "UTF-8")
                    + (quick == null || quick.isEmpty() ? "" : "&q=" + quick);
        } catch (UnsupportedEncodingException e) {
            throw new IllegalStateException(e);
        }
    }

    /** 読めなければ null */
    public static PairCode parse(String text) {
        if (text == null) return null;
        String t = text.trim();
        if (t.isEmpty()) return null;
        int hash = t.indexOf('#');
        if (hash >= 0) t = t.substring(hash + 1);
        while (t.startsWith("?") || t.startsWith("#")) t = t.substring(1);

        Map<String, String> query = new HashMap<>();
        for (String part : t.split("&")) {
            int eq = part.indexOf('=');
            if (eq <= 0) continue;
            try {
                query.put(part.substring(0, eq), URLDecoder.decode(part.substring(eq + 1), "UTF-8"));
            } catch (UnsupportedEncodingException | IllegalArgumentException e) {
                // 読めない項目は飛ばす
            }
        }

        String secret = query.get("k");
        if (secret == null && SECRET.matcher(t).matches()) secret = t;
        if (secret == null || !SECRET.matcher(secret).matches()) return null;

        String relay = query.containsKey("s") ? query.get("s").trim() : DEFAULT_RELAY;
        if (!relay.startsWith("http://") && !relay.startsWith("https://")) relay = "https://" + relay;
        while (relay.endsWith("/")) relay = relay.substring(0, relay.length() - 1);

        // 高速モードの鍵。形が正しいものだけ受け取る
        String quick = query.containsKey("q") ? query.get("q") : "";
        byte[] raw = quick.isEmpty() ? null : SyncCrypto.fromBase64(quick);
        if (raw == null || raw.length != 97 || raw[0] != 4) quick = "";

        return new PairCode(secret, relay, quick);
    }
}
