package io.github.skmax3.clipshelf;

import android.content.Context;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** ほかの端末から届いたもの（直近10件）。画面と通知から取り出せるように、このアプリが動いている間だけ覚えておく */
final class Inbox {
    static final class Entry {
        final long id;
        final String device;
        final String kind;  // "text" か "image"
        final String name;
        final String text;  // テキストのとき
        final File file;  // 画像のとき
        final String mime;
        final long time = System.currentTimeMillis();

        Entry(long id, String device, String kind, String name, String text, File file, String mime) {
            this.id = id;
            this.device = device;
            this.kind = kind;
            this.name = name;
            this.text = text;
            this.file = file;
            this.mime = mime;
        }

        String summary() {
            if ("text".equals(kind)) {
                String t = text.replace('\n', ' ').trim();
                return t.length() > 60 ? t.substring(0, 60) + "…" : t;
            }
            return "画像（" + (name.isEmpty() ? "名前なし" : name) + "）";
        }
    }

    interface Listener {
        void onChanged();
    }

    private static final List<Entry> ENTRIES = new ArrayList<>();
    private static Listener listener;
    private static long nextId = 1;

    private Inbox() {}

    static synchronized long newId() {
        return nextId++;
    }

    static synchronized void add(Entry entry) {
        ENTRIES.add(0, entry);
        while (ENTRIES.size() > 10) {
            Entry old = ENTRIES.remove(ENTRIES.size() - 1);
            if (old.file != null) //noinspection ResultOfMethodCallIgnored
                old.file.delete();
        }
    }

    static synchronized List<Entry> list() {
        return new ArrayList<>(ENTRIES);
    }

    static synchronized Entry get(long id) {
        for (Entry e : ENTRIES) if (e.id == id) return e;
        return null;
    }

    static synchronized void setListener(Listener l) {
        listener = l;
    }

    static synchronized void notifyChanged() {
        if (listener != null) listener.onChanged();
    }

    /** 画像を置く場所（ImageProvider が、ほかのアプリに渡す） */
    static File imageDir(Context context) {
        File dir = new File(context.getCacheDir(), "images");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        return dir;
    }
}
