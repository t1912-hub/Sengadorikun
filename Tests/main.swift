// PencilTest のテスト。 ./run_tests.command で実行します。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

var pass = 0, fail = 0
func check(_ label: String, _ cond: Bool) {
    if cond { pass += 1; print("  OK    \(label)") } else { fail += 1; print("  FAIL  \(label)") }
}
func section(_ t: String) { print("\n── \(t)") }

func makeImage(_ w: Int, _ h: Int, shift: Int = 0) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 20 + shift * 30, y: 40, width: 60, height: 60))
    return ctx.makeImage()!
}

let fm = FileManager.default

// ============================================================
section("FrameStore — 撮影したコマがディスクに残るか")
// ============================================================
let base = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-test-\(UUID().uuidString)")
let store = FrameStore(baseFolder: base)

for _ in 0..<5 { store.append(makeImage(1552, 1552)) }
store.flush()
check("5コマ記録された", store.frames.count == 5)

func pngs() -> [String] {
    ((try? fm.contentsOfDirectory(atPath: store.folder.path)) ?? [])
        .filter { $0.hasSuffix(".png") }.sorted()
}
check("PNG が5枚ディスクに書かれた", pngs().count == 5)
check("連番になっている（既定名） — \(pngs().first ?? "-")",
      pngs().first == "PencilTest_0001.png" && pngs().last == "PencilTest_0005.png")

// プロジェクト名
let named = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-name-\(UUID().uuidString)"))
check("撮影前ならプロジェクト名を変えられる", named.setProjectName("走りサイクル"))
named.append(makeImage(80, 80)); named.flush()
let namedFiles = ((try? fm.contentsOfDirectory(atPath: named.folder.path)) ?? [])
    .filter { $0.hasSuffix(".png") }
check("連番ファイル名がプロジェクト名に沿う — \(namedFiles.first ?? "-")",
      namedFiles.first == "走りサイクル_0001.png")
check("フォルダ名にもプロジェクト名が入る — \(named.folder.lastPathComponent)",
      named.folder.lastPathComponent.hasPrefix("走りサイクル_"))
check("撮影後は名前を変えられない", named.setProjectName("別名") == false)
check("使えない文字は落とされる", FrameStore.sanitize("a/b:c*d") == "abcd")
check("空文字なら既定名に戻る", FrameStore.sanitize("   ") == "PencilTest")
try? fm.removeItem(at: named.folder)

if let full = loadCGImage(at: store.frames[0].url) {
    check("ディスクの画像はフル解像度 1552x1552", full.width == 1552 && full.height == 1552)
} else { check("ディスクの画像が読める", false) }

check("メモリ上のプレビューは長辺1024に縮小 — 実測 \(max(store.frames[0].preview.width, store.frames[0].preview.height))",
      max(store.frames[0].preview.width, store.frames[0].preview.height) == 1024)

let manifest = store.folder.appendingPathComponent("sequence.json")
check("sequence.json がある", fm.fileExists(atPath: manifest.path))

store.duplicate(at: 0); store.flush()
check("複製で6コマになる", store.frames.count == 6)
check("複製は同じファイルを指す", store.frames[0].url == store.frames[1].url)
check("複製でも id は別（描画の重複を避ける）", store.frames[0].id != store.frames[1].id)

store.remove(at: 0); store.flush()
check("削除で5コマに戻る", store.frames.count == 5)
check("削除してもディスクのファイルは残る（撮影データ保全）", pngs().count == 5)

let firstURL = store.frames[0].url
store.move(from: 0, to: 2); store.flush()
check("並べ替えが反映される", store.frames[2].url == firstURL)

if let data = try? Data(contentsOf: manifest),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let names = obj["frames"] as? [String] {
    check("マニフェストが現在の並び順を保持", names.count == 5 && names[2] == firstURL.lastPathComponent)
} else { check("マニフェストが読める", false) }
try? fm.removeItem(at: base)

// ============================================================
section("MP4Exporter — ディスクの PNG から MP4 を書けるか")
// ============================================================
let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-mp4-\(UUID().uuidString)")
try! fm.createDirectory(at: dir, withIntermediateDirectories: true)

// 奇数サイズを渡して H.264 の偶数丸めも確認する
var urls: [URL] = []
for i in 0..<12 {
    let u = dir.appendingPathComponent(String(format: "frame_%04d.png", i + 1))
    let dest = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, makeImage(641, 481, shift: i), nil)
    CGImageDestinationFinalize(dest)
    urls.append(u)
}

let out = dir.appendingPathComponent("out.mp4")
var seen: [Double] = []
do {
    try MP4Exporter.write(urls: urls, fps: 12, to: out) { seen.append($0) }
    check("書き出しが例外なく完了", true)
} catch {
    check("書き出しが例外なく完了 — \(error.localizedDescription)", false)
}

// progress は main キューへ async される。CLI ではランループを回さないと届かない。
RunLoop.main.run(until: Date().addingTimeInterval(0.3))

