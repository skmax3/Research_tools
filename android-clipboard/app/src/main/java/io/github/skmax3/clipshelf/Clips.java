package io.github.skmax3.clipshelf;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** クリップボードの読み書き */
final class Clips {
    /** 送るもの。kind は "text" か "image" */
    static final class Content {
        final String kind;
        final String name;
        final String mime;
        final byte[] data;

        Content(String kind, String name, String mime, byte[] data) {
            this.kind = kind;
            this.name = name;
            this.mime = mime;
            this.data = data;
        }
    }

    private static final int MAX_READ = 40 * 1024 * 1024;

    private Clips() {}

    /** 届いたものを、クリップボードに入れる。画像は、このアプリの ImageProvider の URI として入れる（貼り付けるアプリが読める） */
    static void setEntry(Context context, Inbox.Entry entry) {
        ClipboardManager cm = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        if ("text".equals(entry.kind)) {
            cm.setPrimaryClip(ClipData.newPlainText("クリップ棚", entry.text));
        } else {
            cm.setPrimaryClip(ClipData.newUri(context.getContentResolver(), "画像", ImageProvider.uriFor(entry.file)));
        }
    }

    /**
     * 今のクリップボード（テキストか画像）。Android の決まりで、このアプリの画面が前面にあるとき（フォーカスがあるとき）だけ読める。
     * 読めない・空のときは null
     */
    static Content read(Context context) {
        ClipboardManager cm = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData clip = cm.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) return null;
        ClipData.Item item = clip.getItemAt(0);

        Uri uri = item.getUri();
        if (uri != null) {
            Content image = readUri(context, uri);
            if (image != null) return image;
        }
        CharSequence text = item.getText();
        if (text == null && uri != null) text = item.coerceToText(context);
        if (text == null || text.length() == 0) return null;
        return new Content("text", "", "text/plain", text.toString().getBytes(StandardCharsets.UTF_8));
    }

    /** URI の指す画像を読む（共有された画像・クリップボードの画像）。画像でなければ null */
    static Content readUri(Context context, Uri uri) {
        ContentResolver cr = context.getContentResolver();
        try {
            String mime = cr.getType(uri);
            if (mime == null || !mime.startsWith("image/")) return null;
            try (InputStream in = cr.openInputStream(uri)) {
                if (in == null) return null;
                return new Content("image", displayName(cr, uri), mime, readAll(in));
            }
        } catch (IOException | SecurityException | IllegalArgumentException e) {
            return null;
        }
    }

    private static String displayName(ContentResolver cr, Uri uri) {
        try (Cursor c = cr.query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                String name = c.getString(0);
                if (name != null) return name;
            }
        } catch (RuntimeException e) {
            // 名前が取れなくても、送れる
        }
        return "";
    }

    static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[64 * 1024];
        int n;
        while ((n = in.read(buffer)) > 0) {
            out.write(buffer, 0, n);
            if (out.size() > MAX_READ) throw new IOException("大きすぎます");
        }
        return out.toByteArray();
    }
}
