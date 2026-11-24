package io.github.skmax3.clipshelf;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import io.github.skmax3.clipshelf.core.PairCode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** 設定。この端末のアプリの中だけに保存する（ほかのアプリからは読めない。外部には送らない） */
final class Prefs {
    private final SharedPreferences sp;

    Prefs(Context context) {
        sp = context.getApplicationContext().getSharedPreferences("clipshelf", Context.MODE_PRIVATE);
    }

    boolean paired() {
        return !secret().isEmpty();
    }

    String secret() {
        return sp.getString("secret", "");
    }

    String relay() {
        return sp.getString("relay", PairCode.DEFAULT_RELAY);
    }

    /** 高速モードの鍵（04‖X‖Y‖D の base64url）。なければ空 */
    String quick() {
        return sp.getString("quick", "");
    }

    /** 届いたものを、すぐクリップボードに入れる */
    boolean autoCopy() {
        return sp.getBoolean("autoCopy", true);
    }

    void setAutoCopy(boolean value) {
        sp.edit().putBoolean("autoCopy", value).apply();
    }

    /** バックグラウンドで待ち続けるか（「接続を切る」で false） */
    boolean serviceEnabled() {
        return sp.getBoolean("serviceEnabled", true);
    }

    void setServiceEnabled(boolean value) {
        sp.edit().putBoolean("serviceEnabled", value).apply();
    }

    long lastSeq() {
        return sp.getLong("lastSeq", 0);
    }

    void setLastSeq(long seq) {
        sp.edit().putLong("lastSeq", seq).apply();
    }

    void pair(PairCode code) {
        sp.edit().putString("secret", code.secret).putString("relay", code.relay).putString("quick", code.quick)
                .putLong("lastSeq", 0).putBoolean("serviceEnabled", true).apply();
    }

    void unpair() {
        sp.edit().remove("secret").remove("quick").putLong("lastSeq", 0).apply();
    }

    /** 端末の名前（中継サーバーの x-device）。機種から短い印を付ける */
    static String deviceName() {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest((Build.MANUFACTURER + Build.MODEL).getBytes(StandardCharsets.UTF_8));
            return String.format("android-%02x%02x", hash[0], hash[1]);
        } catch (NoSuchAlgorithmException e) {
            return "android";
        }
    }
}
