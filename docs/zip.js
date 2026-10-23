"use strict";
/* PNG連番をまとめて1つのファイルで渡すための ZIP 書き出し。
   外から部品を持ってくるとオフラインで動かなくなるので、自前で書く。

   PNG はすでに圧縮済みなので、ZIP 側では圧縮しない（格納のみ）。
   そのぶん書き出しが速く、中身のバイト列をそのまま並べるだけで済む。

   中身はすべて Blob のまま扱い、ひとつの大きな配列にはまとめない。
   100枚を超えると数百MBになるため、端末のメモリに載せきれなくなる。
   Blob の配列から Blob を作ると、ブラウザが必要に応じて
   ディスクへ逃がしてくれる。 */

const ZIP_CRC_TABLE = (function(){
  const t = new Uint32Array(256);
  for(let n = 0; n < 256; n++){
    let c = n;
    for(let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();

function zipCrc32(bytes){
  let c = 0xFFFFFFFF;
  for(let i = 0; i < bytes.length; i++)
    c = ZIP_CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

/* ZIP は MS-DOS 時代の日付の持ち方をそのまま使う */
function zipDosTime(d){
  return { time: ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xFFFF,
           date: (((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xFFFF };
}

/* files: [{ name:"フォルダ/0001.png", blob:Blob }]
   onProgress: (作り終えた数, 全体) を受け取る */
async function makeZip(files, onProgress){
  const enc = new TextEncoder();
  const now = zipDosTime(new Date());
  const parts = [];          // 本体。Blob と Uint8Array が混ざってよい
  const central = [];        // 目次
  let offset = 0;

  for(let i = 0; i < files.length; i++){
    const f = files[i];
    const nameBytes = enc.encode(f.name);
    // crc を出すために一度だけ中身を読む。読んだ配列はここで捨て、
    // 本体には元の Blob を積む。こうしないと全部メモリに残る。
    const bytes = new Uint8Array(await f.blob.arrayBuffer());
    const crc = zipCrc32(bytes);
    const size = bytes.length;

    const lh = new Uint8Array(30 + nameBytes.length);
    const lv = new DataView(lh.buffer);
    lv.setUint32(0, 0x04034b50, true);   // 各ファイルの頭
    lv.setUint16(4, 20, true);           // 必要なバージョン
    lv.setUint16(6, 0x0800, true);       // 名前は UTF-8
    lv.setUint16(8, 0, true);            // 圧縮しない
    lv.setUint16(10, now.time, true);
    lv.setUint16(12, now.date, true);
    lv.setUint32(14, crc, true);
    lv.setUint32(18, size, true);
    lv.setUint32(22, size, true);
    lv.setUint16(26, nameBytes.length, true);
    lv.setUint16(28, 0, true);
    lh.set(nameBytes, 30);

    parts.push(lh, f.blob);
    central.push({ nameBytes, crc, size, offset });
    offset += lh.length + size;

    if(onProgress) onProgress(i + 1, files.length);
    // 画面を描き直す隙を作る
    await new Promise(r=>setTimeout(r, 0));
  }

  const dirStart = offset;
  for(const e of central){
    const ch = new Uint8Array(46 + e.nameBytes.length);
    const cv = new DataView(ch.buffer);
    cv.setUint32(0, 0x02014b50, true);   // 目次の項目
    cv.setUint16(4, 20, true);           // 作った側のバージョン
    cv.setUint16(6, 20, true);
    cv.setUint16(8, 0x0800, true);
    cv.setUint16(10, 0, true);
    cv.setUint16(12, now.time, true);
    cv.setUint16(14, now.date, true);
    cv.setUint32(16, e.crc, true);
    cv.setUint32(20, e.size, true);
    cv.setUint32(24, e.size, true);
    cv.setUint16(28, e.nameBytes.length, true);
    cv.setUint16(30, 0, true);           // 追加情報なし
    cv.setUint16(32, 0, true);           // 注釈なし
    cv.setUint16(34, 0, true);           // ディスク番号
    cv.setUint16(36, 0, true);
    cv.setUint32(38, 0, true);
    cv.setUint32(42, e.offset, true);    // 本体のどこにあるか
    ch.set(e.nameBytes, 46);
    parts.push(ch);
    offset += ch.length;
  }

  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);     // 終わりの印
  ev.setUint16(4, 0, true);
  ev.setUint16(6, 0, true);
  ev.setUint16(8, central.length, true);
  ev.setUint16(10, central.length, true);
  ev.setUint32(12, offset - dirStart, true);
  ev.setUint32(16, dirStart, true);
  ev.setUint16(20, 0, true);
  parts.push(end);

  return new Blob(parts, { type: "application/zip" });
}

/* 0001 のように桁を揃える。編集ソフトが順番通りに読み込めるようにするため。 */
function zipPad(n, width){
  let s = String(n);
  while(s.length < width) s = "0" + s;
  return s;
}
