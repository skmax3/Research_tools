package io.github.skmax3.clipshelf;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;
import io.github.skmax3.clipshelf.core.RelayClient;
import io.github.skmax3.clipshelf.core.SyncCrypto;
import io.github.skmax3.clipshelf.core.WebSocketClient;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.security.GeneralSecurityException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * ほかの端末から届くのを、バックグラウンドで待ち続ける（通知に「つながっています」と出る）。
 * 新着の知らせ（WebSocket）で受け取り、切れていても届くように、1分ごとにも確かめる。
 * 届いたものは、設定が「クリップボードに入れる」なら、そのままクリップボードに入れる（Android は、書き込みならバックグラウンドでもできる）。
 */
public final class SyncService extends Service {
    static final String ACTION_STOP = "io.github.skmax3.clipshelf.STOP";
    private static final String TAG = "ClipShelf";
    private static final String CHANNEL_STATUS = "status";
    private static final String CHANNEL_ARRIVAL = "arrival";
    private static final int NOTIFICATION_STATUS = 1;

    static volatile boolean running;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean polling = new AtomicBoolean(false);
    private final AtomicBoolean pollAgain = new AtomicBoolean(false);
    private volatile boolean stopped = true;
    private volatile boolean connected;
    private volatile WebSocketClient webSocket;
    private ExecutorService pollExecutor;
    private ScheduledExecutorService scheduler;
    private Thread listener;

