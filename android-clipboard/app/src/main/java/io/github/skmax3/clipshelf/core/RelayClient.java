package io.github.skmax3.clipshelf.core;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** 中継サーバー（clip-relay）との通信。サーバーには、端末で暗号化したデータしか渡さない。呼び出しは、画面のスレッド以外で行うこと */
public final class RelayClient {
    /** 中継サーバーに置かれている1件。inline は、小さいものだけ一覧に入っている中身 */
    public static final class Item {
        public final long seq;
        public final String device;
        public final byte[] inline;

        Item(long seq, String device, byte[] inline) {
            this.seq = seq;
            this.device = device;
            this.inline = inline;
        }
    }

    private final String baseUrl;
    private final String room;
    private final String device;

    public RelayClient(String baseUrl, String room, String device) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.room = room;
        this.device = device;
    }

    public String webSocketUrl() {
        String base = baseUrl.startsWith("https://") ? "wss://" + baseUrl.substring(8)
                : baseUrl.startsWith("http://") ? "ws://" + baseUrl.substring(7) : baseUrl;
        return base + "/r/" + room + "/ws";
    }

    private HttpURLConnection open(String path, String method) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(baseUrl + "/r/" + room + path).openConnection();
        c.setConnectTimeout(15_000);
        c.setReadTimeout(30_000);
        c.setRequestMethod(method);
        c.setRequestProperty("x-device", device);
        return c;
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[16 * 1024];
        int n;
        while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
        return out.toByteArray();
    }

    /** after より新しい項目の一覧 */
    @SuppressWarnings("unchecked")
    public List<Item> list(long after) throws IOException {
        HttpURLConnection c = open("/items?after=" + after, "GET");
        try {
            if (c.getResponseCode() != 200) throw new IOException("HTTP " + c.getResponseCode());
            String body = new String(readAll(c.getInputStream()), StandardCharsets.UTF_8);
            List<Object> items;
            try {
                items = (List<Object>) MiniJson.parseObject(body).get("items");
            } catch (IllegalArgumentException e) {
                throw new IOException("サーバーの返事を読めません", e);
            }
            List<Item> list = new ArrayList<>();
            if (items == null) return list;
            for (Object o : items) {
                Map<String, Object> m = (Map<String, Object>) o;
                Object seq = m.get("seq");
                if (!(seq instanceof Double)) continue;
                Object dev = m.get("dev");
                Object data = m.get("data");
                list.add(new Item(((Double) seq).longValue(), dev instanceof String ? (String) dev : "",
                        data instanceof String ? SyncCrypto.fromBase64((String) data) : null));
            }
            return list;
        } finally {
            c.disconnect();
        }
    }

    /** 1件の中身。24時間たって消えていたら null */
    public byte[] get(long seq) throws IOException {
        HttpURLConnection c = open("/items/" + seq, "GET");
        try {
            int code = c.getResponseCode();
            if (code == 404) return null;
            if (code != 200) throw new IOException("HTTP " + code);
            return readAll(c.getInputStream());
        } finally {
            c.disconnect();
        }
    }

    /** 暗号化したデータを置く。置けたら true */
    public boolean post(byte[] encrypted) throws IOException {
        HttpURLConnection c = open("/items", "POST");
        try {
            c.setDoOutput(true);
            c.setFixedLengthStreamingMode(encrypted.length);
            c.setRequestProperty("Content-Type", "application/octet-stream");
            try (OutputStream out = c.getOutputStream()) {
                out.write(encrypted);
            }
            return c.getResponseCode() == 201;
        } finally {
            c.disconnect();
        }
    }
}