check("MP4 が生成された", fm.fileExists(atPath: out.path))
let size = (try? fm.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
check("MP4 のサイズが0でない (\(size ?? 0) bytes)", (size ?? 0) > 1000)

let asset = AVURLAsset(url: out)
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let secs = CMTimeGetSeconds(try await asset.load(.duration))
        check("再生時間が約1.0秒 (12コマ/12fps) — 実測 \(String(format: "%.3f", secs))秒",
              abs(secs - 1.0) < 0.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        check("動画トラックが1本ある", tracks.count == 1)
        if let t = tracks.first {
            let sz = try await t.load(.naturalSize)
            check("解像度が偶数に丸められている 640x480 — 実測 \(Int(sz.width))x\(Int(sz.height))",
                  Int(sz.width) == 640 && Int(sz.height) == 480)
            if let d = try await t.load(.formatDescriptions).first {
                let codec = CMFormatDescriptionGetMediaSubType(d)
                let tag = withUnsafeBytes(of: codec.bigEndian) { String(bytes: $0, encoding: .ascii) ?? "" }
                check("コーデックが H.264 (avc1) — 実測 \(tag)", tag == "avc1")
            }
        }
    } catch {
        check("MP4 を解析できる — \(error.localizedDescription)", false)
    }
    sem.signal()
}
sem.wait()
check("進捗が最後まで報告された", seen.count == 12 && (seen.last ?? 0) > 0.99)
try? fm.removeItem(at: dir)

// ============================================================
section("cropCenter — 画面比率の切り抜き")
// ============================================================
let wide = cropCenter(makeImage(1000, 1000), ratio: 16.0/9.0)
check("正方形→16:9横 で 1000x562 (比率 \(String(format: "%.3f", Double(wide.width)/Double(wide.height))))",
      wide.width == 1000 && abs(Double(wide.width)/Double(wide.height) - 16.0/9.0) < 0.01)

let tall = cropCenter(makeImage(1000, 1000), ratio: 9.0/16.0)
check("正方形→9:16縦 で 562x1000 (比率 \(String(format: "%.3f", Double(tall.width)/Double(tall.height))))",
      tall.height == 1000 && abs(Double(tall.width)/Double(tall.height) - 9.0/16.0) < 0.01)

let already = cropCenter(makeImage(1920, 1080), ratio: 16.0/9.0)
check("既に16:9なら変わらない", already.width == 1920 && already.height == 1080)

let fromWide = cropCenter(makeImage(1920, 1080), ratio: 9.0/16.0)
check("16:9→9:16縦 で左右を大きく削る", fromWide.height == 1080 && fromWide.width < 700)

check("FrameAspect は3種類", FrameAspect.allCases.count == 3)
check("free の ratio は nil", FrameAspect.free.ratio == nil)

// ============================================================
section("複数選択の一括削除 — 添字のずれ")
// ============================================================
let ms = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-multi-\(UUID().uuidString)"))
ms.setProjectName("Multi")
for _ in 0..<6 { ms.append(makeImage(60, 60)) }
ms.flush()
check("6コマ用意", ms.frames.count == 6)

// UI 側の deleteSelection と同じ手順：後ろから消す
let sel: Set<Int> = [1, 2, 4]
for i in sel.sorted(by: >) { ms.remove(at: i) }

let left = ms.frames.map { $0.url.lastPathComponent }
check("3コマ残る — 実測 \(ms.frames.count)", ms.frames.count == 3)
check("残ったのは 1・4・6 番目 — 実測 \(left.joined(separator: ", "))",
      left == ["Multi_0001.png", "Multi_0004.png", "Multi_0006.png"])

// 先頭から消すと壊れることを示す（この順ではダメだという確認）
let ms2 = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-multi2-\(UUID().uuidString)"))
ms2.setProjectName("Multi")
for _ in 0..<6 { ms2.append(makeImage(60, 60)) }
ms2.flush()
for i in sel.sorted() where ms2.frames.indices.contains(i) { ms2.remove(at: i) }
let wrong = ms2.frames.map { $0.url.lastPathComponent }
check("前から消すと別のコマが消える（降順が正しいことの裏付け） — 実測 \(wrong.joined(separator: ", "))",
      wrong != ["Multi_0001.png", "Multi_0004.png", "Multi_0006.png"])

// 全選択の削除
for i in (0..<ms.frames.count).sorted(by: >) { ms.remove(at: i) }
check("全部消すと0コマ", ms.frames.isEmpty)
check("ディスクの原本は残る（撮影データ保全）",
      ((try? fm.contentsOfDirectory(atPath: ms.folder.path)) ?? [])
        .filter { $0.hasSuffix(".png") }.count == 6)
try? fm.removeItem(at: ms.folder)
try? fm.removeItem(at: ms2.folder)

// ============================================================
section("取り消し（undo）— 最大10回")
// ============================================================
let us = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-undo-\(UUID().uuidString)"))
us.setProjectName("Undo")
check("最初は取り消せない", us.undo() == false)
check("履歴は0件", us.undoCount == 0)

for _ in 0..<5 { us.append(makeImage(50, 50)) }
us.flush()
check("5コマ撮影後の履歴は5件", us.undoCount == 5)

us.undo()
check("撮影を取り消すと4コマ", us.frames.count == 4)

// まとめて削除 → 1回の undo で全部戻る
us.remove(indices: [0, 1, 2])
check("3コマまとめて削除で1コマ", us.frames.count == 1)
us.undo()
check("まとめ削除は1回の取り消しで戻る — 実測 \(us.frames.count)コマ", us.frames.count == 4)

