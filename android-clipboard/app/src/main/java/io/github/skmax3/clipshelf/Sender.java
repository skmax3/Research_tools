package io.github.skmax3.clipshelf;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.media.ExifInterface;
import android.content.Context;
import io.github.skmax3.clipshelf.core.RelayClient;
import io.github.skmax3.clipshelf.core.SyncCrypto;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.security.GeneralSecurityException;

/** ほかの端末へ送る（暗号化して、中継サーバーに置く）。画面のスレッド以外で呼ぶこと */
final class Sender {
    /** 中継サーバーの上限（8MB）に余裕を持たせた、送れる大きさ */
    private static final int MAX_BYTES = 7_500_000;
    /** これ以下の小さい画像は、そのまま送る */
    private static final int QUICK_BYTES = 400 * 1024;
    /** 大きい画像は、長辺をこれ以下にして JPEG にする（貼り付けや共有には十分で、送るデータが数分の1になる） */
    private static final int MAX_EDGE = 2560;

    private Sender() {}

    /** 送る。成功したら null、失敗したら、画面に出すメッセージ */
    static String sendBlocking(Context context, Clips.Content content) {
        return sendBlocking(context, content, true);
    }

    /** record が true なら、送ったものを履歴にも残す（履歴から送り直すときは false） */
    static String sendBlocking(Context context, Clips.Content content, boolean record) {
        Prefs prefs = new Prefs(context);
        if (!prefs.paired()) return "先にペアリングしてください";
        try {
            SyncCrypto.Keys keys = SyncCrypto.derive(prefs.secret());
            RelayClient relay = new RelayClient(prefs.relay(), keys.room, Prefs.deviceName());

            String name = content.name;
            String mime = content.mime;
            byte[] body = content.data;
            if ("image".equals(content.kind)) {
                Prepared p = prepareImage(content.data, content.name);
                if (p == null) return "この画像は送れません";
                name = p.name;
                mime = p.mime;
                body = p.data;
            } else if (body.length > MAX_BYTES) {
                return "テキストが大きすぎます";
            }
            if (!relay.post(SyncCrypto.seal(keys, content.kind, name, mime, body))) return "送れませんでした";
            if (record) Inbox.addLocal(context, content.kind, name, mime, body);  // 送ったものも履歴に残す
            return null;
        } catch (IOException e) {
            return "通信できませんでした";
        } catch (GeneralSecurityException e) {
            return "暗号化できませんでした";
        }
    }

    private static final class Prepared {
        final String name;
        final String mime;
        final byte[] data;

        Prepared(String name, String mime, byte[] data) {
            this.name = name;
            this.mime = mime;
            this.data = data;
        }
    }

    private static boolean isJpeg(byte[] d) {
        return d.length > 3 && (d[0] & 0xff) == 0xff && (d[1] & 0xff) == 0xd8 && (d[2] & 0xff) == 0xff;
    }

    private static boolean isPng(byte[] d) {
        return d.length > 8 && (d[0] & 0xff) == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G';
    }

    private static String baseName(String name) {
        if (name == null || name.isEmpty()) return "写真";
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    /** 画像を送れる形にする。小さい JPEG・PNG はそのまま。それ以外（大きい・HEIC など）は、長辺2560px 以下の JPEG にする */
    private static Prepared prepareImage(byte[] data, String name) {
        String base = baseName(name);
        boolean jpeg = isJpeg(data);
        boolean png = isPng(data);
        if ((jpeg || png) && data.length <= QUICK_BYTES) {
            return new Prepared(base + (jpeg ? ".jpg" : ".png"), jpeg ? "image/jpeg" : "image/png", data);
        }

        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;
        int longEdge = Math.max(bounds.outWidth, bounds.outHeight);
        int sample = 1;
        while (longEdge / (sample * 2) >= MAX_EDGE) sample *= 2;  // まず、読み込む大きさを小さくして、メモリを節約する

        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sample;
        Bitmap decoded = BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (decoded == null) return null;
        Bitmap source = applyOrientation(decoded, orientationOf(data));

        double scale = Math.min(1.0, (double) MAX_EDGE / Math.max(source.getWidth(), source.getHeight()));
        for (int i = 0; i < 6; i++) {
            int w = Math.max(1, (int) (source.getWidth() * scale));
            int h = Math.max(1, (int) (source.getHeight() * scale));
            Bitmap out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(out);
            canvas.drawColor(Color.WHITE);  // 透明な部分は白にする（JPEG は透明を持てない）
            canvas.drawBitmap(source, null, new Rect(0, 0, w, h), null);
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            out.compress(Bitmap.CompressFormat.JPEG, 88, bytes);
            out.recycle();
            if (bytes.size() <= MAX_BYTES) {
                source.recycle();
                return new Prepared(base + ".jpg", "image/jpeg", bytes.toByteArray());
            }
            scale *= 0.8;
        }
        source.recycle();
        return null;
    }

    private static int orientationOf(byte[] data) {
        try {
            return new ExifInterface(new ByteArrayInputStream(data)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
        } catch (IOException | RuntimeException e) {
            return ExifInterface.ORIENTATION_NORMAL;
        }
    }

    /** 写真の向き（EXIF）のとおりに回す。作り直した JPEG には向きの情報が残らないため */
    private static Bitmap applyOrientation(Bitmap bitmap, int orientation) {
        Matrix m = new Matrix();
        switch (orientation) {
            case ExifInterface.ORIENTATION_ROTATE_90: m.postRotate(90); break;
            case ExifInterface.ORIENTATION_ROTATE_180: m.postRotate(180); break;
            case ExifInterface.ORIENTATION_ROTATE_270: m.postRotate(270); break;
            case ExifInterface.ORIENTATION_FLIP_HORIZONTAL: m.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_FLIP_VERTICAL: m.postScale(1, -1); break;
            case ExifInterface.ORIENTATION_TRANSPOSE: m.postRotate(90); m.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_TRANSVERSE: m.postRotate(270); m.postScale(-1, 1); break;
            default: return bitmap;
        }
        Bitmap rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), m, true);
        if (rotated != bitmap) bitmap.recycle();
        return rotated;
    }
}
