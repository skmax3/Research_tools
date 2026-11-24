package io.github.skmax3.clipshelf.core;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.SecureRandom;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPrivateKeySpec;
import java.security.spec.ECPublicKeySpec;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * iPhone 用 Web アプリ（clip-send/index.html の SYNC-BEGIN〜END）・Mac（SyncCrypto.swift）・Windows（SyncCrypto.cs）と同じ暗号の取り決め。
 * 固定の値で、どの実装でも同じ結果になることをテストしている（android-clipboard/tests/CoreTest.java）。
 *
 * <pre>
 *   秘密 K（32バイト）→ HKDF-SHA256（salt = "clipshelf-v1"）で
 *     部屋ID = HKDF(info = "clipshelf-v1 room", 16バイト) の base64url（22文字）
 *     暗号鍵 = HKDF(info = "clipshelf-v1 enc", 32バイト) を AES-256-GCM に使う
 *   送るデータ   = [0x01][nonce 12バイト][AES-GCM の暗号文＋タグ16バイト（追加認証データ = "clipshelf-v1"）]
 *   暗号化する中身 = [メタ情報の長さ 4バイト（ビッグエンディアン）][メタ情報 JSON][本体]
 *   高速モード = [0x02][使い捨ての公開鍵 65バイト][nonce 12バイト][暗号文＋タグ]
 *     ECDH P-256 → HKDF-SHA256（salt = "clipshelf-v1", info = "clipshelf-v1 quick"）→ AES-256-GCM
 * </pre>
 */
public final class SyncCrypto {
    private static final byte[] TAG = "clipshelf-v1".getBytes(StandardCharsets.UTF_8);
    private static final SecureRandom RANDOM = new SecureRandom();

    private SyncCrypto() {}

    public static final class Keys {
        public final String room;
        public final byte[] key;

        Keys(String room, byte[] key) {
            this.room = room;
            this.key = key;
        }
    }

    /** kind は "text" か "image"。body は、テキストなら UTF-8、画像ならファイルの中身 */
    public static final class Opened {
        public final String kind;
        public final String name;
        public final String mime;
        public final byte[] body;

        Opened(String kind, String name, String mime, byte[] body) {
            this.kind = kind;
            this.name = name;
            this.mime = mime;
            this.body = body;
        }
    }

    // ---- base64url ----