// 並べ替えも戻せる
let beforeMove = us.frames.map { $0.url.lastPathComponent }
us.move(from: 0, to: 3)
check("並べ替えが反映される", us.frames.map { $0.url.lastPathComponent } != beforeMove)
us.undo()
check("並べ替えも取り消せる", us.frames.map { $0.url.lastPathComponent } == beforeMove)

// 上限10件
let ls = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-undo2-\(UUID().uuidString)"))
for _ in 0..<15 { ls.append(makeImage(40, 40)) }
ls.flush()
check("15回操作しても履歴は10件で頭打ち — 実測 \(ls.undoCount)", ls.undoCount == 10)
var n = 0
while ls.undo() { n += 1 }
check("取り消せるのは10回まで — 実測 \(n)回", n == 10)
check("10回戻すと5コマ残る（15-10） — 実測 \(ls.frames.count)", ls.frames.count == 5)
check("それ以上は取り消せない", ls.undo() == false)

try? fm.removeItem(at: us.folder)
try? fm.removeItem(at: ls.folder)

// ============================================================
section("PencilFilter — 鉛筆線の調整")
// ============================================================

/// 照明ムラを再現：左が明るく(200)右が暗い(90)背景に、常に背景より40暗い縦線
func unevenPaper(_ w: Int = 200, _ h: Int = 120) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    for y in 0..<h {
        for x in 0..<w {
            let bg = 200.0 - 110.0 * Double(x) / Double(w - 1)
            let v = (x % 40) == 20 ? bg - 40 : bg
            p[y * ctx.bytesPerRow + x] = UInt8(max(0, min(255, v.rounded())))
        }
    }
    return ctx.makeImage()!
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
    let ctx = CGContext(data: nil, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height)
    return p[y * ctx.bytesPerRow + x]
}

func blackCount(_ image: CGImage) -> Int {
    let ctx = CGContext(data: nil, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height)
    var n = 0
    for y in 0..<image.height { for x in 0..<image.width {
        if p[y * ctx.bytesPerRow + x] == 0 { n += 1 } } }
    return n
}

let paper = unevenPaper()
func filtered(_ change: (inout PencilFilter) -> Void) -> CGImage {
    var f = PencilFilter()
    // ここは手動モードの検証。おまかせが既定でオンなので明示的に切る。
    f.enabled = true; f.auto = false; f.adaptive = true; f.threshold = 0.60; f.radius = 12
    f.black = 0; f.white = 1; f.blur = 0; f.dilate = 0; f.strength = 1
    change(&f)
    return applyPencilFilter(paper, f)
}

let LINE = 180, BGX = 175   // 暗い側の線と背景

let simpleF = filtered { $0.adaptive = false }
check("単純方式：暗い側で線と背景が区別できない（両方黒） — 線\(pixel(simpleF, LINE, 60)) 背景\(pixel(simpleF, BGX, 60))",
      pixel(simpleF, LINE, 60) == 0 && pixel(simpleF, BGX, 60) == 0)

let adap = filtered { _ in }
check("適応方式：暗い側で線=黒・背景=白に分離 — 線\(pixel(adap, LINE, 60)) 背景\(pixel(adap, BGX, 60))",
      pixel(adap, LINE, 60) == 0 && pixel(adap, BGX, 60) == 255)
check("適応方式：明るい側でも線=黒・背景=白 — 線\(pixel(adap, 20, 60)) 背景\(pixel(adap, 5, 60))",
      pixel(adap, 20, 60) == 0 && pixel(adap, 5, 60) == 255)

let srcVal = pixel(paper, 5, 60)
let soft = filtered { $0.strength = 0 }
check("強度0：元の階調がそのまま（元\(srcVal) → \(pixel(soft, 5, 60))）",
      abs(Int(pixel(soft, 5, 60)) - Int(srcVal)) <= 1)
let half = filtered { $0.strength = 0.5 }
check("強度50%：黒と元階調の中間 — 実測 \(pixel(half, 20, 60))",
      pixel(half, 20, 60) > 0 && pixel(half, 20, 60) < 255)

let lifted = filtered { $0.black = 0.35; $0.strength = 0 }
check("黒レベルを上げると中間調が沈む＝薄い線が濃くなる（\(pixel(soft, 5, 60)) → \(pixel(lifted, 5, 60))）",
      pixel(lifted, 5, 60) < pixel(soft, 5, 60))
let blown = filtered { $0.white = 0.75; $0.strength = 0 }
check("白レベルを下げると全体が明るく飛ぶ（\(pixel(soft, 5, 60)) → \(pixel(blown, 5, 60))）",
      pixel(blown, 5, 60) > pixel(soft, 5, 60))

check("線を太く：黒画素が増える \(blackCount(filtered { $0.dilate = 0 })) → \(blackCount(filtered { $0.dilate = 2 }))",
      blackCount(filtered { $0.dilate = 2 }) > blackCount(filtered { $0.dilate = 0 }))
check("ノイズ除去を強めても線は残る — 実測 \(pixel(filtered { $0.blur = 3 }, 20, 60))",
      pixel(filtered { $0.blur = 3 }, 20, 60) == 0)
