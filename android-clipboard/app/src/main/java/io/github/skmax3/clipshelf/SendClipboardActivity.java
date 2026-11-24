package io.github.skmax3.clipshelf;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;

/**
 * 今のクリップボードを、ほかの端末へ送る。画面は見せない（透明）。
 * Android は、クリップボードを読めるのを「画面が前面にあるとき」に限っているので、前面に出て、フォーカスを得てから読む。
 */
public final class SendClipboardActivity extends Activity {
    private boolean handled;

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (!hasFocus || handled) return;
        handled = true;

        final Context app = getApplicationContext();
        final Clips.Content content = Clips.read(this);
        if (content == null) {
            Toast.makeText(app, "クリップボードにテキストか画像がありません", Toast.LENGTH_LONG).show();
            finish();
            return;
        }
        Toast.makeText(app, "送っています…", Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            String error = Sender.sendBlocking(app, content);
            new Handler(Looper.getMainLooper()).post(() -> {
                Toast.makeText(app, error == null ? "送りました" : error, Toast.LENGTH_LONG).show();
                finish();
            });
        }).start();
    }
}
