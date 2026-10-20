import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Combine

// MARK: - Frame store（撮った瞬間にディスクへ保存する）

/// ディスク上の PNG を読み込む
func loadCGImage(at url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// 中央を基準に、指定した割合まで縮めて切り抜く（セーフティ枠の内側）
func cropCenter(_ image: CGImage, scale: CGFloat) -> CGImage {
    guard scale > 0, scale < 1 else { return image }
    let w = (CGFloat(image.width) * scale).rounded()
    let h = (CGFloat(image.height) * scale).rounded()
    let rect = CGRect(x: ((CGFloat(image.width) - w) / 2).rounded(),
                      y: ((CGFloat(image.height) - h) / 2).rounded(),
                      width: w, height: h)
    return image.cropping(to: rect) ?? image
}

/// 書き出し時に1コマへ適用する処理を組み立てる。
/// 切り抜きと鉛筆線の調整をまとめ、どちらも不要なら nil を返す。
/// 画面側はこれを呼ぶだけにして、組み立ての取り違えを防ぐ。
func makeExportTransform(cropToGuide: Bool,
                         safety: CGFloat = 1.0,
                         filter: PencilFilter) -> ((CGImage) -> CGImage)? {
    guard cropToGuide || filter.enabled else { return nil }
    return { image in
        var out = image
        if cropToGuide {
            // ガイドと同じ手順：まず映像に収まる最大の16:9、次にセーフティ枠の内側
            out = cropCenter(out, ratio: 16.0 / 9.0)
            out = cropCenter(out, scale: safety)
        }
        return applyPencilFilter(out, filter)
    }
}

/// 画面比率。動画用紙のフレームを決めるのに使う。
enum FrameAspect: String, CaseIterable, Identifiable {
    case free = "そのまま"
    case wide = "16:9 横"
    case tall = "9:16 縦"

    var id: String { rawValue }

    /// 幅 / 高さ。nil はカメラのまま。
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        }
    }
}

/// 中央を基準に、指定した縦横比へ切り抜く
func cropCenter(_ image: CGImage, ratio: CGFloat) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    guard w > 0, h > 0, ratio > 0 else { return image }
    let current = w / h
    let rect: CGRect
    if current > ratio {
        // 横に広すぎる → 左右を削る
        let newW = h * ratio
        rect = CGRect(x: ((w - newW) / 2).rounded(), y: 0, width: newW.rounded(), height: h)
    } else {
        // 縦に長すぎる → 上下を削る
        let newH = w / ratio
        rect = CGRect(x: 0, y: ((h - newH) / 2).rounded(), width: w, height: newH.rounded())
    }
    return image.cropping(to: rect) ?? image
}

/// 鉛筆線を読みやすくするための調整。
/// 元の PNG には一切手を加えず、表示と書き出しにだけ効く。
struct PencilFilter: Equatable {
    var enabled = false
    /// おまかせ。局所の平均とばらつきからしきい値を自動で決める（Sauvola 法）。
    /// 紙に影が落ちていても、線だけを拾える。
    var auto = true
    /// おまかせの強さ。大きいほど拾う線が減り、地の汚れを拾わなくなる。
    var autoStrength: Double = 0.20
    /// 局所平均を基準にする方式。照明のムラに強い。
    var adaptive = true
    /// 大きいほど黒が増える
    var threshold: Double = 0.60
    /// 適応方式で周囲を見る半径（px）
    var radius: Int = 12
    /// 黒レベル。上げると中間調が沈み、薄い線が濃くなる
    var black: Double = 0.0
    /// 白レベル。下げると紙の地色が白く飛ぶ
    var white: Double = 1.0
    /// ノイズ除去の半径
    var blur: Int = 1
    /// 線を太くする半径
    var dilate: Int = 0
    /// 0 で元の階調、1 で完全な2値
    var strength: Double = 1.0
}

// MARK: 内部の画像演算

