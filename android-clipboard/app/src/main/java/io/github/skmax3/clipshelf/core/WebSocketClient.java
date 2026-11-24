package io.github.skmax3.clipshelf.core;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * 新着の知らせを待つための、小さな WebSocket クライアント（RFC 6455。外部のライブラリを使わず、Java だけで書いてある）。
 * 使い方: connect() でつなぎ、readLoop() で受け取り続ける（切れるまで戻らない）。別のスレッドから sendText() で送れる。
 */
public final class WebSocketClient {
    public interface Listener {
        void onText(String text);
    }

    private static final String GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private static final SecureRandom RANDOM = new SecureRandom();

    private final URI uri;
    private final Listener listener;
    private final Object writeLock = new Object();
    private volatile boolean closed;
    private Socket socket;
    private InputStream in;
    private OutputStream out;

    public WebSocketClient(String url, Listener listener) {
        this.uri = URI.create(url);
        this.listener = listener;
    }

    public void connect(int timeoutMs) throws IOException {
        boolean tls = "wss".equals(uri.getScheme());
        String host = uri.getHost();
        int port = uri.getPort() > 0 ? uri.getPort() : (tls ? 443 : 80);

        Socket plain = new Socket();
        plain.connect(new InetSocketAddress(host, port), timeoutMs);
        Socket s = plain;
        if (tls) {
            SSLSocket ssl = (SSLSocket) ((SSLSocketFactory) SSLSocketFactory.getDefault()).createSocket(plain, host, port, true);
            SSLParameters params = ssl.getSSLParameters();
            params.setEndpointIdentificationAlgorithm("HTTPS");  // 相手の名前を確かめる（なりすまし対策）
            ssl.setSSLParameters(params);
            ssl.startHandshake();
            s = ssl;
        }
        // 25秒ごとに ping を送っているので、70秒なにも来なければ、切れているとみなす
        s.setSoTimeout(70_000);
        socket = s;
        in = new BufferedInputStream(s.getInputStream());
        out = s.getOutputStream();

        byte[] keyBytes = new byte[16];
        RANDOM.nextBytes(keyBytes);
        String key = Base64.getEncoder().encodeToString(keyBytes);
        String path = uri.getRawPath() == null || uri.getRawPath().isEmpty() ? "/" : uri.getRawPath();
        if (uri.getRawQuery() != null) path += "?" + uri.getRawQuery();
        String hostHeader = uri.getPort() > 0 ? host + ":" + uri.getPort() : host;
        String request = "GET " + path + " HTTP/1.1\r\nHost: " + hostHeader + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n";
        out.write(request.getBytes(StandardCharsets.ISO_8859_1));
        out.flush();

        String headers = readHeaders();
        String[] lines = headers.split("\r\n");
        if (lines.length == 0 || !lines[0].contains(" 101")) throw new IOException("WebSocket につなげません: " + lines[0]);
        String accept = null;
        for (String line : lines) {
            if (line.toLowerCase().startsWith("sec-websocket-accept:")) accept = line.substring(line.indexOf(':') + 1).trim();
        }
        if (!expectedAccept(key).equals(accept)) throw new IOException("WebSocket の相手を確認できませんでした");
    }

    private static String expectedAccept(String key) throws IOException {
        try {
            byte[] sha1 = MessageDigest.getInstance("SHA-1").digest((key + GUID).getBytes(StandardCharsets.ISO_8859_1));
            return Base64.getEncoder().encodeToString(sha1);
        } catch (NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
    }

    private String readHeaders() throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        while (buffer.size() < 16 * 1024) {
            int b = in.read();
            if (b < 0) throw new EOFException("つなぐ途中で切れました");
            buffer.write(b);
            byte[] a = buffer.toByteArray();
            int n = a.length;
            if (n >= 4 && a[n - 4] == '\r' && a[n - 3] == '\n' && a[n - 2] == '\r' && a[n - 1] == '\n') {
                return new String(a, 0, n - 4, StandardCharsets.ISO_8859_1);
            }
        }
        throw new IOException("返事が長すぎます");
    }

    private int readByte() throws IOException {
        int b = in.read();
        if (b < 0) throw new EOFException("切れました");
        return b;
    }

    private byte[] readFully(int length) throws IOException {
        byte[] data = new byte[length];
        int offset = 0;
        while (offset < length) {
            int n = in.read(data, offset, length - offset);
            if (n < 0) throw new EOFException("切れました");
            offset += n;
        }
        return data;
    }

    /** 受け取り続ける。相手が閉じたら正常に戻る。切れたら例外（そのあと、つなぎ直す） */
    public void readLoop() throws IOException {
        ByteArrayOutputStream fragments = null;
        while (!closed) {
            int b0 = readByte();
            int b1 = readByte();
            boolean fin = (b0 & 0x80) != 0;
            int opcode = b0 & 0x0f;
            boolean masked = (b1 & 0x80) != 0;
            long length = b1 & 0x7f;
            if (length == 126) {
                length = (readByte() << 8) | readByte();
            } else if (length == 127) {
                length = 0;
                for (int k = 0; k < 8; k++) length = (length << 8) | readByte();
            }
            if (length > 16 * 1024 * 1024) throw new IOException("大きすぎるメッセージです");
            byte[] mask = masked ? readFully(4) : null;
            byte[] payload = readFully((int) length);
            if (mask != null) for (int k = 0; k < payload.length; k++) payload[k] ^= mask[k % 4];

            switch (opcode) {
                case 0x1:  // テキスト
                case 0x0:  // 続き
                    if (opcode == 0x1) fragments = new ByteArrayOutputStream();
                    if (fragments == null) break;
                    fragments.write(payload);
                    if (fin) {
                        String text = new String(fragments.toByteArray(), StandardCharsets.UTF_8);
                        fragments = null;
                        listener.onText(text);
                    }
                    break;
                case 0x8:  // 閉じる
                    try { sendFrame(0x8, payload); } catch (IOException ignored) { /* 相手がもう閉じている */ }
                    return;
                case 0x9:  // ping → pong
                    sendFrame(0xA, payload);
                    break;
                default:  // pong・バイナリは使わない
                    break;
            }
        }
    }

    public void sendText(String text) throws IOException {
        sendFrame(0x1, text.getBytes(StandardCharsets.UTF_8));
    }

    /** クライアントから送るフレームは、マスクをかける決まり */
    private void sendFrame(int opcode, byte[] payload) throws IOException {
        byte[] mask = new byte[4];
        RANDOM.nextBytes(mask);
        ByteArrayOutputStream frame = new ByteArrayOutputStream();
        frame.write(0x80 | opcode);
        if (payload.length < 126) {
            frame.write(0x80 | payload.length);
        } else if (payload.length <= 0xffff) {
            frame.write(0x80 | 126);
            frame.write(payload.length >>> 8);
            frame.write(payload.length & 0xff);
        } else {
            throw new IOException("送るメッセージが大きすぎます");
        }
        frame.write(mask);
        for (int k = 0; k < payload.length; k++) frame.write(payload[k] ^ mask[k % 4]);
        synchronized (writeLock) {
            out.write(frame.toByteArray());
            out.flush();
        }
    }

    public void close() {
        closed = true;
        try {
            if (socket != null) socket.close();
        } catch (IOException ignored) {
            // 閉じるだけなので、失敗しても気にしない
        }
    }
}
