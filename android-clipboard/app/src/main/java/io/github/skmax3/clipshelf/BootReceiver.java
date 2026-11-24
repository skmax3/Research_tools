package io.github.skmax3.clipshelf;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** 端末を起動したときに、待ち続けるサービスを自動で始める（ペアリング済みで、「接続を切る」にしていないとき） */
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        Prefs prefs = new Prefs(context);
        if (!prefs.paired() || !prefs.serviceEnabled()) return;
        try {
            context.startForegroundService(new Intent(context, SyncService.class));
        } catch (RuntimeException e) {
            // 起動直後は、始められないことがある。アプリを開いたときに始まる
        }
    }
}
