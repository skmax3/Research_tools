package io.github.skmax3.clipshelf;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.LruCache;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * 履歴パネル（Mac の ⇧⌘X に当たる）。ショートカット・クイック設定のタイル・通知から開く。
 * 開いたときに、今のクリップボードを読み込んで、履歴の先頭に入れる（Android は、画面が前面にあるときしか、クリップボードを読めないため）。
 * カードをタップ＝クリップボードに入れて閉じる（そのまま貼り付けられる）。長押し＝送る・ピン留め・削除。
 */
public final class PanelActivity extends Activity implements Inbox.Listener {
    private static final int BLUE = Color.rgb(10, 132, 255);
    private static final int PURPLE = Color.rgb(175, 82, 222);
    private static final int ORANGE = Color.rgb(255, 149, 0);

    private boolean dark;
    private int bg;
    private int cardBg;
    private int ink;
    private int muted;

    private LinearLayout list;
    private LinearLayout chips;
    private TextView currentLabel;
    private EditText search;
    private String kindFilter = "all";
    private String deviceFilter = "";
    private String query = "";
    private boolean captured;
    private Clips.Content current;
    private final LruCache<Long, Bitmap> thumbs = new LruCache<>(40);

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Inbox.init(this);
        dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        bg = dark ? Color.rgb(32, 34, 40) : Color.rgb(245, 245, 248);
        cardBg = dark ? Color.rgb(44, 47, 54) : Color.WHITE;
        ink = dark ? Color.rgb(242, 242, 247) : Color.rgb(28, 28, 30);
        muted = dark ? Color.rgb(160, 160, 168) : Color.rgb(110, 110, 115);

