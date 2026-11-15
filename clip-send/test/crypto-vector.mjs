// 暗号の取り決めの確認。
//  1) ページのコード（WebCrypto）と、Node 標準の暗号（別の実装）が同じ結果になること
//  2) Mac 側（Swift）の確認に使う固定の値を出力すること（mac-clipboard/Tests/main.swift に貼る）
// 使い方: node clip-send/test/crypto-vector.mjs [--swift]
import fs from 'node:fs';
import nodeCrypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const html = fs.readFileSync(path.join(here, '../index.html'), 'utf8');
const code = html.slice(html.indexOf('/* SYNC-BEGIN */'), html.indexOf('/* SYNC-END */'));
const Sync = new Function(code + ';return Sync')();

let fail = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fail++; };
const hex = (u8) => Buffer.from(u8).toString('hex');

// 固定の入力
const secretBytes = Uint8Array.from({ length: 32 }, (_, i) => i);
const secret = Sync.b64u(secretBytes);
const nonce = Uint8Array.from({ length: 12 }, (_, i) => i);
const metaJson = '{"k":"text","name":"","mime":"text/plain"}';
const bodyText = 'こんにちは, clip!';
const body = new TextEncoder().encode(bodyText);

// ページ側の実装
const keys = await Sync.derive(secret);
const sealed = await Sync.seal(keys.key, metaJson, body, nonce);

// 別の実装（node:crypto）で同じものを作る
const salt = Buffer.from('clipshelf-v1');
const hk = (info, n) => Buffer.from(nodeCrypto.hkdfSync('sha256', Buffer.from(secretBytes), salt, Buffer.from('clipshelf-v1 ' + info), n));
const room2 = hk('room', 16).toString('base64url');
const key2 = hk('enc', 32);
const meta = Buffer.from(metaJson);
const len = Buffer.alloc(4); len.writeUInt32BE(meta.length);
const pt = Buffer.concat([len, meta, Buffer.from(body)]);
const c = nodeCrypto.createCipheriv('aes-256-gcm', key2, Buffer.from(nonce));
c.setAAD(Buffer.from('clipshelf-v1'));
const ct = Buffer.concat([c.update(pt), c.final(), c.getAuthTag()]);
const sealed2 = Buffer.concat([Buffer.from([1]), Buffer.from(nonce), ct]);

ok(keys.room === room2, `部屋IDが一致（${keys.room}）`);
ok(keys.room.length === 22, '部屋IDは22文字（中継サーバーの条件を満たす）');
ok(hex(sealed) === sealed2.toString('hex'), '暗号文が一致（WebCrypto と node:crypto）');

// 復号（ページ側）と、別の実装での復号
const opened = await Sync.open(keys.key, sealed);
ok(opened.meta.k === 'text' && new TextDecoder().decode(opened.body) === bodyText, 'ページ側で復号できる');
const d = nodeCrypto.createDecipheriv('aes-256-gcm', key2, sealed2.subarray(1, 13));
d.setAAD(Buffer.from('clipshelf-v1')); d.setAuthTag(sealed2.subarray(sealed2.length - 16));
const pt2 = Buffer.concat([d.update(sealed2.subarray(13, sealed2.length - 16)), d.final()]);
ok(pt2.equals(pt), 'node:crypto で復号できる');

// 改ざん・別の鍵は拒否される
const bad = Uint8Array.from(sealed); bad[bad.length - 1] ^= 1;
ok(await Sync.open(keys.key, bad).then(() => false, () => true), '改ざんされたデータは復号できない');
const other = await Sync.derive(Sync.newSecret());
ok(await Sync.open(other.key, sealed).then(() => false, () => true), '別の鍵では復号できない');
ok(other.room !== keys.room, '別の秘密からは別の部屋ID');

// 大きいデータ（3MB）
const big = Uint8Array.from({ length: 3 * 1024 * 1024 + 5 }, (_, i) => (i * 7) & 255);
const bigOpened = await Sync.open(keys.key, await Sync.seal(keys.key, { k: 'image', name: 'a.jpg', mime: 'image/jpeg' }, big));
ok(bigOpened.body.length === big.length && bigOpened.body.every((v, i) => v === big[i]), '3MBの往復');

if (process.argv.includes('--swift')) {
  console.log(`
// ---- mac-clipboard/Tests/main.swift に貼る固定の値（crypto-vector.mjs --swift で出力）----
let vecSecret = "${secret}"
let vecRoom = "${keys.room}"
let vecMeta = #"${metaJson}"#
let vecBody = "${bodyText}"
let vecNonceHex = "${hex(nonce)}"
let vecSealedHex = "${hex(sealed)}"`);
}
console.log(fail ? `${fail}件失敗` : 'すべて成功');
process.exit(fail ? 1 : 0);