check("しきい値を上げると黒が増える \(blackCount(filtered { $0.threshold = 0.4 })) → \(blackCount(filtered { $0.threshold = 0.8 }))",
      blackCount(filtered { $0.threshold = 0.8 }) > blackCount(filtered { $0.threshold = 0.4 }))
check("無効なら素通し", applyPencilFilter(paper, PencilFilter()).width == paper.width)
check("サイズが変わらない", adap.width == 200 && adap.height == 120)

// 書き出しに適用できるか
let btmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt-bin-\(UUID().uuidString)")
try! fm.createDirectory(at: btmp, withIntermediateDirectories: true)
var burls: [URL] = []
for i in 0..<4 {
    let u = btmp.appendingPathComponent(String(format: "f%02d.png", i))
    let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, unevenPaper(64, 64), nil)
    CGImageDestinationFinalize(d)
    burls.append(u)
}
let bout = btmp.appendingPathComponent("bin.mp4")
var ef = PencilFilter(); ef.enabled = true
do {
    try MP4Exporter.write(urls: burls, fps: 12, to: bout,
                          transform: { applyPencilFilter($0, ef) }) { _ in }
    check("調整を適用した MP4 書き出しが通る", fm.fileExists(atPath: bout.path))
} catch {
    check("調整を適用した MP4 書き出しが通る — \(error.localizedDescription)", false)
}
try? fm.removeItem(at: btmp)

// ============================================================
section("書き出し範囲 — 全体 / 16:9 の切り出し")
// ============================================================
let etmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-export-\(UUID().uuidString)")
try! fm.createDirectory(at: etmp, withIntermediateDirectories: true)

// 正方形(600x600)のコマを用意する。16:9 に切ると 600x337 → 偶数丸めで 600x336
var eurls: [URL] = []
for i in 0..<6 {
    let u = etmp.appendingPathComponent(String(format: "e%02d.png", i))
    let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, makeImage(600, 600, shift: i), nil)
    CGImageDestinationFinalize(d)
    eurls.append(u)
}

func exportedSize(_ transform: ((CGImage) -> CGImage)?) -> (Int, Int)? {
    let out = etmp.appendingPathComponent("out-\(UUID().uuidString).mp4")
    do { try MP4Exporter.write(urls: eurls, fps: 12, to: out, transform: transform) { _ in } }
    catch { return nil }
    let asset = AVURLAsset(url: out)
    var result: (Int, Int)? = nil
    let sem2 = DispatchSemaphore(value: 0)
    Task {
        if let t = try? await asset.loadTracks(withMediaType: .video).first,
           let sz = try? await t.load(.naturalSize) {
            result = (Int(sz.width), Int(sz.height))
        }
        sem2.signal()
    }
    sem2.wait()
    return result
}

if let whole = exportedSize(nil) {
    check("「全体」は正方形のまま 600x600 — 実測 \(whole.0)x\(whole.1)",
          whole == (600, 600))
} else { check("「全体」で書き出せる", false) }

let cropTransform: (CGImage) -> CGImage = { cropCenter($0, ratio: 16.0 / 9.0) }
if let cropped = exportedSize(cropTransform) {
    let ratio = Double(cropped.0) / Double(cropped.1)
    check("「16:9 の範囲」は横長になる — 実測 \(cropped.0)x\(cropped.1) (比率 \(String(format: "%.3f", ratio)))",
          cropped.0 == 600 && abs(ratio - 16.0/9.0) < 0.02)
} else { check("「16:9 の範囲」で書き出せる", false) }

// 切り抜きと鉛筆線の調整を合成しても通るか
var cf = PencilFilter(); cf.enabled = true
let combined: (CGImage) -> CGImage = { applyPencilFilter(cropCenter($0, ratio: 16.0/9.0), cf) }
if let both = exportedSize(combined) {
    check("切り抜き＋2値化の合成でも書き出せる — 実測 \(both.0)x\(both.1)", both.0 == 600)
} else { check("切り抜き＋2値化の合成でも書き出せる", false) }

try? fm.removeItem(at: etmp)

// ============================================================
section("makeExportTransform — 画面の設定が書き出しに効くか")
// ============================================================
var offFilter = PencilFilter()          // 2値化オフ
var onFilter  = PencilFilter(); onFilter.enabled = true

check("何も設定しなければ nil（素通し）",
      makeExportTransform(cropToGuide: false, filter: offFilter) == nil)
check("切り抜きだけでも処理が返る",
      makeExportTransform(cropToGuide: true, filter: offFilter) != nil)
check("2値化だけでも処理が返る",
      makeExportTransform(cropToGuide: false, filter: onFilter) != nil)

// 階調のある画像で試す（白黒だけの画像では「階調が残るか」を確かめられない）
let square = unevenPaper(600, 600)
let srcMid = pixel(square, 310, 300)

if let t = makeExportTransform(cropToGuide: true, filter: offFilter) {
    let r = t(square)
    check("切り抜きのみ：600x600 → 16:9 になる — 実測 \(r.width)x\(r.height)",
          r.width == 600 && abs(Double(r.width)/Double(r.height) - 16.0/9.0) < 0.02)
    let v = pixel(r, 310, r.height/2)
    check("切り抜きのみ：中間調が残る（2値化されない） — 元\(srcMid) → \(v)",
          v != 0 && v != 255 && abs(Int(v) - Int(srcMid)) <= 2)
} else { check("切り抜きのみの処理が得られる", false) }

