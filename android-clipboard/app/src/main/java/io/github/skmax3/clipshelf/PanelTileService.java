package io.github.skmax3.clipshelf;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/** クイック設定のタイル。1回タップすると、履歴パネルが開く */
public final class PanelTileService extends TileService {
    @Override
    public void onStartListening() {
        Tile tile = getQsTile();
        if (tile != null) {
            tile.setState(Tile.STATE_INACTIVE);
            tile.updateTile();
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onClick() {
        Intent intent = new Intent(this, PanelActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 1, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        } else {
            startActivityAndCollapse(intent);
        }
    }
}
