import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo

/// 書き出しの解像度
enum ExportSize: String, CaseIterable, Identifiable {
    case original = "元のまま"
    case fhd = "FHD"
    case hd = "HD"

    var id: String { rawValue }

    /// 書き出す画面サイズ。nil なら元のコマの寸法をそのまま使う。
    var pixelSize: (width: Int, height: Int)? {
        switch self {
        case .original: return nil
        case .fhd:      return (1920, 1080)
        case .hd:       return (1280, 720)
        }
    }
}

// MARK: - MP4 export

enum ExportError: LocalizedError {
    case noFrames, writerFailed(String), pixelBufferFailed
    var errorDescription: String? {
        switch self {
        case .noFrames: return "書き出すコマがありません。"
        case .writerFailed(let m): return "書き出しに失敗しました: \(m)"
        case .pixelBufferFailed: return "フレームの変換に失敗しました。"
        }
    }
}

struct MP4Exporter {

    /// 連番の CGImage を H.264 の MP4 として書き出す
    static func write(urls: [URL],
                      fps: Int,
                      to url: URL,
                      transform: ((CGImage) -> CGImage)? = nil,
                      size: ExportSize = .original,
                      progress: @escaping (Double) -> Void) throws {

        // フル解像度はディスクから1枚ずつ読む。全コマをメモリに載せない。
        guard let firstURL = urls.first,
              let loaded = loadCGImage(at: firstURL) else { throw ExportError.noFrames }
        let first = transform?(loaded) ?? loaded

        // H.264 は偶数サイズが必要。
        // 解像度を指定した場合はその画面に収める（余った所は黒帯になる）。
        let width: Int
        let height: Int
        if let target = size.pixelSize {
            width = target.width - (target.width % 2)
            height = target.height - (target.height % 2)
        } else {
            width = first.width - (first.width % 2)
            height = first.height - (first.height % 2)
        }

        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 8,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else { throw ExportError.writerFailed("入力を追加できません") }
        writer.add(input)

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "不明なエラー")
        }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        for (index, frameURL) in urls.enumerated() {
            guard let loadedFrame = loadCGImage(at: frameURL) else {
                throw ExportError.writerFailed("コマを読み込めませんでした: \(frameURL.lastPathComponent)")
            }
            let image = transform?(loadedFrame) ?? loadedFrame
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferFailed }

            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let pixelBuffer = buffer else { throw ExportError.pixelBufferFailed }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
               let ctx = CGContext(data: base,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                   space: colorSpace,
                                   bitmapInfo: bitmapInfo) {
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                // アスペクト比を保って中央に収める
                let scale = min(CGFloat(width) / CGFloat(image.width),
                                CGFloat(height) / CGFloat(image.height))
                let w = CGFloat(image.width) * scale
                let h = CGFloat(image.height) * scale
                let rect = CGRect(x: (CGFloat(width) - w) / 2,
                                  y: (CGFloat(height) - h) / 2,
                                  width: w, height: h)
                ctx.draw(image, in: rect)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "フレーム追加に失敗")
            }
            let ratio = Double(index + 1) / Double(urls.count)
            DispatchQueue.main.async { progress(ratio) }
        }

        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(urls.count),
                                               timescale: CMTimeScale(fps)))
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status != .completed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "不明なエラー")
        }
    }
}

