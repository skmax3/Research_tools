// 高速モードのテスト。別のターミナルで `npx wrangler dev --local --port 8799` を動かしてから `node test/quick.mjs` を実行する。
// Mac 役は、サーバーのコードを使わず node:crypto だけで復号する（仕様どおりに作れていることの確認）。
// `--swift` を付けると、Swift 側のテスト（mac-clipboard/Tests/main.swift）に貼る固定の値を出力する。
import nodeCrypto from 'node:crypto';
import { sealQuick, sniff } from '../src/quick.js';

const B = 'http://127.0.0.1:8799';
let fail = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fail++; };
const hex = (u8) => Buffer.from(u8).toString('hex');

// Mac 役の鍵（P-256）
function newMac(d) {
  const ecdh = nodeCrypto.createECDH('prime256v1');
  d ? ecdh.setPrivateKey(d) : ecdh.generateKeys();
  return { ecdh, pub: ecdh.getPublicKey() };
}
function openQuick(ecdh, blob) {
  if (blob[0] !== 2) throw new Error('version');
  const ephPub = blob.subarray(1, 66), nonce = blob.subarray(66, 78), rest = blob.subarray(78);
  const shared = ecdh.computeSecret(ephPub);
  const key = Buffer.from(nodeCrypto.hkdfSync('sha256', shared, Buffer.from('clipshelf-v1'), Buffer.from('clipshelf-v1 quick'), 32));
  const d = nodeCrypto.createDecipheriv('aes-256-gcm', key, nonce);
  d.setAAD(Buffer.from('clipshelf-v1'));
  d.setAuthTag(rest.subarray(rest.length - 16));
  const pt = Buffer.concat([d.update(rest.subarray(0, rest.length - 16)), d.final()]);
  const n = pt.readUInt32BE(0);
  return { meta: JSON.parse(pt.subarray(4, 4 + n)), body: pt.subarray(4 + n) };
}

// ---- 1. 種類の判定 ----
const u8 = (...a) => Uint8Array.from(a);
ok(sniff(u8(0xff, 0xd8, 0xff, 0xe0, 0, 0)).ext === 'jpg', '判定: JPEG');
ok(sniff(u8(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)).ext === 'png', '判定: PNG');
ok(sniff(Buffer.from('GIF89a....')).ext === 'gif', '判定: GIF');
ok(sniff(Buffer.concat([Buffer.alloc(4), Buffer.from('ftypheic'), Buffer.alloc(4)])).ext === 'heic', '判定: HEIC');
ok(sniff(Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WEBP')])).ext === 'webp', '判定: WebP');
ok(sniff(new TextEncoder().encode('こんにちは')).kind === 'text', '判定: 日本語のテキスト');
ok(sniff(u8(0xff, 0xfe, 0x00, 0x01, 0x02)) === null && sniff(new Uint8Array(0)) === null, '判定: 文字でも画像でもないものは拒否');

// ---- 2. 暗号（サーバーのコード → 別の実装で復号） ----
const mac = newMac();
const sealed = await sealQuick(mac.pub, { k: 'text', name: '', mime: 'text/plain' }, new TextEncoder().encode('φ = 30°'));
const o = openQuick(mac.ecdh, Buffer.from(sealed));
ok(o.meta.k === 'text' && o.body.toString() === 'φ = 30°', '別の実装（node:crypto）で復号できる');
ok(sealed.length === 1 + 65 + 12 + (4 + JSON.stringify({ k: 'text', name: '', mime: 'text/plain' }).length + Buffer.byteLength('φ = 30°')) + 16, '長さが取り決めどおり');
let rejected = false;
try { openQuick(newMac().ecdh, Buffer.from(sealed)); } catch (_) { rejected = true; }
ok(rejected, '別の Mac の鍵では復号できない');
const bad = Buffer.from(sealed); bad[bad.length - 1] ^= 1;
rejected = false; try { openQuick(mac.ecdh, bad); } catch (_) { rejected = true; }
ok(rejected, '改ざんは復号できない');

// ---- 3. 中継サーバー（ローカル）----
const room = nodeCrypto.randomBytes(16).toString('base64url');
const quick = (r, body, headers = {}) => fetch(`${B}/r/${r}/quick`, { method: 'POST', body, headers });
let r = await quick(room, 'こんにちは');
ok(r.status === 409, '公開鍵の登録前は 409（ペアリングが必要）');
r = await fetch(`${B}/r/${room}/pub`, { method: 'PUT', body: Buffer.from('short') });
ok(r.status === 400, '不正な鍵は 400');
r = await fetch(`${B}/r/${room}/pub`, { method: 'PUT', body: mac.pub });
ok(r.status === 201, '公開鍵を登録できる');
r = await fetch(`${B}/r/${room}/pub`, { method: 'PUT', body: mac.pub });
ok(r.status === 200, '同じ鍵の再登録は 200');
r = await fetch(`${B}/r/${room}/pub`, { method: 'PUT', body: newMac().pub });
ok(r.status === 409, '別の鍵での上書きは 409');
r = await fetch(`${B}/r/${room}/pub`);
ok(Buffer.from(await r.arrayBuffer()).equals(mac.pub), '登録された公開鍵を取得できる');

const list = async (after = 0) => (await (await fetch(`${B}/r/${room}/items?after=${after}`)).json()).items;
const get = async (s) => Buffer.from(await (await fetch(`${B}/r/${room}/items/${s}`)).arrayBuffer());

// ウェブソケットで新着が届く
const ws = new WebSocket(`ws://127.0.0.1:8799/r/${room}/ws`);
const notified = new Promise((res) => { ws.onmessage = (e) => { if (e.data !== 'pong') res(JSON.parse(e.data)); }; setTimeout(() => res(null), 5000); });
await new Promise((res) => (ws.onopen = res));

r = await quick(room, 'ショートカットから😀\n2行目');
ok(r.status === 201, 'テキストを高速モードで送れる');
const info = await notified; ws.close();
ok(info && info.dev === 'iphone-quick', 'WebSocket で新着が届く');
let items = await list();
ok(items.length === 1 && items[0].dev === 'iphone-quick', '保存された');
let q = openQuick(mac.ecdh, await get(items[0].seq));
ok(q.meta.k === 'text' && q.body.toString() === 'ショートカットから😀\n2行目', 'Mac 役が復号でき、中身が一致');
const raw = await get(items[0].seq);
ok(!raw.includes(Buffer.from('ショートカット')), 'サーバーに保存されたデータに平文が含まれない');

// 画像（PNG・JPEG・HEIC）
const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), nodeCrypto.randomBytes(3 * 1024 * 1024)]);
r = await quick(room, png); ok(r.status === 201, '3MB の画像を送れる');
items = await list(items[0].seq); q = openQuick(mac.ecdh, await get(items[0].seq));
ok(q.meta.k === 'image' && q.meta.mime === 'image/png' && q.meta.name === 'iPhoneから.png' && q.body.equals(png), '画像がバイト単位で一致');
const heic = Buffer.concat([Buffer.alloc(4), Buffer.from('ftypheic'), nodeCrypto.randomBytes(100)]);
r = await quick(room, heic); items = await list(items[0].seq);
q = openQuick(mac.ecdh, await get(items[0].seq)); ok(q.meta.mime === 'image/heic' && q.body.equals(heic), 'HEIC も送れる');