/// 積分画像。局所平均を O(1) で引くために使う。
private func integralImage(_ src: [Float], _ w: Int, _ h: Int) -> [Double] {
    let W = w + 1
    var ii = [Double](repeating: 0, count: W * (h + 1))
    for y in 0..<h {
        var rowSum: Double = 0
        for x in 0..<w {
            rowSum += Double(src[y*w + x])
            ii[(y+1)*W + (x+1)] = ii[y*W + (x+1)] + rowSum
        }
    }
    return ii
}

private func boxMean(_ ii: [Double], _ w: Int, _ h: Int,
                     _ x: Int, _ y: Int, _ r: Int) -> Double {
    let W = w + 1
    let x0 = max(0, x - r), y0 = max(0, y - r)
    let x1 = min(w - 1, x + r), y1 = min(h - 1, y + r)
    let s = ii[(y1+1)*W + (x1+1)] - ii[y0*W + (x1+1)]
          - ii[(y1+1)*W + x0]     + ii[y0*W + x0]
    return s / Double((x1 - x0 + 1) * (y1 - y0 + 1))
}

private func boxBlur(_ src: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
    let ii = integralImage(src, w, h)
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { out[y*w + x] = Float(boxMean(ii, w, h, x, y, r)) } }
    return out
}

/// 二乗和の積分画像。局所のばらつきを O(1) で求めるために使う。
/// 値が大きくなるので Double でないと精度が足りない。
private func integralSquares(_ src: [Float], _ w: Int, _ h: Int) -> [Double] {
    let W = w + 1
    var ii = [Double](repeating: 0, count: W * (h + 1))
    for y in 0..<h {
        var rowSum: Double = 0
        for x in 0..<w {
            let v = Double(src[y*w + x])
            rowSum += v * v
            ii[(y+1)*W + (x+1)] = ii[y*W + (x+1)] + rowSum
        }
    }
    return ii
}

/// 黒を膨らませて細い線を残す（分離型の最小値フィルタ）
private func dilateBlack(_ src: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
    var tmp = [Float](repeating: 255, count: w * h)
    var out = [Float](repeating: 255, count: w * h)
    for y in 0..<h { for x in 0..<w {
        var m: Float = 255
        for k in -r...r { let xx = x + k
            if xx < 0 || xx >= w { continue }
            m = min(m, src[y*w + xx]) }
        tmp[y*w + x] = m
    }}
    for y in 0..<h { for x in 0..<w {
        var m: Float = 255
        for k in -r...r { let yy = y + k
            if yy < 0 || yy >= h { continue }
            m = min(m, tmp[yy*w + x]) }
        out[y*w + x] = m
    }}
    return out
}

