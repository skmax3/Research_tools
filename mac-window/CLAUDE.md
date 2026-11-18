# 窓割り（mac-window）の開発メモ

ユーザーや Claude がこのアプリを直すときに最初に読むファイル。使い方は README.md、仕様と今後の候補は SPEC.md。

## ビルドと確認
- このクラウド環境では Mac アプリをビルドできない。push すると GitHub Actions（`.github/workflows/mac-window.yml`）が
  テスト（`Tests/main.swift`）とビルドを行い、作業ブランチなら Xcode プロジェクトを自動生成してコミットする。
- テストできるのは「画面やイベントに触らない計算」だけ（`Geometry.swift`・`Presets.swift`・`EdgeLogic.swift`・`KeyCombo.swift`・`Layouts.swift`）。
  計算を足したら、なるべくこれらのファイルに置いてテストを書く。新しいファイルをテストに含めるときは、ワークフローの `swiftc` の行にも足す。
- 動作確認はユーザーの Mac で行う。メニュー「最新版にアップデート…」で、main の最新版がビルドされて入れ替わる。

## ファイルの役割
| ファイル | 役割 |
|---|---|
| `App.swift` | 入口・メニューバー・ショートカットの登録・操作の振り分け（`perform`） |
| `Shortcuts.swift` | ショートカットの一覧（操作の種類 `WindowAction` と初期のキー） |
| `KeyCombo.swift` | キーの組み合わせ（表示・保存）※テストあり |
| `HotKey.swift` | グローバルショートカット（Carbon）。クリップ棚と同じ |
| `AppSettings.swift` | 設定の保存（UserDefaults） |
| `Geometry.swift` | 場所（画面に対する割合）→ ウィンドウの枠、座標変換、最小サイズに合わせた並び直し（`Fit`） ※テストあり |
| `Presets.swift` | 配置プリセットの形・初期値、よく使うアプリ ※テストあり |
| `WindowMover.swift` | アクセシビリティ API でウィンドウを読む・動かす。フルスクリーン解除、AI と並べる、プリセット |
| `StageManager.swift` | ステージマネージャのオン・オフを読む・切り替える（まとめて並べる前にオフにする） |
| `Desktops.swift` | デスクトップの切り替え（システムのキーを送る）、今のデスクトップに見えているウィンドウ |
| `EdgeLogic.swift` | 境目でカーソルを止める判定 ※テストあり |
| `EdgeBarrierController.swift` | マウスの動きを受け取って、境目でカーソルを止める（イベントタップ） |
| `GridSelector.swift` | マス目の図（設定画面と配置パネルで共通） |
| `Layouts.swift` | 配置パネルの「配置案」のひな形 ※テストあり |
| `WindowList.swift` | 開いているウィンドウの一覧（手前から順。フルスクリーン・別のデスクトップも） |
| `LayoutBoard.swift` | 配置パネルの中身（配置案を選ぶ → 枠にウィンドウをドラッグ → 並べる）と、その状態 |
| `GridPicker.swift` | 配置パネルの窓を出す・閉じる、並べる・保存する |
| `Toast.swift` | 動かしたときに場所の名前を一瞬出す表示、メニュー用の小さな図 |
| `SettingsView.swift` | 設定画面（SwiftUI）：配置プリセット・AI・ショートカット・カーソルと動き方 |

## よくある変更のしかた
- **配置案を増やす**: `Layouts.swift` の `LayoutTemplate.builtIn` に 1 行足す。テストが、はみ出し・重なりを確かめる。
- **場所を増やす**（例「左 2/5」）: `Geometry.swift` の `NamedZone` に case・`title`・`group`・`zone` を足す。テストは自動で全部の場所を確かめる。
- **ショートカットの操作を増やす**: `Shortcuts.swift` の一覧に 1 行足す（`id` は保存に使うので、あとで変えない）。
  新しい種類の操作なら `WindowAction` に case を足し、`App.swift` の `perform` に処理を書く。設定画面とメニューには自動で出る。
- **初期のプリセットを変える**: `Presets.swift` の `Preset.defaults`。すでに使っている人の設定は変わらない（設定画面の「最初の状態に戻す」で反映）。
- **よく使うアプリを足す**: `Presets.swift` の `KnownApp`（バンドル ID は、ターミナルで `osascript -e 'id of app "アプリ名"'`）。
- **設定を足す**: `AppSettings.swift` の手順コメントどおり。設定画面は `SettingsView.swift` の各タブに部品を足す。

## 注意
- 座標は 2 種類ある。macOS の画面（`NSScreen`・`NSWindow`）は左下原点・上向き。アクセシビリティ・`CGEvent` は左上原点・下向き。
  このアプリの計算は左上原点にそろえ、自分の窓を置くときだけ `WindowMover.toCocoa` で変換する。
- `let area = area(for:)` のように、変数名とメソッド名が同じだと Swift ではエラーになる。`self.area(for:)` と書く。
- ステージマネージャがオンだと、アプリを手前に出す（`raise`）たびに前のアプリが左の帯にしまわれる。
  2 つ以上のアプリを並べる処理は `WindowMover.whenStageManagerOff` を通す。
- アプリには最小のウィンドウサイズがあり、小さな画面では指定どおりの幅にならないことがある。まとめて並べたあとは
  `WindowMover.refit`（計算は `Geometry.swift` の `Fit.refit`、テストあり）で、ほかの列を細くして重ならないようにしている。
- アプリの最小サイズは `AppSettings.minSizes`（バンドル ID → pt）。測る・覚えるのは `WindowMover.measureMinSize` / `learnMinSize`、
  配置パネルの警告・おすすめは `LayoutBoardModel` の `fits` / `slotNote` / `recommendation`（判定の計算は `Fit.check` / `Fit.recommend`、テストあり）。
- 返答・UI・コメントは日本語。外部ライブラリは使わない。
