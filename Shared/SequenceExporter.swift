import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 連番 PNG として書き出す。
/// コマはもともと PNG でディスクにあるが、並び順・コマの長さ・解像度・
/// 鉛筆線の調整を反映した状態で、通し番号を振り直して出す。
enum SequenceExporter {

    enum ExportError: LocalizedError {
        case noFrames
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noFrames: return "書き出すコマがありません。"
            case .failed(let m): return "書き出しに失敗しました: \(m)"
            }
        }
    }

    /// 指定サイズの画面に収めて描き直す。nil なら元のまま。
    private static func fitted(_ image: CGImage, to size: ExportSize) -> CGImage {
        guard let target = size.pixelSize else { return image }
        let w = target.width, h = target.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let scale = min(CGFloat(w) / CGFloat(image.width), CGFloat(h) / CGFloat(image.height))
        let dw = CGFloat(image.width) * scale, dh = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2,
                                   width: dw, height: dh))
        return ctx.makeImage() ?? image
    }

    /// 連番 PNG をフォルダに書き出す。戻り値はそのフォルダ。
    @discardableResult
    static func writeFolder(urls: [URL],
                            named name: String,
                            to parent: URL,
                            transform: ((CGImage) -> CGImage)? = nil,
                            size: ExportSize = .original,
                            progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        guard !urls.isEmpty else { throw ExportError.noFrames }
        let safe = FrameStore.sanitize(name)
        let dir = parent.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (i, src) in urls.enumerated() {
            guard let loaded = loadCGImage(at: src) else {
                throw ExportError.failed("コマを読み込めませんでした: \(src.lastPathComponent)")
            }
            let processed = fitted(transform?(loaded) ?? loaded, to: size)
            let out = dir.appendingPathComponent(String(format: "%@_%04d.png", safe, i + 1))
            guard let dest = CGImageDestinationCreateWithURL(
                out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ExportError.failed("書き込めませんでした")
            }
            CGImageDestinationAddImage(dest, processed, nil)
            guard CGImageDestinationFinalize(dest) else {
                throw ExportError.failed("書き込めませんでした")
            }
            let ratio = Double(i + 1) / Double(urls.count)
            DispatchQueue.main.async { progress(ratio) }
        }
        return dir
    }

    /// 連番 PNG のフォルダを zip にまとめる。配布や取り出しに使う。
    static func zipFolder(_ dir: URL) throws -> URL {
        var zipURL: URL?
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading],
                                       error: &coordError) { tmp in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(dir.lastPathComponent + ".zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: tmp, to: dest)
                zipURL = dest
            } catch { copyError = error }
        }
        if let coordError { throw ExportError.failed(coordError.localizedDescription) }
        if let copyError { throw ExportError.failed(copyError.localizedDescription) }
        guard let zipURL else { throw ExportError.failed("zip を作れませんでした") }
        return zipURL
    }
}
