// 中継サーバーの動作テスト。別のターミナルで `npx wrangler dev --local --port 8799` を動かしてから `node test/smoke.mjs` を実行する。
const B='http://127.0.0.1:8799';let fail=0;
const ok=(c,m)=>{console.log((c?'PASS ':'FAIL ')+m);if(!c)fail++};
const room='A'.repeat(43);
const post=(r,body,dev='mac')=>fetch(`${B}/r/${r}/items`,{method:'POST',body,headers:{'x-device':dev}});
const list=async(r,after=0)=>(await fetch(`${B}/r/${r}/items?after=${after}`)).json();

// 1. 不正な部屋ID
ok((await fetch(`${B}/r/short/items`)).status===404,'短い部屋IDは404');
// 2. 空の部屋
ok((await list(room)).items.length===0,'最初は空');
// 3. 小さい項目 → 一覧に中身が入る
const small=new Uint8Array([1,2,3,4,5]);
let r=await post(room,small);const i1=await r.json();
ok(r.status===201&&i1.seq>0&&i1.size===5&&i1.dev==='mac','小さい項目を置ける');
let l=await list(room);
ok(l.items.length===1&&l.items[0].data===btoa('\x01\x02\x03\x04\x05'),'一覧に中身が入る');
// 4. after
ok((await list(room,i1.seq)).items.length===0,'after で新しいものだけ');
// 5. 大きい項目（3MB、複数チャンク）→ 一覧には中身なし、個別取得でバイト一致
const big=new Uint8Array(3*1024*1024+17);for(let i=0;i<big.length;i++)big[i]=(i*31+7)&255;
r=await post(room,big,'iphone');const i2=await r.json();
ok(r.status===201&&i2.size===big.length,'3MBの項目を置ける');
l=await list(room,i1.seq);
ok(l.items.length===1&&l.items[0].data===undefined,'大きい項目は一覧に中身なし');
const got=new Uint8Array(await (await fetch(`${B}/r/${room}/items/${i2.seq}`)).arrayBuffer());
ok(got.length===big.length&&got.every((v,i)=>v===big[i]),'3MBがバイト単位で一致');
// 6. 上限
r=await post(room,new Uint8Array(9*1024*1024));ok(r.status===413,'8MB超は413');
r=await post(room,new Uint8Array(0));ok(r.status===400,'空は400');
// 7. 部屋の分離
const other='B'.repeat(43);
ok((await list(other)).items.length===0,'別の部屋は見えない');
ok((await fetch(`${B}/r/${other}/items/${i1.seq}`)).status===404,'別の部屋から取れない');
// 8. WebSocket
const ws=new WebSocket(`ws://127.0.0.1:8799/r/${room}/ws`);
const got2=new Promise((res,rej)=>{ws.onmessage=e=>{if(e.data!=='pong')res(JSON.parse(e.data))};setTimeout(()=>rej(new Error('timeout')),5000)});
await new Promise(res=>ws.onopen=res);
await post(room,new Uint8Array([9]),'mac');
const ev=await got2.catch(e=>null);
ok(ev&&ev.size===1&&ev.dev==='mac','WebSocketで新着通知が届く');
ws.close();
// 9. 件数上限（30件）
const room3='C'.repeat(43);for(let i=0;i<35;i++)await post(room3,new Uint8Array([i]));
l=await list(room3);ok(l.items.length===30&&l.items[0].data===btoa('\x05'),'31件目以降は古いものから消える');
// 10. 削除
r=await fetch(`${B}/r/${room}/items`,{method:'DELETE'});ok((await list(room)).items.length===0,'DELETEで全部消える');
// 11. CORS
r=await fetch(`${B}/r/${room}/items`,{method:'OPTIONS'});ok(r.status===204&&r.headers.get('access-control-allow-origin')==='*','CORSプリフライト');
console.log(fail?`${fail}件失敗`:'すべて成功');process.exit(fail?1:0);