/// 鉛筆線を読みやすくする一連の処理。元画像は変更しない。
func applyPencilFilter(_ image: CGImage, _ f: PencilFilter) -> CGImage {
    guard f.enabled else { return image }
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return image }

    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let raw = ctx.data else { return image }
    let bpr = ctx.bytesPerRow
    let src = raw.bindMemory(to: UInt8.self, capacity: bpr * h)

    // 1) グレースケール + レベル補正（薄い線を持ち上げる）
    var lum = [Float](repeating: 0, count: w * h)
    let bp = Float(f.black) * 255, wp = Float(f.white) * 255
    let span = max(1, wp - bp)
    for y in 0..<h {
        for x in 0..<w {
            let v = (Float(src[y*bpr + x]) - bp) / span * 255
            lum[y*w + x] = min(255, max(0, v))
        }
    }

    // 2) ノイズ除去
    let work = f.blur > 0 ? boxBlur(lum, w, h, f.blur) : lum

    // 3) 二値化
    var bw = [Float](repeating: 0, count: w * h)
    if f.auto {
        // Sauvola 法。局所の平均 m とばらつき sd から、その場所のしきい値を決める。
        //   T = m * (1 + k * (sd / R - 1))
        // 影の中（m が小さい）ではしきい値も下がるので、影そのものは黒にならない。
        // 地の紙のように平坦な場所（sd がほぼ0）では T が m より十分小さくなり、
        // 紙の微妙なムラを拾わない。
        let ii  = integralImage(work, w, h)
        let ii2 = integralSquares(work, w, h)
        // 半径は画の大きさから決める。線の太さに対して十分広く取る。
        let r = max(8, min(w, h) / 24)
        let k = f.autoStrength
        let R = 128.0
        for y in 0..<h {
            for x in 0..<w {
                let m  = boxMean(ii,  w, h, x, y, r)
                let m2 = boxMean(ii2, w, h, x, y, r)
                let variance = max(0, m2 - m * m)
                let sd = variance.squareRoot()
                let t = m * (1 + k * (sd / R - 1))
                bw[y*w + x] = Double(work[y*w + x]) < t ? 0 : 255
            }
        }
    } else if f.adaptive {
        // 局所平均より暗い画素を線とみなす
        let ii = integralImage(work, w, h)
        let bias = (0.6 - f.threshold) * 120
        for y in 0..<h {
            for x in 0..<w {
                let m = boxMean(ii, w, h, x, y, f.radius)
                bw[y*w + x] = Double(work[y*w + x]) < m - bias ? 0 : 255
            }
        }
    } else {
        let t = Float(f.threshold) * 255
        for i in 0..<(w*h) { bw[i] = work[i] < t ? 0 : 255 }
    }

    // 4) 線を太く
    let fin = f.dilate > 0 ? dilateBlack(bw, w, h, f.dilate) : bw

    // 5) 強度でブレンド
    guard let out = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let odata = out.data else { return image }
    let obpr = out.bytesPerRow
    let dst = odata.bindMemory(to: UInt8.self, capacity: obpr * h)
    let a = Float(f.strength)
    for y in 0..<h {
        for x in 0..<w {
            let v = lum[y*w + x] * (1 - a) + fin[y*w + x] * a
            dst[y*obpr + x] = UInt8(min(255, max(0, v.rounded())))
        }
    }
    return out.makeImage() ?? image
}

/// 1コマ分。フル解像度はディスク、メモリには表示用の縮小画像だけを持つ。
struct Frame: Identifiable {
    let id = UUID()
    let url: URL          // フル解像度 PNG のファイル（無加工の原本）
    let preview: CGImage  // 表示・再生用の縮小画像（無加工）
    var display: CGImage  // 実際に画面に出す画像（2値化などを適用したもの）
    /// このコマを何コマ分の長さで見せるか。2 なら 2コマ打ち。最大 48（24fps で 2 秒）。
    var hold: Int = 1

    init(url: URL, preview: CGImage, display: CGImage? = nil, hold: Int = 1) {
        self.url = url
        self.preview = preview
        self.display = display ?? preview
        self.hold = hold
    }
}

final class FrameStore: ObservableObject {

    @Published private(set) var frames: [Frame] = []
    @Published private(set) var folder: URL
    /// プロジェクト名。フォルダ名とコマの連番ファイル名に使う。
    @Published private(set) var projectName: String = "PencilTest"

    private var counter = 0
    private let io = DispatchQueue(label: "pencilTest.io")

    /// 取り消し履歴。並び順のスナップショットを最大10件保持する。
    /// ディスク上の PNG は消さないので、削除したコマもこれで戻せる。
    /// 表示用画像の作り直しは重いので、裏で走らせて古い依頼は捨てる
    private let filterQueue = DispatchQueue(label: "pencilTest.filter", qos: .userInitiated)
    private let genLock = NSLock()
    private var _filterGen = 0
    /// 調整を反映中か（画面に「処理中」を出すため）
    @Published private(set) var isFiltering = false

    private var currentGen: Int {
        genLock.lock(); defer { genLock.unlock() }; return _filterGen
    }

    private var history: [[Frame]] = []
    private var redoStack: [[Frame]] = []
    private let historyLimit = 10
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0

    /// 鉛筆線の調整。元の PNG には一切手を加えず、表示と書き出しにだけ効く。
    private(set) var filter = PencilFilter()

    /// 表示用プレビューの長辺（px）。フル解像度はディスクにしかない。
    /// 二値化はこの解像度で行うので、小さすぎると細い鉛筆線が潰れる。
    /// 1コマにつき元画像と処理後の2枚を持つため、上げすぎるとメモリを圧迫する。
    private let previewEdge: CGFloat = 1024

