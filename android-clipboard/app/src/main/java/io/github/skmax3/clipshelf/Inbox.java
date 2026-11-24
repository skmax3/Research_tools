package io.github.skmax3.clipshelf;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * 履歴（ほかの端末から届いたもの、この端末でコピー・送信したもの）。
 * この端末のアプリの中（filesDir）だけに保存し、外部には送らない。ピン留め以外は、新しい順に 100 件・合計 200MB まで。
 */
final class Inbox {
    static final int MAX_ITEMS = 100;
    static final long MAX_BYTES = 200L * 1024 * 1024;

    static final class Entry {
        final long id;
        final String device;
        final String kind;  // "text" か "image"
        final String name;
        final String text;  // テキストのとき
        final File file;  // 画像のとき
        final String mime;
        long time = System.currentTimeMillis();
        boolean pinned;

        Entry(long id, String device, String kind, String name, String text, File file, String mime) {
            this.id = id;
            this.device = device;
            this.kind = kind;
            this.name = name;
            this.text = text;
            this.file = file;
            this.mime = mime;
        }

        long bytes() {
            if ("text".equals(kind)) return text.getBytes(StandardCharsets.UTF_8).length;
            return file != null ? file.length() : 0;
        }

        /** 色分けの種類: "text"（青）・"link"（紫）・"image"（橙） */
        String category() {
            if ("image".equals(kind)) return "image";
            String t = text.trim();
            if (!t.isEmpty() && !t.contains("\n") && !t.contains(" ") && (t.startsWith("http://") || t.startsWith("https://"))) return "link";
            return "text";
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
    private static boolean loaded;
    private static File base;

    private Inbox() {}

    /** 起動時に1回、保存してある履歴を読み込む */
    static synchronized void init(Context context) {
        if (loaded) return;
        loaded = true;
        base = context.getApplicationContext().getFilesDir();
        File index = new File(base, "history.json");
        if (!index.isFile()) return;
        try {
            byte[] raw;
            try (java.io.FileInputStream in = new java.io.FileInputStream(index)) {
                raw = Clips.readAll(in);
            }
            JSONArray array = new JSONArray(new String(raw, StandardCharsets.UTF_8));
            for (int i = 0; i < array.length(); i++) {
                JSONObject o = array.getJSONObject(i);
                File file = o.has("file") ? new File(imageDir(context), o.getString("file")) : null;
                if ("image".equals(o.getString("kind")) && (file == null || !file.isFile())) continue;
                Entry e = new Entry(o.getLong("id"), o.getString("device"), o.getString("kind"), o.optString("name", ""),
                        o.optString("text", ""), file, o.optString("mime", ""));
                e.time = o.optLong("time", System.currentTimeMillis());
                e.pinned = o.optBoolean("pinned", false);
                ENTRIES.add(e);
                nextId = Math.max(nextId, e.id + 1);
            }
        } catch (IOException | JSONException e) {
            ENTRIES.clear();  // 壊れていたら、空から始める
        }
    }

    private static void save() {
        if (base == null) return;
        try {
            JSONArray array = new JSONArray();
            for (Entry e : ENTRIES) {
                JSONObject o = new JSONObject();
                o.put("id", e.id).put("device", e.device).put("kind", e.kind).put("name", e.name).put("mime", e.mime)
                        .put("time", e.time).put("pinned", e.pinned);
                if ("text".equals(e.kind)) o.put("text", e.text);
                else if (e.file != null) o.put("file", e.file.getName());
                array.put(o);
            }
            File tmp = new File(base, "history.json.tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(array.toString().getBytes(StandardCharsets.UTF_8));
            }
            //noinspection ResultOfMethodCallIgnored
            tmp.renameTo(new File(base, "history.json"));
        } catch (IOException | JSONException e) {
            // 保存できなくても、動いている間は使える
        }
    }

    static synchronized long newId() {
        return nextId++;
    }

    /** 同じ内容のものがすでにあるか（あれば、新しく作らずに先頭へ動かす） */
    private static Entry findSame(Entry entry) {
        for (Entry e : ENTRIES) {
            if (!e.kind.equals(entry.kind)) continue;
            if ("text".equals(e.kind) && e.text.equals(entry.text)) return e;
            if ("image".equals(e.kind) && e.name.equals(entry.name) && e.bytes() == entry.bytes() && e.bytes() > 0) return e;
        }
        return null;
    }

    static synchronized void add(Entry entry) {
        Entry same = findSame(entry);
        if (same != null) {
            ENTRIES.remove(same);
            same.time = System.currentTimeMillis();
            ENTRIES.add(0, same);
            if (entry.file != null && !entry.file.equals(same.file)) //noinspection ResultOfMethodCallIgnored
                entry.file.delete();
        } else {
            ENTRIES.add(0, entry);
        }
        trim();
        save();
    }

    /** この端末でコピーした・送ったものを、履歴に入れる。画面のスレッド以外でもよい */
    static synchronized void addLocal(Context context, String kind, String name, String mime, byte[] data) {
        init(context);
        long id = newId();
        if ("text".equals(kind)) {
            add(new Entry(id, "Android", "text", "", new String(data, StandardCharsets.UTF_8), null, "text/plain"));
        } else {
            String m = mime == null || mime.isEmpty() ? "image/jpeg" : mime;
            String ext = m.contains("png") ? ".png" : m.contains("gif") ? ".gif" : m.contains("webp") ? ".webp" : ".jpg";
            File file = new File(imageDir(context), "local-" + id + "-" + System.currentTimeMillis() + ext);
            try (FileOutputStream out = new FileOutputStream(file)) {
                out.write(data);
            } catch (IOException e) {
                return;
            }
            add(new Entry(id, "Android", "image", name == null ? "" : name, "", file, m));
        }
        notifyChanged();
    }

    private static void trim() {
        long total = 0;
        int count = 0;
        List<Entry> remove = new ArrayList<>();
        for (Entry e : ENTRIES) {
            if (e.pinned) continue;
            count++;
            total += e.bytes();
            if (count > MAX_ITEMS || total > MAX_BYTES) remove.add(e);
        }
        for (Entry e : remove) {
            ENTRIES.remove(e);
            if (e.file != null) //noinspection ResultOfMethodCallIgnored
                e.file.delete();
        }
    }

    static synchronized List<Entry> list() {
        return new ArrayList<>(ENTRIES);
    }

    static synchronized Entry get(long id) {
        for (Entry e : ENTRIES) if (e.id == id) return e;
        return null;
    }

    static synchronized void togglePin(long id) {
        Entry e = get(id);
        if (e == null) return;
        e.pinned = !e.pinned;
        save();
    }

    static synchronized void delete(long id) {
        Entry e = get(id);
        if (e == null) return;
        ENTRIES.remove(e);
        if (e.file != null) //noinspection ResultOfMethodCallIgnored
            e.file.delete();
        save();
    }

    static synchronized void setListener(Listener l) {
        listener = l;
    }

    static synchronized void notifyChanged() {
        final Listener l = listener;
        if (l != null) new Handler(Looper.getMainLooper()).post(l::onChanged);
    }

    /** 画像を置く場所（ImageProvider が、ほかのアプリに渡す）。アプリの外からは読めない場所 */
    static File imageDir(Context context) {
        File dir = new File(context.getApplicationContext().getFilesDir(), "images");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        return dir;
    }
}
