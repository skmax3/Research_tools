# clip-relay（クリップ棚の中継サーバー）

Mac のクリップ棚と iPhone の間で、**端末側で暗号化されたデータ**を一時的に預かって渡すだけの小さなサーバー（Cloudflare Workers + Durable Objects、無料プランで動く）。

- サーバーは鍵を持たないので、中身は読めない（暗号文と、送った時刻・端末名・サイズだけを見る）。
- 部屋ID は、2台が QR で共有した秘密から作る推測できない文字列。部屋ごとに保存場所が分かれる。
- 保存は 24 時間で自動削除。1件 8MB まで、部屋ごとに 30 件・合計 40MB まで（古いものから消える）。
- 配置は、`main` に入ると GitHub Actions（`.github/workflows/clip-relay.yml`）が自動で行う。事前に GitHub の Secrets へ `CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を登録しておく。

## API
| メソッド・パス | 内容 |
|---|---|
| `POST /r/<部屋ID>/items` | 暗号文を置く（本文＝バイナリ、ヘッダー `x-device`＝端末名） |
| `GET /r/<部屋ID>/items?after=N` | N より新しい項目の一覧（48KB 以下は中身も base64 で入る） |
| `GET /r/<部屋ID>/items/<番号>` | 1件の中身（バイナリ） |
| `DELETE /r/<部屋ID>/items` | 部屋の中身を全部消す |
| `GET /r/<部屋ID>/ws` | WebSocket。新しい項目が置かれると `{seq,t,dev,size}` が届く |
| `PUT /r/<部屋ID>/pub` | Mac の公開鍵（P-256、65バイト）を登録する。1回だけ登録でき、別の鍵での上書きは 409 |
| `GET /r/<部屋ID>/pub` | 登録されている公開鍵 |
| `POST /r/<部屋ID>/quick` | 高速モード。iPhone の「ショートカット」から平文（テキスト・画像）を送ると、サーバーが Mac の公開鍵で暗号化してから保存する |

## 高速モードについて
「ショートカット」アプリには暗号化の機能がなく、通常の方式（端末で暗号化）では、ページを開いて送る必要がある。
高速モードは、ショートカットが直接送れるように、**サーバーが受け取った内容を、保存する直前に Mac の公開鍵で暗号化する**（ECDH P-256 + AES-256-GCM。仕様は `src/quick.js`）。

- 保存されるのは Mac だけが開ける暗号文で、平文は保存しない。Mac の秘密鍵は Mac の外に出ない。
- ただし、サーバーのプログラムは、処理の間だけ平文を扱う（通常の方式では、サーバーは平文を一切扱わない）。通信は HTTPS。
- 部屋ID を知っていると、送ることはできる（読むことはできない）。公開鍵は1回しか登録できないので、あとから自分の鍵に差し替えて読み取ることはできない。解除（部屋の削除）すると、送れなくなる。
- 機密は送らない運用をおすすめする。

## 他の端末から送る（Windows・Android・ターミナル）
高速モードの宛先（クリップ棚のペアリング画面に表示される `https://…/r/<部屋ID>/quick`）は、ただの HTTP POST なので、本文を送れるものなら何でも使える。Mac のクリップ棚が受け取って、履歴に入れる（受け取れるのは今のところ Mac だけ）。

| 端末・道具 | 方法 | 状態 |
|---|---|---|
| Mac・Linux のターミナル（`curl`） | `printf 'こんにちは' \| curl -X POST --data-binary @- "<宛先>"`（画像は `curl -X POST --data-binary @写真.png "<宛先>"`） | 動作確認済み（`-d` ではなく `--data-binary` を使う） |
| Windows（PowerShell） | 下の例 | 未確認（書き方の例） |
| Android | 無料アプリ「HTTP Shortcuts」で、POST・本文「クリップボード」（または共有されたファイル）のショートカットを作る | 未確認（方法の見当） |

Windows（PowerShell）の例。日本語が文字化けしないように、先に出力の文字コードを UTF-8 にする。
```powershell
$OutputEncoding = [Text.UTF8Encoding]::new()
Get-Clipboard -Raw | curl.exe -s -X POST --data-binary "@-" "<宛先>"
```
Windows でクリップボードの画像を送る例:
```powershell
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = "$env:TEMP\clip.png"
[System.Windows.Forms.Clipboard]::GetImage().Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
curl.exe -s -X POST --data-binary "@$f" "<宛先>"
```
送れるのはテキスト・JPEG・PNG・GIF・WebP・HEIC で、1件 8MB まで。宛先には部屋ID が入っているので、人に見せない。

## ローカルで試す
```
cd clip-relay
npx wrangler dev --local --port 8799     # 1つ目のターミナル
node test/smoke.mjs                       # 2つ目のターミナル（16項目のテスト）
node test/quick.mjs                       # 高速モードのテスト（別の実装での復号を含む）
```