if let t = makeExportTransform(cropToGuide: false, filter: onFilter) {
    let r = t(square)
    check("2値化のみ：サイズは変わらない — 実測 \(r.width)x\(r.height)",
          r.width == 600 && r.height == 600)
    let v = pixel(r, 310, 300)
    check("2値化のみ：中間調が白か黒に振り分けられる — 元\(srcMid) → \(v)", v == 0 || v == 255)
} else { check("2値化のみの処理が得られる", false) }

if let t = makeExportTransform(cropToGuide: true, filter: onFilter) {
    let r = t(square)
    let v = pixel(r, 310, r.height/2)
    check("両方：16:9 かつ2値化される — 実測 \(r.width)x\(r.height) 画素\(v)",
          r.width == 600 && r.height < 400 && (v == 0 || v == 255))
} else { check("両方の処理が得られる", false) }

// ============================================================
section("セーフティ枠での切り出し — 16:9 カメラでも実際に削られるか")
// ============================================================
// 実機で使っている 1920x1080（すでに 16:9）のコマを想定する
let hd = unevenPaper(1920, 1080)

if let t = makeExportTransform(cropToGuide: true, safety: 1.0, filter: offFilter) {
    let r = t(hd)
    check("セーフティ100%なら 16:9 素材は変化しない — 実測 \(r.width)x\(r.height)",
          r.width == 1920 && r.height == 1080)
} else { check("セーフティ100%の処理が得られる", false) }

if let t = makeExportTransform(cropToGuide: true, safety: 0.9, filter: offFilter) {
    let r = t(hd)
    check("セーフティ90%で 1920x1080 → 1728x972 に削られる — 実測 \(r.width)x\(r.height)",
          r.width == 1728 && r.height == 972)
    check("削っても 16:9 は保たれる",
          abs(Double(r.width)/Double(r.height) - 16.0/9.0) < 0.02)
} else { check("セーフティ90%の処理が得られる", false) }

if let t = makeExportTransform(cropToGuide: true, safety: 0.8, filter: offFilter) {
    let r = t(hd)
    check("セーフティ80%ならさらに小さくなる — 実測 \(r.width)x\(r.height)",
          r.width == 1536 && r.height == 864)
} else { check("セーフティ80%の処理が得られる", false) }

// 正方形カメラ（内蔵 1552x1552）でも二段階に効くか
let sq = unevenPaper(1552, 1552)
if let t = makeExportTransform(cropToGuide: true, safety: 0.9, filter: offFilter) {
    let r = t(sq)
    check("正方形1552は 16:9 に切ってからセーフティで縮む — 実測 \(r.width)x\(r.height)",
          r.width == 1397 && abs(Double(r.width)/Double(r.height) - 16.0/9.0) < 0.02)
} else { check("正方形での処理が得られる", false) }

check("「全体」を選べば切り抜かれない",
      makeExportTransform(cropToGuide: false, safety: 0.9, filter: offFilter) == nil)

// ============================================================
section("やり直し（redo）")
// ============================================================
let rs = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-redo-\(UUID().uuidString)"))
for _ in 0..<3 { rs.append(makeImage(40, 40)) }
rs.flush()
check("最初はやり直せない", rs.redo() == false)
check("やり直し履歴は0件", rs.redoCount == 0)

rs.undo()
check("取り消しで2コマ", rs.frames.count == 2)
check("やり直し履歴が1件できる", rs.redoCount == 1)
rs.redo()
check("やり直しで3コマに戻る", rs.frames.count == 3)
check("やり直し履歴は空に戻る", rs.redoCount == 0)

// 取り消したあと新しい操作をすると、やり直しは無効になる
rs.undo(); rs.undo()
check("2回取り消して1コマ", rs.frames.count == 1)
check("やり直しは2件たまる", rs.redoCount == 2)
rs.append(makeImage(40, 40)); rs.flush()
check("新しく撮影するとやり直し履歴が消える", rs.redoCount == 0)
check("やり直しはもうできない", rs.redo() == false)

// 何度も往復できる
rs.undo(); rs.redo(); rs.undo(); rs.redo()
check("取り消しとやり直しを往復しても壊れない — 実測 \(rs.frames.count)コマ", rs.frames.count == 2)
try? fm.removeItem(at: rs.folder)

// ============================================================
section("書き出し解像度 — FHD / HD / 元のまま")
// ============================================================
let stmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-size-\(UUID().uuidString)")
try! fm.createDirectory(at: stmp, withIntermediateDirectories: true)
var surls: [URL] = []
for i in 0..<4 {
    let u = stmp.appendingPathComponent(String(format: "s%02d.png", i))
    let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, makeImage(600, 600, shift: i), nil)
    CGImageDestinationFinalize(d)
    surls.append(u)
}

func sizeOf(_ es: ExportSize, _ tr: ((CGImage) -> CGImage)? = nil) -> (Int, Int)? {
    let out = stmp.appendingPathComponent("o-\(UUID().uuidString).mp4")
    do { try MP4Exporter.write(urls: surls, fps: 12, to: out, transform: tr, size: es) { _ in } }
    catch { return nil }
    var r: (Int, Int)? = nil
    let sem3 = DispatchSemaphore(value: 0)
    Task {
        if let t = try? await AVURLAsset(url: out).loadTracks(withMediaType: .video).first,
           let sz = try? await t.load(.naturalSize) { r = (Int(sz.width), Int(sz.height)) }
        sem3.signal()
    }
    sem3.wait()
    return r
}

