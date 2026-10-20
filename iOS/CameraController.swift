import AVFoundation
import CoreImage
import Combine
import UIKit
import SwiftUI

/// iPhone / iPad のカメラ。
/// macOS と違い、iOS ではピント・露出・WB をアプリ側から完全に固定できる。
final class CameraController: NSObject, ObservableObject,
                              AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "pencilTest.sample")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var pendingCapture: ((CGImage) -> Void)?
    private var device: AVCaptureDevice?
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published var isReady = false
    @Published var errorMessage: String?

    // ピント
    @Published var lensPosition: Float = 0.5
    @Published var canSetLensPosition = false
    /// 最短撮影距離(mm)。これより近づくとピントが合わない。
    @Published var minimumFocusDistanceMM: Int?

    // 露出
    @Published var iso: Float = 100
    @Published var isoRange: ClosedRange<Float> = 100...100
    /// シャッター速度の分母（1/x 秒）
    @Published var shutterDenominator: Double = 60
    @Published var canSetExposure = false

    @Published var isLocked = false
    /// 実際に届いている映像の縦横比。設定値ではなく実測を使う。
    @Published var activeAspect: CGFloat = 4.0 / 3.0
    private var lastW = 0, lastH = 0

    // MARK: 起動

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() }
                    else { self.errorMessage = "カメラへのアクセスが許可されませんでした。" }
                }
            }
        default:
            errorMessage = "カメラへのアクセスが拒否されています。設定 → 線画撮りくん → カメラ を確認してください。"
        }
    }

    private func configure() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video, position: .back)
        guard let device = discovery.devices.first else {
            errorMessage = "背面カメラが見つかりませんでした。"
            return
        }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .photo
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            errorMessage = "カメラを開けませんでした: \(error.localizedDescription)"
            session.commitConfiguration()
            return
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        readCapabilities(device)

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
            DispatchQueue.main.async { self.isReady = true }
        }
    }

    private func readCapabilities(_ device: AVCaptureDevice) {
        canSetLensPosition = device.isLockingFocusWithCustomLensPositionSupported
        canSetExposure = device.isExposureModeSupported(.custom)
        lensPosition = device.lensPosition

        let f = device.activeFormat
        isoRange = f.minISO...f.maxISO
        iso = min(max(device.iso, f.minISO), f.maxISO)

        let d = device.exposureDuration.seconds
        if d > 0 { shutterDenominator = (1.0 / d).rounded() }

        let mm = device.minimumFocusDistance
        minimumFocusDistanceMM = mm > 0 ? mm : nil
    }

    // MARK: ピント

    /// 画面上のタップ位置（ビュー座標）にピントを合わせる
    func focus(atLayerPoint p: CGPoint) {
        guard let layer = previewLayer else { return }
        focus(at: layer.captureDevicePointConverted(fromLayerPoint: p))
    }

    /// 0..1 の正規化座標にピントを合わせる
    func focus(at point: CGPoint) {
        guard let device = device else { return }
        withDevice(device) {
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
        }
        isLocked = false
    }

    /// レンズ位置を直接指定する（0.0 = 近, 1.0 = 遠）
    func setLens(_ position: Float) {
        guard let device = device, device.isLockingFocusWithCustomLensPositionSupported else { return }
        lensPosition = position
        withDevice(device) {
            device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
        }
    }

    // MARK: 露出

    func setExposure(iso newISO: Float, shutter denominator: Double) {
        guard let device = device, device.isExposureModeSupported(.custom) else { return }
        let f = device.activeFormat
        let clampedISO = min(max(newISO, f.minISO), f.maxISO)
        var duration = CMTime(seconds: 1.0 / denominator, preferredTimescale: 1_000_000)
        if CMTimeCompare(duration, f.minExposureDuration) < 0 { duration = f.minExposureDuration }
        if CMTimeCompare(duration, f.maxExposureDuration) > 0 { duration = f.maxExposureDuration }

        iso = clampedISO
        shutterDenominator = denominator
        withDevice(device) {
            device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
        }
        isLocked = true
    }

    // MARK: 一括ロック

    /// ピント・露出・ホワイトバランスをまとめて固定する。
    /// コマ撮りではこれを1回押したあと、二度と触らないのが正しい使い方。
    func lockEverything() {
        guard let device = device else { return }
        withDevice(device) {
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        }
        lensPosition = device.lensPosition
        iso = device.iso
        let d = device.exposureDuration.seconds
        if d > 0 { shutterDenominator = (1.0 / d).rounded() }
        isLocked = true
    }

    func unlockEverything() {
        guard let device = device else { return }
        withDevice(device) {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
        isLocked = false
    }

    /// プレビューと同じ角度を撮影データ側にも適用する
    func setOutputRotation(_ angle: CGFloat) {
        guard let c = output.connection(with: .video),
              c.isVideoRotationAngleSupported(angle) else { return }
        if c.videoRotationAngle != angle { c.videoRotationAngle = angle }
    }

    private func withDevice(_ device: AVCaptureDevice, _ body: () -> Void) {
        do {
            try device.lockForConfiguration()
            body()
            device.unlockForConfiguration()
        } catch {
            errorMessage = "カメラ設定を変更できませんでした: \(error.localizedDescription)"
        }
    }

    // MARK: 撮影

    func grabFrame(_ completion: @escaping (CGImage) -> Void) {
        lock.lock(); pendingCapture = completion; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // 実測の縦横比を記録する（ガイドと表示枠の基準）
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if (w != lastW || h != lastH), w > 0, h > 0 {
                lastW = w; lastH = h
                DispatchQueue.main.async { self.activeAspect = CGFloat(w) / CGFloat(h) }
            }
        }

        lock.lock()
        let callback = pendingCapture
        pendingCapture = nil
        lock.unlock()

        guard let callback = callback,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        DispatchQueue.main.async { callback(cgImage) }
    }
}

// MARK: - ライブプレビュー

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onReady: ((AVCaptureVideoPreviewLayer) -> Void)? = nil
    var onRotation: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = gravity
        v.onRotation = onRotation
        onReady?(v.previewLayer)
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        if v.previewLayer.session !== session { v.previewLayer.session = session }
        if v.previewLayer.videoGravity != gravity { v.previewLayer.videoGravity = gravity }
        v.onRotation = onRotation
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onRotation: ((CGFloat) -> Void)?
        /// 同じ角度を作り直さないための記録。これが無いと回転代入→再レイアウトの無限ループになる。
        private var lastAngle: CGFloat = .nan

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
        }
        required init?(coder: NSCoder) { fatalError() }

        /// 端末の向きに合わせてプレビューを回す。横位置でも正しく見えるように。
        /// 角度が変わったときだけ処理する（毎回代入するとレイアウトが無限ループする）。
        override func layoutSubviews() {
            super.layoutSubviews()
            let angle: CGFloat
            switch window?.windowScene?.interfaceOrientation {
            case .landscapeLeft:      angle = 180
            case .landscapeRight:     angle = 0
            case .portraitUpsideDown: angle = 270
            default:                  angle = 90
            }
            guard angle != lastAngle else { return }
            lastAngle = angle

            if let c = previewLayer.connection,
               c.isVideoRotationAngleSupported(angle),
               c.videoRotationAngle != angle {
                c.videoRotationAngle = angle
            }
            onRotation?(angle)
        }
    }
}
