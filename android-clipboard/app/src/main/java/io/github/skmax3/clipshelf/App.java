package io.github.skmax3.clipshelf;

import android.app.Application;

/** アプリの起動時に、保存してある履歴を読み込む */
public final class App extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        Inbox.init(this);
    }
}