if let o = sizeOf(.original) { check("元のまま：600x600 — 実測 \(o.0)x\(o.1)", o == (600, 600)) }
else { check("元のままで書き出せる", false) }
if let o = sizeOf(.fhd) { check("FHD：1920x1080 — 実測 \(o.0)x\(o.1)", o == (1920, 1080)) }
else { check("FHDで書き出せる", false) }
if let o = sizeOf(.hd) { check("HD：1280x720 — 実測 \(o.0)x\(o.1)", o == (1280, 720)) }
else { check("HDで書き出せる", false) }

let cropT: (CGImage) -> CGImage = { cropCenter($0, ratio: 16.0/9.0) }
if let o = sizeOf(.fhd, cropT) {
    check("切り抜き＋FHD でも 1920x1080 — 実測 \(o.0)x\(o.1)", o == (1920, 1080))
} else { check("切り抜き＋FHD で書き出せる", false) }
check("ExportSize は3種類", ExportSize.allCases.count == 3)
try? fm.removeItem(at: stmp)

// ============================================================
section("おまかせ二値化 — 紙に落ちた影と鉛筆線を分けられるか")
// ============================================================

/// iPad の影が紙の左半分に落ちている状況を作る。
/// 紙の明るさは場所によって 225 と 120 に分かれ、
/// 鉛筆線は「その場所の紙より 60 暗い」＝影の中では絶対値として非常に暗い。
func shadowedPaper(_ w: Int = 400, _ h: Int = 300) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    for y in 0..<h {
        for x in 0..<w {
            // 左 45% が影。境目は少しぼかす
            let edge = Double(w) * 0.45
            let t = min(1.0, max(0.0, (Double(x) - edge) / 30.0))
            let paper = 120.0 + (225.0 - 120.0) * t
            let isLine = (x % 50) == 25
            let v = isLine ? paper - 60 : paper
            p[y * ctx.bytesPerRow + x] = UInt8(max(0, min(255, v.rounded())))
        }
    }
    return ctx.makeImage()!
}

let shadowed = shadowedPaper()
func autoFiltered(_ change: (inout PencilFilter) -> Void = { _ in }) -> CGImage {
    var f = PencilFilter()
    f.enabled = true; f.auto = true; f.autoStrength = 0.2
    f.blur = 0; f.dilate = 0; f.strength = 1; f.black = 0; f.white = 1
    change(&f)
    return applyPencilFilter(shadowed, f)
}

// 影の中（x=75 が線、x=90 が紙）／影の外（x=275 が線、x=290 が紙）
let A = autoFiltered()
check("おまかせ：影の中の線が黒 — 実測 \(pixel(A, 75, 150))",  pixel(A, 75, 150) == 0)
check("おまかせ：影の中の紙が白 — 実測 \(pixel(A, 90, 150))",  pixel(A, 90, 150) == 255)
check("おまかせ：影の外の線が黒 — 実測 \(pixel(A, 275, 150))", pixel(A, 275, 150) == 0)
check("おまかせ：影の外の紙が白 — 実測 \(pixel(A, 290, 150))", pixel(A, 290, 150) == 255)

// 単純なしきい値だと影ごと黒く潰れることを示す（おまかせが必要な理由）
var sf = PencilFilter()
sf.enabled = true; sf.auto = false; sf.adaptive = false
sf.threshold = 0.6; sf.blur = 0; sf.dilate = 0; sf.strength = 1; sf.black = 0; sf.white = 1
let S = applyPencilFilter(shadowed, sf)
check("単純方式：影の中の紙まで黒く潰れる — 実測 \(pixel(S, 90, 150))", pixel(S, 90, 150) == 0)

// 強さの効き方
check("強さを上げると黒が減る（地の汚れを拾わなくなる） \(blackCount(autoFiltered { $0.autoStrength = 0.05 })) → \(blackCount(autoFiltered { $0.autoStrength = 0.45 }))",
      blackCount(autoFiltered { $0.autoStrength = 0.45 }) < blackCount(autoFiltered { $0.autoStrength = 0.05 }))
check("おまかせの既定値でサイズは変わらない", A.width == 400 && A.height == 300)
check("おまかせが既定でオンになっている", PencilFilter().auto == true)
var mixed = PencilFilter()
mixed.enabled = true; mixed.auto = true; mixed.adaptive = false; mixed.threshold = 0.95
let M = applyPencilFilter(shadowed, mixed)
check("おまかせがオンなら手動のしきい値は無視される（影の紙が白のまま） — 実測 \(pixel(M, 90, 150))",
      pixel(M, 90, 150) == 255)

// ============================================================
section("コマの長さ（2コマ打ち・3コマ打ち）")
// ============================================================
let hs = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-hold-\(UUID().uuidString)"))
hs.setProjectName("Hold")
for _ in 0..<3 { hs.append(makeImage(50, 50)) }
hs.flush()
check("既定はすべて1コマ打ち", hs.frames.allSatisfy { $0.hold == 1 })
check("展開後の総数は3", hs.totalFrameCount == 3)