    private Prefs prefs;
    private RelayClient relay;
    private SyncCrypto.Keys keys;
    private byte[] quickKey;
    private boolean warnedQuick;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        prefs = new Prefs(this);
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            prefs.setServiceEnabled(false);
            stopSelf();
            return START_NOT_STICKY;
        }
        createChannels();
        startForegroundCompat(statusNotification("つながっています"));  // startForegroundService から5秒以内に呼ぶ決まり
        if (!prefs.paired()) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (stopped) startWorkers();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopWorkers();
        super.onDestroy();
    }

    // ---- 開始・停止 ----

    private void startWorkers() {
        try {
            keys = SyncCrypto.derive(prefs.secret());
        } catch (GeneralSecurityException e) {
            Log.w(TAG, "ペアリング情報が正しくありません", e);
            stopSelf();
            return;
        }
        quickKey = prefs.quick().isEmpty() ? null : SyncCrypto.fromBase64(prefs.quick());
        relay = new RelayClient(prefs.relay(), keys.room, Prefs.deviceName());
        stopped = false;
        running = true;
        pollExecutor = Executors.newSingleThreadExecutor();
        scheduler = Executors.newSingleThreadScheduledExecutor();
        scheduler.scheduleWithFixedDelay(this::requestPoll, 30, 60, TimeUnit.SECONDS);  // 取りこぼし防止
        scheduler.scheduleWithFixedDelay(this::sendPing, 25, 25, TimeUnit.SECONDS);
        listener = new Thread(this::listenLoop, "clipshelf-ws");
        listener.start();
        requestPoll();
    }

    private void stopWorkers() {
        stopped = true;
        running = false;
        WebSocketClient ws = webSocket;
        if (ws != null) ws.close();
        if (listener != null) listener.interrupt();
        if (scheduler != null) scheduler.shutdownNow();
        if (pollExecutor != null) pollExecutor.shutdownNow();
    }

    // ---- 新着の知らせ（WebSocket） ----

    private void listenLoop() {
        int delay = 2;
        while (!stopped) {
            WebSocketClient client = new WebSocketClient(relay.webSocketUrl(), text -> requestPoll());
            try {
                client.connect(15_000);
                webSocket = client;
                delay = 2;
                setConnected(true);
                requestPoll();  // つながったら、取りこぼしがないか1回確かめる
                client.readLoop();
            } catch (IOException | RuntimeException e) {
                Log.w(TAG, "WebSocket が切れました: " + e.getMessage());
            } finally {
                webSocket = null;
                client.close();
            }
            setConnected(false);
            try {
                for (int i = 0; i < delay * 10 && !stopped; i++) Thread.sleep(100);
            } catch (InterruptedException e) {
                return;
            }
            delay = Math.min(60, delay * 2);
        }
    }

    private void sendPing() {
        WebSocketClient ws = webSocket;
        if (ws == null) return;
        try {
            ws.sendText("ping");
        } catch (IOException e) {
            // 切れている。受け取る側が気づいて、つなぎ直す
        }
    }

    private void setConnected(boolean value) {
        if (connected == value) return;
        connected = value;
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null && !stopped) nm.notify(NOTIFICATION_STATUS, statusNotification(value ? "つながっています" : "つなぎ直しています…"));
    }

    // ---- 受信 ----

    private void requestPoll() {
        if (stopped) return;
        pollAgain.set(true);
        if (polling.compareAndSet(false, true)) {
            try {
                pollExecutor.execute(this::pollLoop);
            } catch (RejectedExecutionException e) {
                polling.set(false);
            }
        }
    }

    private void pollLoop() {
        try {
            while (!stopped && pollAgain.getAndSet(false)) pollOnce();
        } finally {
            polling.set(false);
            if (pollAgain.get() && !stopped) requestPoll();
        }
    }

    private void pollOnce() {
        try {
            List<RelayClient.Item> list = relay.list(prefs.lastSeq());
            final boolean silent = prefs.silentNext();
            List<Inbox.Entry> got = new ArrayList<>();
            boolean aborted = false;
            for (RelayClient.Item item : list) {
                if (item.device.equals(Prefs.deviceName())) {  // 自分が置いたもの
                    advance(item.seq);
                    continue;
                }
                byte[] blob = item.inline;
                if (blob == null) {
                    try {
                        blob = relay.get(item.seq);
                    } catch (IOException e) {
                        aborted = true;  // 通信に失敗。ここで止めて、あとでやり直す（この項目は飛ばさない）
                        break;
                    }
                    if (blob == null) {  // 24時間たって消えた
                        advance(item.seq);
                        continue;
                    }
                }
                advance(item.seq);
                Inbox.Entry entry = decode(item.device, blob);
                if (entry != null) got.add(entry);
            }
            if (!got.isEmpty()) main.post(() -> deliver(got, silent));
            if (!aborted && list.size() >= 50) pollAgain.set(true);  // 50件ずつ返ってくる。続きがあれば、もう一度
            else if (!aborted && silent) prefs.setSilentNext(false);
        } catch (IOException e) {
            Log.w(TAG, "受信できませんでした: " + e.getMessage());
        }
    }

    private void advance(long seq) {
        if (seq > prefs.lastSeq()) prefs.setLastSeq(seq);
    }

    /** 先頭の1バイトで方式を見分ける（1: 端末で暗号化、2: 高速モード）。開けないものは null */
    private Inbox.Entry decode(String device, byte[] blob) {
        try {
            SyncCrypto.Opened opened;
            if (blob.length > 0 && blob[0] == 2) {
                if (quickKey == null) {
                    if (!warnedQuick) {
                        warnedQuick = true;
                        main.post(() -> toastNotification("高速モードで届いたものを開けません",
                                "Mac の「Windows・Android アプリ用のコード」で、ペアリングし直してください。"));
                    }
                    return null;
                }
                opened = SyncCrypto.openQuick(quickKey, blob);
            } else {
                opened = SyncCrypto.open(keys, blob);
            }
            String from = deviceLabel(device);
            long id = Inbox.newId();
            if ("text".equals(opened.kind)) {
                return new Inbox.Entry(id, from, "text", "", new String(opened.body, java.nio.charset.StandardCharsets.UTF_8), null, "text/plain");
            }
            if ("image".equals(opened.kind)) {
                String mime = opened.mime.isEmpty() ? "image/jpeg" : opened.mime;
                String ext = mime.contains("png") ? ".png" : mime.contains("gif") ? ".gif" : mime.contains("webp") ? ".webp" : ".jpg";
                File file = new File(Inbox.imageDir(this), "recv-" + id + "-" + System.currentTimeMillis() + ext);
                try (FileOutputStream out = new FileOutputStream(file)) {
                    out.write(opened.body);
                }
                return new Inbox.Entry(id, from, "image", opened.name, "", file, mime);
            }
        } catch (GeneralSecurityException | IOException | RuntimeException e) {
            Log.w(TAG, "開けませんでした: " + e.getMessage());
        }
        return null;
    }

    private static String deviceLabel(String device) {
        String d = device.toLowerCase();
        if (d.startsWith("iphone")) return "iPhone";
        if (d.startsWith("windows")) return "Windows";
        if (d.equals("mac")) return "Mac";
        if (d.startsWith("android")) return "Android";
        return device.isEmpty() ? "他の端末" : device;
    }

    /** 届いたものを受け取る（画面のスレッド） */
    private void deliver(List<Inbox.Entry> got, boolean silent) {
        for (Inbox.Entry e : got) Inbox.add(e);
        if (silent) {
            Inbox.notifyChanged();
            return;
        }
        Inbox.Entry newest = got.get(got.size() - 1);  // 一覧は古い順なので、最後がいちばん新しい
        boolean copied = false;
        if (prefs.autoCopy()) {
            try {
                Clips.setEntry(this, newest);
                copied = true;
            } catch (RuntimeException e) {
                Log.w(TAG, "クリップボードに入れられませんでした: " + e.getMessage());
            }
        }
        arrivalNotification(newest, copied);
        Inbox.notifyChanged();
    }

    // ---- 通知 ----

    private void createChannels() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL_STATUS, "接続の状態", NotificationManager.IMPORTANCE_LOW));
        nm.createNotificationChannel(new NotificationChannel(CHANNEL_ARRIVAL, "届いたとき", NotificationManager.IMPORTANCE_DEFAULT));
    }

    private void startForegroundCompat(Notification notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_STATUS, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIFICATION_STATUS, notification);
        }
    }

    private static final int PI_FLAGS = PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;

    private Notification statusNotification(String text) {
        PendingIntent open = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PI_FLAGS);
        PendingIntent send = PendingIntent.getActivity(this, 1,
                new Intent(this, SendClipboardActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PI_FLAGS);
        PendingIntent stop = PendingIntent.getService(this, 2, new Intent(this, SyncService.class).setAction(ACTION_STOP), PI_FLAGS);
        return new Notification.Builder(this, CHANNEL_STATUS)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle("クリップ棚")
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(open)
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_stat), "今のコピーを送る", send).build())
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_stat), "接続を切る", stop).build())
                .build();
    }

    private void arrivalNotification(Inbox.Entry entry, boolean copied) {
        PendingIntent open = PendingIntent.getActivity(this, 10,
                new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PI_FLAGS);
        Notification.Builder b = new Notification.Builder(this, CHANNEL_ARRIVAL)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle(entry.device + "から届きました")
                .setContentText(entry.summary() + (copied ? "（クリップボードに入れました）" : ""))
                .setAutoCancel(true)
                .setTimeoutAfter(20_000)
                .setContentIntent(open);
        if (!copied) {
            PendingIntent copy = PendingIntent.getBroadcast(this, (int) entry.id,
                    new Intent(this, CopyReceiver.class).putExtra("id", entry.id), PI_FLAGS);
            b.addAction(new Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_stat), "コピー", copy).build());
        }
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(100 + (int) (entry.id % 1000), b.build());
    }

    private void toastNotification(String title, String text) {
        Notification n = new Notification.Builder(this, CHANNEL_ARRIVAL)
                .setSmallIcon(R.drawable.ic_stat).setContentTitle(title).setContentText(text).setAutoCancel(true).build();
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(99, n);
    }
}