// 拒否されるもの
r = await quick(room, Buffer.from([0xff, 0xfe, 0x00, 0x01])); ok(r.status === 415, '文字でも画像でもないものは 415');
r = await quick(room, Buffer.alloc(0)); ok(r.status === 415, '空は拒否');
// 大きすぎるものは、413 で断るか、本体を読む前に接続を閉じる（どちらでも送れないことに変わりはない）
const tooBig = await quick(room, Buffer.alloc(9 * 1024 * 1024, 65)).then((x) => x.status, () => 'closed');
ok(tooBig === 413 || tooBig === 'closed', '8MB 超は送れない（' + tooBig + '）');
ok((await list()).length === 3, '8MB 超は保存されていない');

// 通常の送信（暗号化済み）との併用と、解除
r = await fetch(`${B}/r/${room}/items`, { method: 'POST', body: Buffer.from([1, 2, 3]), headers: { 'x-device': 'mac' } });
ok(r.status === 201, '通常の送信も使える');
r = await fetch(`${B}/r/${room}/items`, { method: 'DELETE' });
ok((await list()).length === 0, '解除で中身が消える');
r = await quick(room, 'x'); ok(r.status === 409, '解除した部屋には、高速モードでも送れない');

if (process.argv.includes('--swift')) {
  // 固定の受信側の鍵と、固定の使い捨ての鍵・nonce で作った、Swift 側のテスト用の値
  const d = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
  const m = newMac(d);
  const e = newMac(Buffer.from(Array.from({ length: 32 }, (_, i) => 100 + i)));
  const jwk = (k) => ({ kty: 'EC', crv: 'P-256', x: k.pub.subarray(1, 33).toString('base64url'), y: k.pub.subarray(33).toString('base64url') });
  const ephKey = {
    privateKey: await crypto.subtle.importKey('jwk', { ...jwk(e), d: Buffer.from(Array.from({ length: 32 }, (_, i) => 100 + i)).toString('base64url') }, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']),
    publicKey: await crypto.subtle.importKey('jwk', jwk(e), { name: 'ECDH', namedCurve: 'P-256' }, true, []),
  };
  const nonce = Uint8Array.from({ length: 12 }, (_, i) => 50 + i);
  const metaJson = '{"k":"text","name":"","mime":"text/plain"}';
  const bodyText = 'ショートカット, quick!';
  const blob = await sealQuick(m.pub, metaJson, new TextEncoder().encode(bodyText), { eph: ephKey, nonce });
  openQuick(m.ecdh, Buffer.from(blob));  // 念のため、作った値が復号できることを確認
  console.log(`
// ---- mac-clipboard/Tests/main.swift に貼る固定の値（quick.mjs --swift で出力）----
let quickPrivateHex = "${hex(d)}"
let quickPublicHex = "${hex(m.pub)}"
let quickBody = "${bodyText}"
let quickSealedHex = "${hex(blob)}"`);
}
console.log(fail ? `${fail}件失敗` : 'すべて成功');
process.exit(fail ? 1 : 0);