hs.setHold(at: 1, to: 3)
check("2枚目を3コマ打ちにできる", hs.frames[1].hold == 3)
check("展開後の総数が5になる — 実測 \(hs.totalFrameCount)", hs.totalFrameCount == 5)
check("展開した並びが 0,1,1,1,2 — 実測 \(hs.expandedIndices.map(String.init).joined(separator: ","))",
      hs.expandedIndices == [0, 1, 1, 1, 2])
check("書き出し用のファイル列も5つに展開される", hs.expandedURLs.count == 5)
check("同じコマが3回続く",
      hs.expandedURLs[1] == hs.expandedURLs[2] && hs.expandedURLs[2] == hs.expandedURLs[3])

hs.undo()
check("長さの変更も取り消せる — 実測 \(hs.frames[1].hold)コマ", hs.frames[1].hold == 1)
hs.redo()
check("やり直しで戻る", hs.frames[1].hold == 3)

hs.setHold(at: 0, to: 99)
check("長すぎる指定は48で頭打ち — 実測 \(hs.frames[0].hold)", hs.frames[0].hold == 48)
hs.setHold(at: 0, to: 48)
check("48コマ＝24fpsで2秒を指定できる", hs.frames[0].hold == 48)
hs.setHold(at: 0, to: 0)
check("0以下は1に丸められる — 実測 \(hs.frames[0].hold)", hs.frames[0].hold == 1)

hs.duplicate(at: 1)
check("複製すると長さも引き継ぐ — 実測 \(hs.frames[1].hold)コマ", hs.frames[1].hold == 3)

// マニフェストに長さが残るか
hs.flush()
if let data = try? Data(contentsOf: hs.folder.appendingPathComponent("sequence.json")),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let holds = obj["holds"] as? [Int] {
    check("sequence.json に長さが記録される — 実測 \(holds.map(String.init).joined(separator: ","))",
          holds.count == hs.frames.count)
} else { check("sequence.json に長さが記録される", false) }
try? fm.removeItem(at: hs.folder)

// ============================================================
section("付随データと差し替え — 描いた線を残して編集し直す")
// ============================================================
let ds = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-draw-\(UUID().uuidString)"))
ds.setProjectName("Draw")
ds.append(makeImage(200, 200))
ds.flush()

let strokes = "ストロークの中身".data(using: .utf8)!
ds.writeSidecar(strokes, for: ds.frames[0], ext: "drawing")
ds.flush()
check("付随データを書き戻せる", ds.readSidecar(for: ds.frames[0], ext: "drawing") == strokes)
check("コマと同じ名前で拡張子だけ違う",
      fm.fileExists(atPath: ds.folder.appendingPathComponent("Draw_0001.drawing").path))
check("無い拡張子を読むと nil", ds.readSidecar(for: ds.frames[0], ext: "none") == nil)

// 絵の差し替え
let before = ds.frames[0].preview.width
ds.replace(at: 0, with: makeImage(400, 300))
ds.flush()
check("差し替えてもコマ数は変わらない", ds.frames.count == 1)
check("差し替え後もファイル名は同じ（付随データと対応が崩れない）",
      ds.frames[0].url.lastPathComponent == "Draw_0001.png")
if let full = loadCGImage(at: ds.frames[0].url) {
    check("ディスクの画像が新しいものに置き換わる — 実測 \(full.width)x\(full.height)",
          full.width == 400 && full.height == 300)
} else { check("差し替え後の画像を読める", false) }
check("差し替え後も付随データは残る", ds.readSidecar(for: ds.frames[0], ext: "drawing") == strokes)
_ = before
try? fm.removeItem(at: ds.folder)

