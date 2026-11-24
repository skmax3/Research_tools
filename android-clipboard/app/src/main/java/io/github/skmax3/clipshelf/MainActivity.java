package io.github.skmax3.clipshelf;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import io.github.skmax3.clipshelf.core.PairCode;

/** 本体の画面。ペアリング、今のクリップボードを送る、届いたものを取り出す、設定 */
public final class MainActivity extends Activity implements Inbox.Listener {
    private Prefs prefs;
    private EditText codeField;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 1);  // 届いたことを通知で知らせるため
        }
        startSync(false);
    }

    @Override
    protected void onResume() {
        super.onResume();
        Inbox.setListener(this);
        render();
    }

    @Override
    protected void onPause() {
        Inbox.setListener(null);
        super.onPause();
    }

    @Override
    public void onChanged() {
        runOnUiThread(this::render);
    }

    // ---- サービスの操作 ----

    /** 待ち続けるサービスを始める。restart が true なら、いったん止めてから（ペアリングを変えたあと） */
    private void startSync(boolean restart) {
        if (restart) stopService(new Intent(this, SyncService.class));
        if (!prefs.paired() || !prefs.serviceEnabled()) return;
        try {
            startForegroundService(new Intent(this, SyncService.class));
        } catch (RuntimeException e) {
            Toast.makeText(this, "バックグラウンドの待ち受けを始められませんでした", Toast.LENGTH_LONG).show();
        }
    }

    // ---- 画面 ----

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    private TextView text(String s, int sizeSp, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sizeSp);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, dp(6), 0, dp(6));
        return t;
    }

    private Button button(String label, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setOnClickListener(l);
        return b;
    }

    private void render() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(20), dp(40), dp(20), dp(24));
        scroll.addView(root);

        root.addView(text("クリップ棚", 26, true));
        if (!prefs.paired()) {
            renderUnpaired(root);
        } else {
            renderPaired(root);
        }
        setContentView(scroll);
    }

    private void renderUnpaired(LinearLayout root) {
        root.addView(text("最初に、Mac とペアリングします（1回だけ）", 16, true));
        root.addView(text("1. Mac のクリップ棚のメニューバーのアイコン →「端末のペアリング…」を開く\n"
                + "2.「Windows・Android アプリ用のコードをコピー」を押す\n"
                + "3. そのコードを、この端末に送って（メモや自分宛てのメッセージなど）、下の欄に貼り付ける\n"
                + "※ コードには鍵が入っているので、自分の端末以外には送らないでください", 14, false));
        codeField = new EditText(this);
        codeField.setHint("ここにペアリングコードを貼り付け");
        codeField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        codeField.setMinLines(3);
        codeField.setGravity(Gravity.TOP);
        root.addView(codeField);
        root.addView(button("ペアリング", v -> pair()));
    }

    private void pair() {
        PairCode code = PairCode.parse(codeField.getText().toString());
        if (code == null) {
            Toast.makeText(this, "コードが正しくありません。Mac の「Windows・Android アプリ用のコードをコピー」で、もう一度コピーしてください", Toast.LENGTH_LONG).show();
            return;
        }
        prefs.pair(code);
        if (code.quick.isEmpty()) {
            Toast.makeText(this, "高速モードの鍵が入っていないコードです。iPhone のショートカットから送ったものは、この端末では開けません", Toast.LENGTH_LONG).show();
        }
        startSync(true);
        render();
    }

    private void renderPaired(LinearLayout root) {
        root.addView(text(SyncService.running ? "ペアリング済み・バックグラウンドで待っています" : "ペアリング済み・待ち受けは止まっています", 14, false));

        root.addView(button("今のクリップボードを、ほかの端末へ送る",
                v -> startActivity(new Intent(this, SendClipboardActivity.class))));

        CheckBox autoCopy = new CheckBox(this);
        autoCopy.setText("届いたら、すぐクリップボードに入れる");
        autoCopy.setChecked(prefs.autoCopy());
        autoCopy.setOnCheckedChangeListener((b, checked) -> prefs.setAutoCopy(checked));
        root.addView(autoCopy);

        root.addView(button(prefs.serviceEnabled() ? "待ち受けを止める" : "待ち受けを始める", v -> {
            boolean enable = !prefs.serviceEnabled();
            prefs.setServiceEnabled(enable);
            if (enable) startSync(false);
            else stopService(new Intent(this, SyncService.class));
            render();
        }));

        root.addView(text("届いたもの（直近10件）", 16, true));
        java.util.List<Inbox.Entry> entries = Inbox.list();
        if (entries.isEmpty()) {
            root.addView(text("まだ届いていません。Mac・iPhone・Windows から送ると、ここに出ます。", 14, false));
        }
        for (Inbox.Entry e : entries) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            TextView label = text(e.device + "・" + e.summary(), 14, false);
            row.addView(label, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            row.addView(button("コピー", v -> {
                try {
                    Clips.setEntry(this, e);
                    Toast.makeText(this, "コピーしました", Toast.LENGTH_SHORT).show();
                } catch (RuntimeException ex) {
                    Toast.makeText(this, "コピーできませんでした", Toast.LENGTH_LONG).show();
                }
            }));
            root.addView(row);
        }

        root.addView(text("使い方", 16, true));
        root.addView(text("・送る: ほかのアプリの共有メニューで「クリップ棚」を選ぶ（写真・スクショ・テキスト）\n"
                + "・コピーしたものを送る: 画面の上から引き下げて、クイック設定のタイル「今のコピーを送る」をタップ"
                + "（タイルは、クイック設定の編集（鉛筆）から追加）。アプリのアイコンの長押しや、通知のボタンからも送れる\n"
                + "・届いたもの: 設定がオンなら、クリップボードに入っているので、そのまま貼り付けられる", 14, false));

        root.addView(text("バックグラウンドで止まらないようにする", 16, true));
        root.addView(text("機種によっては、電池の節約のために、待ち受けが止められることがあります。止まるときは、下のボタンで除外してください。", 14, false));
        root.addView(button("電池の最適化から除外する", v -> requestIgnoreBatteryOptimization()));
        root.addView(button("通知の設定を開く", v -> startActivity(new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName()))));

        root.addView(button("ペアリングを解除", v -> new AlertDialog.Builder(this)
                .setMessage("この端末のペアリングを解除しますか？（Mac や iPhone のペアリングは、そのままです）")
                .setPositiveButton("解除", (d, w) -> {
                    prefs.unpair();
                    stopService(new Intent(this, SyncService.class));
                    render();
                })
                .setNegativeButton("やめる", null)
                .show()));
    }

    private void requestIgnoreBatteryOptimization() {
        PowerManager pm = getSystemService(PowerManager.class);
        if (pm != null && pm.isIgnoringBatteryOptimizations(getPackageName())) {
            Toast.makeText(this, "すでに除外されています", Toast.LENGTH_SHORT).show();
            return;
        }
        try {
            startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName())));
        } catch (RuntimeException e) {
            startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
        }
    }
}
