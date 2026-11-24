package io.github.skmax3.clipshelf;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.widget.Toast;

/** 通知の「コピー」ボタン。届いたものを、クリップボードに入れる */
public final class CopyReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        Inbox.Entry entry = Inbox.get(intent.getLongExtra("id", -1));
        if (entry == null) {
            Toast.makeText(context, "もう取り出せません", Toast.LENGTH_LONG).show();
            return;
        }
        try {
            Clips.setEntry(context, entry);
            Toast.makeText(context, "コピーしました", Toast.LENGTH_SHORT).show();
        } catch (RuntimeException e) {
            Toast.makeText(context, "コピーできませんでした", Toast.LENGTH_LONG).show();
        }
    }
}