        Window window = getWindow();
        window.setGravity(Gravity.BOTTOM);
        window.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, (int) (getResources().getDisplayMetrics().heightPixels * 0.82f));
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable sheet = new GradientDrawable();
        sheet.setColor(bg);
        sheet.setCornerRadii(new float[] {dp(20), dp(20), dp(20), dp(20), 0, 0, 0, 0});
        root.setBackground(sheet);
        root.setPadding(dp(14), dp(12), dp(14), dp(8));

        // 上: タイトルと「設定」
        LinearLayout top = new LinearLayout(this);
        top.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = label("クリップ棚", 18, true, ink);
        top.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        top.addView(smallButton("設定", v -> {
            startActivity(new Intent(this, MainActivity.class));
            finish();
        }));
        root.addView(top);

        // いまのクリップボード
        currentLabel = label("いまのコピーを読み込んでいます…", 13, false, muted);
        root.addView(currentLabel);

        search = new EditText(this);
        search.setHint("検索（コピーした文字を探す）");
        search.setSingleLine(true);
        search.setTextSize(15);
        search.setTextColor(ink);
        search.setHintTextColor(muted);
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) {}
            @Override public void afterTextChanged(Editable s) {
                query = s.toString().trim();
                render();
            }
        });
        root.addView(search);

        HorizontalScrollView chipScroll = new HorizontalScrollView(this);
        chipScroll.setHorizontalScrollBarEnabled(false);
        chips = new LinearLayout(this);
        chips.setOrientation(LinearLayout.HORIZONTAL);
        chipScroll.addView(chips);
        root.addView(chipScroll);

        ScrollView scroll = new ScrollView(this);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        scroll.addView(list);
        root.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
        render();
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
        render();
    }

    /** フォーカスを得たときに、今のクリップボードを読む（Android の決まり） */
    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (!hasFocus || captured) return;
        captured = true;
        try {
            current = Clips.read(this);
        } catch (RuntimeException e) {
            current = null;
        }
        if (current == null) {
            currentLabel.setText("いまのクリップボードは空です（または読めませんでした）");
            return;
        }
        final Clips.Content c = current;
        currentLabel.setText("いまのコピー: " + ("text".equals(c.kind)
                ? oneLine(new String(c.data, java.nio.charset.StandardCharsets.UTF_8)) : "画像（" + sizeText(c.data.length) + "）")
                + "　履歴に入れました");
        new Thread(() -> Inbox.addLocal(getApplicationContext(), c.kind, c.name, c.mime, c.data)).start();
    }

    @Override
    protected void onDestroy() {
        thumbs.evictAll();
        super.onDestroy();
    }

    // ---- 表示 ----

    private TextView label(String s, int sp, boolean bold, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, dp(3), 0, dp(3));
        return t;
    }

    private TextView smallButton(String s, View.OnClickListener l) {
        TextView t = label(s, 14, true, BLUE);
        t.setPadding(dp(12), dp(6), dp(12), dp(6));
        t.setOnClickListener(l);
        return t;
    }

    private static String oneLine(String s) {
        String t = s.replace('\n', ' ').trim();
        return t.length() > 40 ? t.substring(0, 40) + "…" : t;
    }

    private static String sizeText(long bytes) {
        return bytes < 1024 * 1024 ? Math.max(1, bytes / 1024) + " KB" : String.format(Locale.JAPAN, "%.1f MB", bytes / 1024.0 / 1024.0);
    }

    private static int colorOf(String category) {
        switch (category) {
            case "link": return PURPLE;
            case "image": return ORANGE;
            default: return BLUE;
        }
    }

    private static String categoryLabel(String category) {
        switch (category) {
            case "link": return "リンク";
            case "image": return "画像";
            default: return "テキスト";
        }
    }

    private TextView chip(String text, boolean on, int color, View.OnClickListener l) {
        TextView t = label(text, 13, true, on ? Color.WHITE : color);
        t.setPadding(dp(12), dp(5), dp(12), dp(5));
        GradientDrawable shape = new GradientDrawable();
        shape.setCornerRadius(dp(99));
        shape.setColor(on ? color : (color & 0x00ffffff) | 0x30000000);
        t.setBackground(shape);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, dp(4), dp(6), dp(4));
        t.setLayoutParams(lp);
        t.setOnClickListener(l);
        return t;
    }

    private boolean matches(Inbox.Entry e) {
        if (!"all".equals(kindFilter) && !kindFilter.equals(e.category())) return false;
        if (!deviceFilter.isEmpty() && !deviceFilter.equals(e.device)) return false;
        if (!query.isEmpty()) {
            String hay = "text".equals(e.kind) ? e.text : e.name;
            if (!hay.toLowerCase(Locale.ROOT).contains(query.toLowerCase(Locale.ROOT))) return false;
        }
        return true;
    }

    private void render() {
        if (list == null) return;
        List<Inbox.Entry> all = Inbox.list();

        chips.removeAllViews();
        chips.addView(chip("すべて", "all".equals(kindFilter), BLUE, v -> { kindFilter = "all"; render(); }));
        for (String k : new String[] {"text", "link", "image"}) {
            final String kk = k;
            chips.addView(chip(categoryLabel(k), kk.equals(kindFilter), colorOf(k), v -> { kindFilter = kk.equals(kindFilter) ? "all" : kk; render(); }));
        }
        List<String> devices = new ArrayList<>();
        for (Inbox.Entry e : all) if (!devices.contains(e.device)) devices.add(e.device);
        for (String d : devices) {
            final String dd = d;
            chips.addView(chip(d, d.equals(deviceFilter), Color.rgb(120, 120, 128), v -> { deviceFilter = dd.equals(deviceFilter) ? "" : dd; render(); }));
        }

        List<Inbox.Entry> shown = new ArrayList<>();
        for (Inbox.Entry e : all) if (matches(e)) shown.add(e);
        // ピン留めを先頭に（それ以外は新しい順のまま）
        List<Inbox.Entry> ordered = new ArrayList<>();
        for (Inbox.Entry e : shown) if (e.pinned) ordered.add(e);
        for (Inbox.Entry e : shown) if (!e.pinned) ordered.add(e);

        list.removeAllViews();
        if (ordered.isEmpty()) {
            list.addView(label("まだ何もありません。コピーしてからここを開くか、ほかの端末から送ると、ここにたまります。", 14, false, muted));
        }
        int n = 0;
        for (Inbox.Entry e : ordered) {
            if (++n > 60) break;
            list.addView(card(e));
        }
    }

    private View card(final Inbox.Entry e) {
        int color = colorOf(e.category());
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(cardBg);
        shape.setCornerRadius(dp(12));
        row.setBackground(shape);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, dp(4), 0, dp(4));
        row.setLayoutParams(lp);

        View bar = new View(this);
        GradientDrawable barShape = new GradientDrawable();
        barShape.setColor(color);
        barShape.setCornerRadii(new float[] {dp(12), dp(12), 0, 0, 0, 0, dp(12), dp(12)});
        bar.setBackground(barShape);
        row.addView(bar, new LinearLayout.LayoutParams(dp(6), ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(dp(10), dp(8), dp(10), dp(8));

        TextView meta = label((e.pinned ? "★ " : "") + categoryLabel(e.category()) + "　" + e.device + "・"
                + new SimpleDateFormat("M/d HH:mm", Locale.JAPAN).format(new Date(e.time))
                + ("image".equals(e.kind) ? "・" + sizeText(e.bytes()) : "・" + e.text.length() + "文字"), 12, true, color);
        body.addView(meta);

        if ("text".equals(e.kind)) {
            TextView t = label(e.text, 15, false, "link".equals(e.category()) ? PURPLE : ink);
            t.setMaxLines(4);
            t.setEllipsize(android.text.TextUtils.TruncateAt.END);
            body.addView(t);
        } else {
            ImageView iv = new ImageView(this);
            iv.setAdjustViewBounds(true);
            iv.setScaleType(ImageView.ScaleType.FIT_START);
            iv.setMaxHeight(dp(140));
            Bitmap bmp = thumb(e);
            if (bmp != null) iv.setImageBitmap(bmp);
            body.addView(iv, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            if (!e.name.isEmpty()) body.addView(label(e.name, 12, false, muted));
        }
        row.addView(body, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        row.setOnClickListener(v -> {
            try {
                Clips.setEntry(this, e);
                Toast.makeText(this, "コピーしました。貼り付けたい場所で、長押し →「貼り付け」", Toast.LENGTH_LONG).show();
                finish();
            } catch (RuntimeException ex) {
                Toast.makeText(this, "コピーできませんでした", Toast.LENGTH_LONG).show();
            }
        });
        row.setOnLongClickListener(v -> {
            actions(e);
            return true;
        });
        return row;
    }

    private Bitmap thumb(Inbox.Entry e) {
        Bitmap cached = thumbs.get(e.id);
        if (cached != null) return cached;
        if (e.file == null) return null;
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(e.file.getPath(), bounds);
        int edge = Math.max(bounds.outWidth, bounds.outHeight);
        int sample = 1;
        while (edge / (sample * 2) >= 480) sample *= 2;
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inSampleSize = sample;
        Bitmap bmp = BitmapFactory.decodeFile(e.file.getPath(), o);
        if (bmp != null) thumbs.put(e.id, bmp);
        return bmp;
    }

    /** 長押し: 送る・ピン留め・削除 */
    private void actions(final Inbox.Entry e) {
        final String[] items = {"ほかの端末へ送る", e.pinned ? "ピン留めを外す" : "ピン留め", "削除"};
        new AlertDialog.Builder(this).setItems(items, (d, which) -> {
            if (which == 0) sendEntry(e);
            else if (which == 1) {
                Inbox.togglePin(e.id);
                render();
            } else {
                Inbox.delete(e.id);
                render();
            }
        }).show();
    }

    private void sendEntry(final Inbox.Entry e) {
        final Context app = getApplicationContext();
        Toast.makeText(app, "送っています…", Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            String error;
            try {
                byte[] data;
                if ("text".equals(e.kind)) {
                    data = e.text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
                } else {
                    try (java.io.FileInputStream in = new java.io.FileInputStream(e.file)) {
                        data = Clips.readAll(in);
                    }
                }
                error = Sender.sendBlocking(app, new Clips.Content(e.kind, e.name, e.mime, data), false);
            } catch (java.io.IOException ex) {
                error = "読み込めませんでした";
            }
            final String message = error == null ? "送りました" : error;
            new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(app, message, Toast.LENGTH_LONG).show());
        }).start();
    }
}
