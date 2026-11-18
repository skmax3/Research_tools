# 画面切り替え（Windows 用・下書き）

デスクトップ PC と MacBook Air で、2 台のモニターを入れ替えて使うための `.bat` ファイル。ダブルクリック 1 回で、ゲームを出すモニターを切り替える。

| モード | Dell S2725QS（27 型 4K） | BenQ EX2510S（24.5 型 FHD） | 実行するファイル |
|---|---|---|---|
| 4K でゲーム | PC（メイン・ゲーム） | Mac | `switch-game4k.bat` |
| Mac 作業 | Mac | PC（メイン・ゲーム） | `switch-macwork.bat` |

Mac の映像の行き先は、双方向 HDMI 切替器（サンワサプライ 400-SW034）のボタンで変える。Mac 側の設定は不要。

> まだ実機で動かしていない下書き。試して直していく。

## ファイル
| ファイル | 役割 |
|---|---|
| `switch-game4k.bat` | 4K でゲーム：Dell を PC のメインにし、BenQ への出力を止める |
| `switch-macwork.bat` | Mac 作業：BenQ を PC のメインにし、Dell への出力を止める |
| `save-config.bat` | 最初に 1 回。今の Windows の画面設定を、上の 2 つのモードとして保存する |
| `settings.bat` | 自分の環境に合わせて書き換える場所（入力の番号・モニターの ID） |

`.bat` は文字化けしないよう Shift_JIS・CRLF で保存している（`.gitattributes` で Git に変換させない）。メモ帳で編集するときは文字コードを変えずに保存する。
GitHub の画面では日本語が化けて見えるが、Windows では正しく表示される。

## 配線
```
PC  --DP-->  Dell の DP
PC  --DP-->  BenQ の DP
Mac --USB-C→HDMI-->  切替器の「1 入力」側
切替器の出力 1 --HDMI-->  Dell の HDMI 1
切替器の出力 2 --HDMI-->  BenQ の HDMI 1
```
別の HDMI 端子につないだら、`settings.bat` の番号を 18 にする。

## 最初の準備（1 回だけ）
1. このフォルダを Windows の好きな場所に置く（GitHub Desktop で取得したリポジトリの中のままでもよい）
2. NirSoft の [MultiMonitorTool](https://www.nirsoft.net/utils/multi_monitor_tool.html)（64 ビット版）をダウンロードし、`MultiMonitorTool.exe` をこのフォルダに入れる（Git には入らない）
3. Windows の「設定 → システム → ディスプレイ」で、Dell を「メイン ディスプレイにする」、BenQ を「このディスプレイを切断する」にしてから、`save-config.bat` を開いて「1」を押す
4. 同じ画面で BenQ を表示させてメインにし、Dell を「このディスプレイを切断する」にしてから、`save-config.bat` を開いて「2」を押す
5. Dell・BenQ それぞれのメニュー（OSD）で、入力の「自動選択」があればオンにする

## ふだんの使い方
- 4K でゲームにする：切替器を BenQ 側にする → `switch-game4k.bat` をダブルクリック
- Mac 作業にする：切替器を Dell 側にする → `switch-macwork.bat` をダブルクリック

キーで呼びたいとき：`.bat` を右クリック →「ショートカットの作成」→ ショートカットをデスクトップに移す → 右クリック「プロパティ」→「ショートカット キー」に Ctrl + Alt + G などを設定する。

## モニターが自動で入力を切り替えないとき
1. NirSoft の [ControlMyMonitor](https://www.nirsoft.net/utils/control_my_monitor.html) をダウンロードし、`ControlMyMonitor.exe` をこのフォルダに入れる
2. ControlMyMonitor を開き、上の一覧で Dell・BenQ を選んで、出てくる Monitor ID（または Short Monitor ID）を `settings.bat` に貼る
3. `settings.bat` の `USE_DDC` を `1` にする

モニターは「今映している入力」からの命令（DDC）しか受け付けないことが多い。PC が映っているモニターを Mac 側へ切り替えるのは効くが、Mac が映っているモニターを PC 側へ戻すのは効かないことがある。そのときはモニターのボタンで入力を選ぶ。

## うまくいかないとき
- 切り替えても何も変わらない：Windows 11 24H2 では MultiMonitorTool が効かないことがある。最新版（v2.20 以降）にする。だめなら画面の設定を一度手で変えてから試す。それでもだめなら、Windows の画面設定を直接変える小さなツールを自作する。
- ゲームが前のモニターに出る：ゲームの設定で表示するモニターを選ぶ。全画面のゲームは一度ウィンドウモードにしてから戻す。