    public static String base64Url(byte[] data) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(data);
    }

    /** base64url（普通の base64 も可）→ バイト列。読めなければ null */
    public static byte[] fromBase64(String s) {
        try {
            return Base64.getUrlDecoder().decode(s.replace('+', '-').replace('/', '_'));
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    // ---- 鍵 ----

    public static String newSecret() {
        byte[] b = new byte[32];
        RANDOM.nextBytes(b);
        return base64Url(b);
    }

    public static Keys derive(String secret) throws GeneralSecurityException {
        byte[] raw = fromBase64(secret);
        if (raw == null || raw.length != 32) throw new GeneralSecurityException("秘密の長さが正しくありません");
        byte[] room = hkdf(raw, TAG, utf8("clipshelf-v1 room"), 16);
        byte[] key = hkdf(raw, TAG, utf8("clipshelf-v1 enc"), 32);
        return new Keys(base64Url(room), key);
    }

    /** HKDF-SHA256（RFC 5869）。length は 32 以下のときだけ使う（今回は 16 と 32） */
    static byte[] hkdf(byte[] ikm, byte[] salt, byte[] info, int length) throws GeneralSecurityException {
        if (length > 32) throw new GeneralSecurityException("長すぎます");
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(salt, "HmacSHA256"));
        byte[] prk = mac.doFinal(ikm);
        mac.init(new SecretKeySpec(prk, "HmacSHA256"));
        mac.update(info);
        mac.update((byte) 1);
        return Arrays.copyOf(mac.doFinal(), length);
    }

    // ---- 暗号化・復号 ----

    /** nonce はテスト用（普通は null にして、毎回ランダムにする） */
    public static byte[] seal(Keys keys, byte[] meta, byte[] body, byte[] nonce) throws GeneralSecurityException {
        byte[] plain = new byte[4 + meta.length + body.length];
        plain[0] = (byte) (meta.length >>> 24);
        plain[1] = (byte) (meta.length >>> 16);
        plain[2] = (byte) (meta.length >>> 8);
        plain[3] = (byte) meta.length;
        System.arraycopy(meta, 0, plain, 4, meta.length);
        System.arraycopy(body, 0, plain, 4 + meta.length, body.length);

        if (nonce == null) {
            nonce = new byte[12];
            RANDOM.nextBytes(nonce);
        }
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(keys.key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(TAG);
        byte[] encrypted = cipher.doFinal(plain);  // 暗号文のあとに、タグ16バイトが付く

        byte[] out = new byte[1 + 12 + encrypted.length];
        out[0] = 1;
        System.arraycopy(nonce, 0, out, 1, 12);
        System.arraycopy(encrypted, 0, out, 13, encrypted.length);
        return out;
    }

    public static byte[] seal(Keys keys, String kind, String name, String mime, byte[] body) throws GeneralSecurityException {
        String meta = "{\"k\":" + MiniJson.quote(kind) + ",\"name\":" + MiniJson.quote(name) + ",\"mime\":" + MiniJson.quote(mime) + "}";
        return seal(keys, utf8(meta), body, null);
    }

    /** 方式 1（端末で暗号化したもの）を開く。壊れている・鍵が違うときは例外 */
    public static Opened open(Keys keys, byte[] data) throws GeneralSecurityException {
        if (data.length <= 1 + 12 + 16 || data[0] != 1) throw new GeneralSecurityException("未対応の形式です");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(keys.key, "AES"), new GCMParameterSpec(128, data, 1, 12));
        cipher.updateAAD(TAG);
        return parse(cipher.doFinal(data, 13, data.length - 13));
    }

    /**
     * 方式 2（高速モード。サーバーが公開鍵で暗号化したもの）を開く。
     * quickKey は 04 ‖ X ‖ Y ‖ D の 97 バイト（Mac が出す「Windows・Android アプリ用コード」の q）
     */
    public static Opened openQuick(byte[] quickKey, byte[] data) throws GeneralSecurityException {
        if (quickKey == null || quickKey.length != 97 || quickKey[0] != 4) throw new GeneralSecurityException("高速モードの鍵の形式が正しくありません");
        if (data.length <= 1 + 65 + 12 + 16 || data[0] != 2) throw new GeneralSecurityException("未対応の形式です");

        AlgorithmParameters params = AlgorithmParameters.getInstance("EC");
        params.init(new ECGenParameterSpec("secp256r1"));
        ECParameterSpec spec = params.getParameterSpec(ECParameterSpec.class);
        KeyFactory factory = KeyFactory.getInstance("EC");

        BigInteger d = new BigInteger(1, Arrays.copyOfRange(quickKey, 65, 97));
        BigInteger x = new BigInteger(1, Arrays.copyOfRange(data, 2, 34));  // data[1] は 0x04（圧縮なしの印）
        BigInteger y = new BigInteger(1, Arrays.copyOfRange(data, 34, 66));

        KeyAgreement agreement = KeyAgreement.getInstance("ECDH");
        agreement.init(factory.generatePrivate(new ECPrivateKeySpec(d, spec)));
        agreement.doPhase(factory.generatePublic(new ECPublicKeySpec(new ECPoint(x, y), spec)), true);
        byte[] shared = agreement.generateSecret();
        byte[] key = hkdf(shared, TAG, utf8("clipshelf-v1 quick"), 32);

        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, data, 66, 12));
        cipher.updateAAD(TAG);
        return parse(cipher.doFinal(data, 78, data.length - 78));
    }

    /** [メタ情報の長さ 4バイト][メタ情報 JSON][本体] を分ける */
    private static Opened parse(byte[] plain) throws GeneralSecurityException {
        if (plain.length < 4) throw new GeneralSecurityException("壊れたデータです");
        int n = ((plain[0] & 0xff) << 24) | ((plain[1] & 0xff) << 16) | ((plain[2] & 0xff) << 8) | (plain[3] & 0xff);
        if (n < 0 || 4 + n > plain.length) throw new GeneralSecurityException("壊れたデータです");
        Map<String, Object> meta;
        try {
            meta = MiniJson.parseObject(new String(plain, 4, n, StandardCharsets.UTF_8));
        } catch (IllegalArgumentException e) {
            throw new GeneralSecurityException("メタ情報を読めません", e);
        }
        return new Opened(str(meta, "k"), str(meta, "name"), str(meta, "mime"), Arrays.copyOfRange(plain, 4 + n, plain.length));
    }

    private static String str(Map<String, Object> m, String key) {
        Object v = m.get(key);
        return v instanceof String ? (String) v : "";
    }

    private static byte[] utf8(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }
}