    static let baseFolderKey = "captureBaseFolder"

    /// 保存先の親フォルダを変える。撮影前のみ有効（途中で変えるとコマが散らばるため）。
    @discardableResult
    func changeBase(to base: URL) -> Bool {
        guard frames.isEmpty else { return false }
        UserDefaults.standard.set(base.path, forKey: Self.baseFolderKey)
        folder = Self.sessionFolder(under: base, name: projectName)
        counter = 0
        clearHistory()
        return true
    }

    /// ファイル名に使えない文字を落とす
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: bad).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "PencilTest" : cleaned
    }

    private static func sessionFolder(under base: URL, name: String) -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let safe = sanitize(name)
        let f = base.appendingPathComponent("PencilTest/\(safe)_\(stamp.string(from: Date()))",
                                            isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// プロジェクト名を変える。撮影前のみ有効。フォルダも作り直す。
    @discardableResult
    func setProjectName(_ name: String) -> Bool {
        guard frames.isEmpty else { return false }
        projectName = Self.sanitize(name)
        folder = Self.sessionFolder(under: folder.deletingLastPathComponent()
                                             .deletingLastPathComponent(),
                                    name: projectName)
        counter = 0
        clearHistory()
        return true
    }

    init(baseFolder: URL? = nil) {
        #if os(iOS)
        // iOS はサンドボックス内の Documents（ファイル App から見える）
        let searchPath = FileManager.SearchPathDirectory.documentDirectory
        #else
        let searchPath = FileManager.SearchPathDirectory.moviesDirectory
        #endif
        let saved = UserDefaults.standard.string(forKey: Self.baseFolderKey)
            .map { URL(fileURLWithPath: $0) }
        let base = baseFolder
            ?? saved
            ?? FileManager.default.urls(for: searchPath, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        // init 中は self を参照できないので、既定名をローカルで持つ
        let name = "PencilTest"
        projectName = name
        folder = Self.sessionFolder(under: base, name: name)
    }

    // MARK: 取り消し

    private func snapshot() {
        history.append(frames)
        if history.count > historyLimit { history.removeFirst() }
        // 新しい操作をしたらやり直しの履歴は無効になる
        redoStack.removeAll()
        syncCounts()
    }

    private func clearHistory() {
        history.removeAll()
        redoStack.removeAll()
        syncCounts()
    }

    private func syncCounts() {
        undoCount = history.count
        redoCount = redoStack.count
    }

    /// 直前の操作を取り消す（最大10回）
    @discardableResult
    func undo() -> Bool {
        guard let last = history.popLast() else { return false }
        redoStack.append(frames)
        if redoStack.count > historyLimit { redoStack.removeFirst() }
        frames = last
        syncCounts()
        saveManifest()
        return true
    }

    /// 取り消した操作をやり直す
    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        history.append(frames)
        if history.count > historyLimit { history.removeFirst() }
        frames = next
        syncCounts()
        saveManifest()
        return true
    }

    // MARK: 撮影

    func append(_ image: CGImage) {
        snapshot()
        counter += 1
        let url = folder.appendingPathComponent(
            String(format: "%@_%04d.png", Self.sanitize(projectName), counter))
        let preview = downscale(image) ?? image
        frames.append(Frame(url: url, preview: preview, display: processed(preview)))
        io.async { writePNG(image, to: url) }
        saveManifest()
    }

    /// 指定したコマの次に、新しいコマを差し込む。戻り値は挿入位置。
    @discardableResult
    func insert(_ image: CGImage, after index: Int) -> Int {
        snapshot()
        counter += 1
        let url = folder.appendingPathComponent(
            String(format: "%@_%04d.png", Self.sanitize(projectName), counter))
        let preview = downscale(image) ?? image
        let pos = min(max(0, index + 1), frames.count)
        frames.insert(Frame(url: url, preview: preview, display: processed(preview)), at: pos)
        io.async { writePNG(image, to: url) }
        saveManifest()
        return pos
    }

    // MARK: 並べ替え・削除

    func removeLast() {
        guard !frames.isEmpty else { return }
        snapshot()
        frames.removeLast()
        saveManifest()
    }

    func remove(at index: Int) {
        guard frames.indices.contains(index) else { return }
        snapshot()
        frames.remove(at: index)
        saveManifest()
    }

    /// 複数のコマをまとめて削除する。
    /// 後ろから消さないと添字がずれるので、この順序はここで担保する。
    func remove(indices: Set<Int>) {
        let valid = indices.filter { frames.indices.contains($0) }
        guard !valid.isEmpty else { return }
        snapshot()
        for i in valid.sorted(by: >) { frames.remove(at: i) }
        saveManifest()
    }

    /// 同じファイルを指す新しいコマを足す（2コマ打ちの確認用）
    func duplicate(at index: Int) {
        guard frames.indices.contains(index) else { return }
        snapshot()
        let f = frames[index]
        frames.insert(Frame(url: f.url, preview: f.preview, display: f.display, hold: f.hold), at: index)
        saveManifest()
    }

    func move(from: Int, to: Int) {
        guard frames.indices.contains(from), frames.indices.contains(to) else { return }
        snapshot()
        let item = frames.remove(at: from)
        frames.insert(item, at: to)
        saveManifest()
    }

    /// コマの長さ（持ち数）を変える
    func setHold(at index: Int, to hold: Int) {
        guard frames.indices.contains(index) else { return }
        snapshot()
        // 24fps で 2 秒 = 48 コマまで止められるようにする
        frames[index].hold = max(1, min(48, hold))
        saveManifest()
    }

    /// 持ち数のぶんだけ展開したコマ番号の並び。再生に使う。
    var expandedIndices: [Int] {
        var out: [Int] = []
        out.reserveCapacity(frames.reduce(0) { $0 + $1.hold })
        for (i, f) in frames.enumerated() {
            out.append(contentsOf: Array(repeating: i, count: f.hold))
        }
        return out
    }

    /// 持ち数のぶんだけ展開したファイルの並び。書き出しに使う。
    var expandedURLs: [URL] {
        frames.flatMap { Array(repeating: $0.url, count: $0.hold) }
    }

    /// 展開後の総コマ数
    var totalFrameCount: Int { frames.reduce(0) { $0 + $1.hold } }

    // MARK: プロジェクト共通のファイル（背景など）

    /// コマに属さない、プロジェクト全体で使うデータを保存する
    func writeProjectFile(_ data: Data, named name: String) {
        let url = folder.appendingPathComponent(name)
        io.async { try? data.write(to: url) }
    }

    func readProjectFile(named name: String) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(name))
    }

    // MARK: プロジェクトの保存と再開

    /// 保存済みプロジェクトの一覧（新しい順）
    static func savedProjects(under base: URL? = nil) -> [URL] {
        #if os(iOS)
        let search = FileManager.SearchPathDirectory.documentDirectory
        #else
        let search = FileManager.SearchPathDirectory.moviesDirectory
        #endif
        let root = (base
            ?? UserDefaults.standard.string(forKey: baseFolderKey).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: search, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("PencilTest", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("sequence.json").path) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }
    }

    /// 保存済みのフォルダを開いて、コマを読み戻す
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("sequence.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = obj["frames"] as? [String] else { return false }
        let holds = (obj["holds"] as? [Int]) ?? []

        var loaded: [Frame] = []
        var maxNumber = 0
        for (i, name) in names.enumerated() {
            let f = url.appendingPathComponent(name)
            guard let img = loadCGImage(at: f) else { continue }
            let p = downscale(img) ?? img
            loaded.append(Frame(url: f, preview: p, display: processed(p),
                                hold: i < holds.count ? holds[i] : 1))
        }
        // 連番の続きから採番する（既存ファイルを上書きしないため）
        for f in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            if let m = f.range(of: #"_(\d{4})\.png$"#, options: .regularExpression) {
                let n = Int(f[m].dropFirst().prefix(4)) ?? 0
                maxNumber = max(maxNumber, n)
            }
        }
        guard !loaded.isEmpty else { return false }

        folder = url
        frames = loaded
        counter = maxNumber
        projectName = url.lastPathComponent
            .replacingOccurrences(of: #"_\d{4}-\d{2}-\d{2}_\d{4}$"#,
                                  with: "", options: .regularExpression)
        clearHistory()
        return true
    }

    /// 新しいプロジェクトを始める（いまのコマは残したまま、別フォルダへ移る）
    func startNewProject(named name: String) {
        let base = folder.deletingLastPathComponent().deletingLastPathComponent()
        projectName = Self.sanitize(name)
        folder = Self.sessionFolder(under: base, name: projectName)
        frames = []
        counter = 0
        clearHistory()
    }

    // MARK: 付随データ（ストローク情報など）

    /// コマと同じ名前・別の拡張子でデータを保存する。
    /// 描いた線の情報を残しておけば、あとから描き直せる。
    func writeSidecar(_ data: Data, for frame: Frame, ext: String) {
        let url = frame.url.deletingPathExtension().appendingPathExtension(ext)
        io.async { try? data.write(to: url) }
    }

    /// 付随データを読む。無ければ nil。
    func readSidecar(for frame: Frame, ext: String) -> Data? {
        let url = frame.url.deletingPathExtension().appendingPathExtension(ext)
        return try? Data(contentsOf: url)
    }

    /// 既にあるコマの絵を差し替える（描き直したとき）
    func replace(at index: Int, with image: CGImage) {
        guard frames.indices.contains(index) else { return }
        let url = frames[index].url
        let preview = downscale(image) ?? image
        frames[index] = Frame(url: url, preview: preview,
                              display: processed(preview), hold: frames[index].hold)
        io.async { writePNG(image, to: url) }
    }

    /// 保留中のディスク書き込みが終わるまで待つ
    func flush() { io.sync {} }

    /// 調整を変え、表示用画像を作り直す。
    /// スライダーを動かすと連続で呼ばれるので、裏で処理して古い依頼は捨てる。
    /// これをメインスレッドで同期実行すると、コマ数に比例して画面が固まる。
    func setFilter(_ f: PencilFilter) {
        filter = f

        genLock.lock(); _filterGen += 1; let gen = _filterGen; genLock.unlock()

        let snapshot = frames.map { (id: $0.id, preview: $0.preview) }
        guard !snapshot.isEmpty else { return }
        isFiltering = true

        filterQueue.async { [weak self] in
            guard let self else { return }
            // 順番待ちしている間に新しい依頼が来ていたら、何もせず捨てる
            if self.currentGen != gen { return }

            var results: [UUID: CGImage] = [:]
            results.reserveCapacity(snapshot.count)
            for item in snapshot {
                if self.currentGen != gen { return }
                results[item.id] = applyPencilFilter(item.preview, f)
            }

            DispatchQueue.main.async {
                guard self.currentGen == gen else { return }
                for i in self.frames.indices {
                    if let img = results[self.frames[i].id] { self.frames[i].display = img }
                }
                self.isFiltering = false
            }
        }
    }

    /// テストや書き出し前に、反映待ちを終わらせる
    func flushFilter() {
        filterQueue.sync {}
        let f = filter
        for i in frames.indices { frames[i].display = applyPencilFilter(frames[i].preview, f) }
        isFiltering = false
    }

    private func processed(_ image: CGImage) -> CGImage {
        applyPencilFilter(image, filter)
    }

    // MARK: 内部

    /// 現在の並び順を JSON で残す。フォルダだけ見ても順番が分かるようにするため。
    private func saveManifest() {
        let names = frames.map { $0.url.lastPathComponent }
        let holds = frames.map { $0.hold }
        let dest = folder.appendingPathComponent("sequence.json")
        io.async {
            guard let data = try? JSONSerialization.data(
                withJSONObject: ["frames": names, "holds": holds],
                options: [.prettyPrinted]) else { return }
            try? data.write(to: dest)
        }
    }

    private func downscale(_ image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, previewEdge / max(w, h))
        if scale >= 1 { return image }
        let nw = Int(w * scale), nh = Int(h * scale)
        guard let ctx = CGContext(data: nil, width: nw, height: nh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}

private func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

