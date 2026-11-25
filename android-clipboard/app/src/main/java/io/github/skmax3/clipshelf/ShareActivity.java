package io.github.skmax3.clipshelf;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;
import io.github.skmax3.clipshelf.core.PairCode;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** 共有メニュー（写真・スクショ・テキストを、ほかの端末へ送る）。画面は見せない（透明）。複数枚もまとめて送れる */
public final class ShareActivity extends Activity {
    @Override
    @SuppressWarnings("deprecation")
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        final Context app = getApplicationContext();
        Intent intent = getIntent();
        String action = intent.getAction();

        final List<Uri> uris = new ArrayList<>();
        String sharedText = null;
        if (Intent.ACTION_SEND.equals(action)) {
            Uri one = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (one != null) uris.add(one);
            else sharedText = intent.getStringExtra(Intent.EXTRA_TEXT);
        } else if (Intent.ACTION_SEND_MULTIPLE.equals(action)) {
            ArrayList<Uri> many = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (many != null) uris.addAll(many);
        }
        final String text = sharedText;
        if (uris.isEmpty() && (text == null || text.isEmpty())) {
            Toast.makeText(app, "送れるものがありません", Toast.LENGTH_LONG).show();
            finish();
            return;
        }
        // まだペアリングしていない端末に、ペアリング用リンクが共有されたら、そのままペアリングする
        if (!new Prefs(app).paired() && text != null && PairCode.parse(text) != null) {
            new Prefs(app).pair(PairCode.parse(text));
            Toast.makeText(app, "ペアリングしました", Toast.LENGTH_LONG).show();
            startActivity(new Intent(app, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            finish();
            return;
        }
        if (!new Prefs(app).paired()) {
            Toast.makeText(app, "先にクリップ棚でペアリングしてください", Toast.LENGTH_LONG).show();
            startActivity(new Intent(app, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            finish();
            return;
        }
        Toast.makeText(app, "送っています…", Toast.LENGTH_SHORT).show();

        new Thread(() -> {
            int total = 0;
            int ok = 0;
            String firstError = null;
            if (text != null && !text.isEmpty()) {
                total++;
                String error = Sender.sendBlocking(app, new Clips.Content("text", "", "text/plain", text.getBytes(StandardCharsets.UTF_8)));
                if (error == null) ok++;
                else firstError = error;
            }
            for (Uri uri : uris) {
                total++;
                Clips.Content content = Clips.readUri(app, uri);
                String error = content == null ? "読み込めませんでした" : Sender.sendBlocking(app, content);
                if (error == null) ok++;
                else if (firstError == null) firstError = error;
            }
            final String message = ok == total ? (total == 1 ? "送りました" : total + "件を送りました")
                    : ok == 0 ? firstError : ok + "件を送りました（一部は送れませんでした: " + firstError + "）";
            new Handler(Looper.getMainLooper()).post(() -> {
                Toast.makeText(app, message, Toast.LENGTH_LONG).show();
                finish();
            });
        }).start();
    }
}
