// 高速モード（iPhone の「ショートカット」から直接送る）用の暗号。
// ショートカットは暗号化できないので、サーバーが受け取った瞬間に、Mac の公開鍵で暗号化してから保存する。
// 保存されるのは Mac だけが開ける暗号文で、平文は保存しない（サーバーのプログラムが処理の間だけ平文を扱う）。
//
//   送るデータ = [0x02][使い捨ての公開鍵 65バイト][nonce 12バイト][AES-GCM の暗号文＋タグ16バイト]
//   鍵の作り方 = ECDH P-256（使い捨ての秘密鍵 × Mac の公開鍵）→ HKDF-SHA256（salt="clipshelf-v1", info="clipshelf-v1 quick"）→ AES-256-GCM
//   追加認証データ = "clipshelf-v1"、暗号化する中身は通常の送信と同じ（[メタ情報の長さ 4バイト][メタ情報 JSON][本体]）
//   Mac 側の復号は mac-clipboard/Sources/SyncCrypto.swift の openQuick

const TAG = "clipshelf-v1";
const enc = new TextEncoder();

const ascii = (b, from, to) => String.fromCharCode(...b.subarray(from, to));

/** 送られてきたデータの種類を、中身の先頭から判定する。分からなければ null */
export function sniff(b) {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { kind: "image", mime: "image/jpeg", ext: "jpg" };
  if (b.length >= 8 && b[0] === 0x89 && ascii(b, 1, 4) === "PNG") return { kind: "image", mime: "image/png", ext: "png" };
  if (b.length >= 6 && ascii(b, 0, 4) === "GIF8") return { kind: "image", mime: "image/gif", ext: "gif" };
  if (b.length >= 12 && ascii(b, 0, 4) === "RIFF" && ascii(b, 8, 12) === "WEBP") return { kind: "image", mime: "image/webp", ext: "webp" };
  if (b.length >= 12 && ascii(b, 4, 8) === "ftyp" && ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].includes(ascii(b, 8, 12))) {
    return { kind: "image", mime: "image/heic", ext: "heic" };
  }
  if (b.length === 0) return null;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(b);
    if (!text.includes("\u0000")) return { kind: "text", mime: "text/plain", ext: "txt" };
  } catch (_) { /* 文字ではない */ }
  return null;
}

/** pubRaw: Mac の公開鍵（65バイト、先頭 0x04）。fixed はテスト用（使い捨ての鍵と nonce を固定する） */
export async function sealQuick(pubRaw, meta, body, fixed) {
  const recipient = await crypto.subtle.importKey("raw", pubRaw, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const eph = fixed?.eph || await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: recipient }, eph.privateKey, 256);
  const ikm = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveBits"]);
  const keyBits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode(TAG), info: enc.encode(TAG + " quick") }, ikm, 256);
  const key = await crypto.subtle.importKey("raw", keyBits, "AES-GCM", false, ["encrypt"]);
  const ephPub = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));

  const m = enc.encode(typeof meta === "string" ? meta : JSON.stringify(meta));
  const plain = new Uint8Array(4 + m.length + body.length);
  new DataView(plain.buffer).setUint32(0, m.length);
  plain.set(m, 4);
  plain.set(body, 4 + m.length);

  const nonce = fixed?.nonce || crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: enc.encode(TAG), tagLength: 128 }, key, plain));
  const out = new Uint8Array(1 + 65 + 12 + ct.length);
  out[0] = 2;
  out.set(ephPub, 1);
  out.set(nonce, 66);
  out.set(ct, 78);
  return out;
}