// ============================================================
section("コマの差し込み — 描いているコマの次に増やす")
// ============================================================
let ins = FrameStore(baseFolder: URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-ins-\(UUID().uuidString)"))
ins.setProjectName("Ins")
for _ in 0..<3 { ins.append(makeImage(60, 60)) }
ins.flush()
let firstURL2 = ins.frames[0].url.lastPathComponent
let lastURL2 = ins.frames[2].url.lastPathComponent

let pos = ins.insert(makeImage(60, 60), after: 0)
ins.flush()
check("1枚目の次に入る（位置1） — 実測 \(pos)", pos == 1)
check("4コマになる", ins.frames.count == 4)
check("1枚目は動かない", ins.frames[0].url.lastPathComponent == firstURL2)
check("元の2枚目以降は後ろへずれる", ins.frames[3].url.lastPathComponent == lastURL2)
check("新しいコマは別ファイル",
      ins.frames[1].url.lastPathComponent != firstURL2 &&
      ins.frames[1].url.lastPathComponent != lastURL2)

let endPos = ins.insert(makeImage(60, 60), after: ins.frames.count - 1)
check("最後の次に入れると末尾になる — 実測 \(endPos)", endPos == 4)
ins.undo()
check("差し込みも取り消せる — 実測 \(ins.frames.count)コマ", ins.frames.count == 4)
try? fm.removeItem(at: ins.folder)

// ============================================================
section("プロジェクトの保存と再開")
// ============================================================
let projBase = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-proj-\(UUID().uuidString)")
let ps = FrameStore(baseFolder: projBase)
ps.setProjectName("走りサイクル")
for _ in 0..<3 { ps.append(makeImage(80, 80)) }
ps.setHold(at: 1, to: 4)
ps.flush()
let savedFolder = ps.folder
check("3コマ保存された", ps.frames.count == 3)

// 別のプロジェクトを始める
ps.startNewProject(named: "歩きサイクル")
check("新規プロジェクトでコマが空になる", ps.frames.isEmpty)
check("フォルダが変わる", ps.folder != savedFolder)
check("名前が変わる", ps.projectName == "歩きサイクル")
ps.append(makeImage(80, 80)); ps.flush()

// 前のプロジェクトを開き直す
check("保存済みを開ける", ps.open(savedFolder))
check("3コマ戻る — 実測 \(ps.frames.count)", ps.frames.count == 3)
check("コマの長さも戻る — 実測 \(ps.frames[1].hold)コマ", ps.frames[1].hold == 4)
check("名前も戻る — 実測 \(ps.projectName)", ps.projectName == "走りサイクル")

// 開いたあとに撮っても、既存ファイルを上書きしない
let filesBefore = Set(((try? fm.contentsOfDirectory(atPath: ps.folder.path)) ?? [])
    .filter { $0.hasSuffix(".png") })
ps.append(makeImage(80, 80)); ps.flush()
let filesAfter = Set(((try? fm.contentsOfDirectory(atPath: ps.folder.path)) ?? [])
    .filter { $0.hasSuffix(".png") })
check("追加したコマは新しい番号になる — \(filesBefore.count) → \(filesAfter.count)枚",
      filesAfter.count == filesBefore.count + 1 && filesBefore.isSubset(of: filesAfter))

// 一覧
let list = FrameStore.savedProjects(under: projBase)
check("保存済みが2件見える — 実測 \(list.count)件", list.count == 2)
check("存在しないフォルダは開けない",
      ps.open(projBase.appendingPathComponent("nope")) == false)
try? fm.removeItem(at: projBase)

// ============================================================
section("連番PNGの書き出し")
// ============================================================
let seqDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pt-seq-\(UUID().uuidString)")
try! fm.createDirectory(at: seqDir, withIntermediateDirectories: true)
var seqSrc: [URL] = []
for i in 0..<5 {
    let u = seqDir.appendingPathComponent(String(format: "src_%02d.png", i))
    let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, makeImage(600, 600, shift: i), nil)
    CGImageDestinationFinalize(d)
    seqSrc.append(u)
}

do {
    let out = try SequenceExporter.writeFolder(urls: seqSrc, named: "走りサイクル", to: seqDir)
    let pngs = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? [])
        .filter { $0.hasSuffix(".png") }.sorted()
    check("5枚が書き出される — 実測 \(pngs.count)枚", pngs.count == 5)
    check("通し番号が振り直される — \(pngs.first ?? "-")", pngs.first == "走りサイクル_0001.png")
    check("最後は 0005", pngs.last == "走りサイクル_0005.png")
    if let img = loadCGImage(at: out.appendingPathComponent(pngs[0])) {
        check("元のまま：600x600 — 実測 \(img.width)x\(img.height)",
              img.width == 600 && img.height == 600)
    } else { check("書き出した PNG を読める", false) }
} catch { check("連番PNGを書き出せる — \(error.localizedDescription)", false) }

// HD 指定
do {
    let out = try SequenceExporter.writeFolder(urls: seqSrc, named: "HD版", to: seqDir, size: .hd)
    if let img = loadCGImage(at: out.appendingPathComponent("HD版_0001.png")) {
        check("HD 指定で 1280x720 — 実測 \(img.width)x\(img.height)",
              img.width == 1280 && img.height == 720)
    } else { check("HD 版を読める", false) }
} catch { check("HD で書き出せる — \(error.localizedDescription)", false) }

// 調整を適用
do {
    var bf = PencilFilter(); bf.enabled = true
    let out = try SequenceExporter.writeFolder(urls: seqSrc, named: "2値化", to: seqDir,
                                               transform: { applyPencilFilter($0, bf) })
    if let img = loadCGImage(at: out.appendingPathComponent("2値化_0001.png")) {
        check("鉛筆線の調整が反映される", img.width == 600)
    } else { check("調整版を読める", false) }
} catch { check("調整を適用して書き出せる — \(error.localizedDescription)", false) }

// zip にまとめる
do {
    let folder = try SequenceExporter.writeFolder(urls: seqSrc, named: "Zip検証", to: seqDir)
    let zip = try SequenceExporter.zipFolder(folder)
    let zipSize = ((try? fm.attributesOfItem(atPath: zip.path)[.size]) as? Int) ?? 0
    check("zip が作られる（\(zipSize) bytes）", fm.fileExists(atPath: zip.path) && zipSize > 500)
    try? fm.removeItem(at: zip)
} catch { check("zip にまとめられる — \(error.localizedDescription)", false) }

check("コマが無ければ拒否される", {
    do { _ = try SequenceExporter.writeFolder(urls: [], named: "空", to: seqDir); return false }
    catch { return true }
}())
try? fm.removeItem(at: seqDir)

print("\n結果: \(pass) OK / \(fail) FAIL")
exit(fail == 0 ? 0 : 1)
