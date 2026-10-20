import SwiftUI
import AVFoundation
import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - App

@main
struct PencilTestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("線画撮りくん") {
            ContentView()
                .frame(minWidth: 940, minHeight: 660)
        }
        .windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Camera

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "pencilTest.sample")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var pendingCapture: ((CGImage) -> Void)?
    /// 実際に届いたフレームの寸法。設定値ではなく実測をガイドの基準にする。
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0

    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String = ""
    @Published var errorMessage: String?
    @Published var isReady: Bool = false

    /// AVFoundation 側で露出ロックが効くか（macOS では通常 false → 本体の M モードで固定する）
    @Published var canLockExposure: Bool = false
    /// 実際に使われている解像度の表示用
    @Published var activeResolution: String = ""
    /// 実際の映像の縦横比（ガイドを画角に合わせるために使う）
    @Published var activeAspect: CGFloat = 16.0 / 9.0
    /// いま使っているカメラの名前
    @Published var activeDeviceName: String = ""
    /// 内蔵ではない外部カメラを使っているか
    @Published var usingExternal: Bool = false
    /// ユーザーが手動でカメラを選んだら、自動切り替えをやめる
    private var userPickedDevice = false

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
            errorMessage = "カメラへのアクセスが拒否されています。システム設定 → プライバシーとセキュリティ → カメラ で線画撮りくんを許可してください。"
        }
    }

    private func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices
    }

    private static let lastCameraKey = "lastCameraID"

    /// Mac に繋がるカメラなら何でも使えるようにする。
    /// 前回選んだものを最優先し、次に外部カメラ、最後に内蔵カメラ。
    private func preferredDevice(from list: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let saved = UserDefaults.standard.string(forKey: Self.lastCameraKey),
           let d = list.first(where: { $0.uniqueID == saved }) { return d }
        if let ext = list.first(where: { isExternal($0) }) { return ext }
        return list.first
    }

    /// 内蔵カメラ以外（一眼のUVC出力・USBカメラ・HDMIキャプチャ・連係カメラ）
    private func isExternal(_ device: AVCaptureDevice) -> Bool {
        device.deviceType != .builtInWideAngleCamera
    }

    private func configure() {
        let found = availableDevices()
        self.devices = found

        guard let target = preferredDevice(from: found) else {
            errorMessage = "使用できるカメラが見つかりませんでした。"
            return
        }
        selectedDeviceID = target.uniqueID

        session.beginConfiguration()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        attach(device: target)
        observeConnections()

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
            DispatchQueue.main.async { self.isReady = true }
        }
    }

    private func attach(device: AVCaptureDevice) {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            // macOS では activeFormat を設定すると preset は自動で input priority 扱いになる
            applyBestFormat(to: device)
        } catch {
            errorMessage = "カメラを開けませんでした: \(error.localizedDescription)"
        }
        session.commitConfiguration()
    }

    /// 最大解像度のフォーマットを選び、可能な範囲で露出・WB・フォーカスを固定する
    private func applyBestFormat(to device: AVCaptureDevice) {
        let best = device.formats.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
        guard let best = best else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
                canLockExposure = true
            } else {
                canLockExposure = false
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            device.unlockForConfiguration()
        } catch {
            canLockExposure = false
        }

        // ここで分かるのは「要求した」形式。macOS ではセッション側が別の形式を
        // 採用することがあるので、暫定値として置き、実際のフレームで上書きする。
        let dim = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        activeResolution = "\(dim.width)×\(dim.height)"
        if dim.height > 0 { activeAspect = CGFloat(dim.width) / CGFloat(dim.height) }
        lastFrameWidth = 0; lastFrameHeight = 0
        activeDeviceName = device.localizedName
        usingExternal = isExternal(device)
    }

    // MARK: 抜き差しへの追従

    private func observeConnections() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureDevice.wasConnectedNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.handleDeviceChange()
        }
        center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.handleDeviceChange()
        }
    }

    /// カメラの抜き差し・電源の入り切りに追従する。
    /// 一眼を USB 接続すると新しいデバイスとして現れるので、自動で掴みに行く。
    private func handleDeviceChange() {
        let found = availableDevices()
        devices = found

        let stillThere = found.contains { $0.uniqueID == selectedDeviceID }

        if !stillThere {
            // いま使っていたカメラが消えた → 選び直す
            userPickedDevice = false
            guard let target = preferredDevice(from: found) else {
                errorMessage = "カメラが取り外されました。"
                return
            }
            errorMessage = nil
            selectedDeviceID = target.uniqueID
            attach(device: target)
        } else if !userPickedDevice,
                  let ext = found.first(where: { isExternal($0) }),
                  ext.uniqueID != selectedDeviceID {
            // 外部カメラが現れた → 自動で切り替える（手動で選んでいた場合は尊重する）
            selectedDeviceID = ext.uniqueID
            attach(device: ext)
        }
    }

    func select(deviceID: String) {
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) else { return }
        userPickedDevice = true
        selectedDeviceID = deviceID
        UserDefaults.standard.set(deviceID, forKey: Self.lastCameraKey)
        attach(device: device)
    }

    func refreshDevices() {
        handleDeviceChange()
    }

    /// 次に届いたフレームを1枚だけ静止画として取り出す
    func grabFrame(_ completion: @escaping (CGImage) -> Void) {
        lock.lock()
        pendingCapture = completion
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // 実際に届いた寸法を記録する。ガイドはこれを基準にするので、
        // 画面の枠と保存される画が必ず一致する。
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if w != lastFrameWidth || h != lastFrameHeight, w > 0, h > 0 {
                lastFrameWidth = w; lastFrameHeight = h
                DispatchQueue.main.async {
                    self.activeResolution = "\(w)×\(h)"
                    self.activeAspect = CGFloat(w) / CGFloat(h)
                }
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

// MARK: - Live preview

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }
    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.session = session
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspect
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - 数値表示（ダブルクリックで直接入力）

private struct EditableNumber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var scale: Double = 1        // 表示上の倍率（0〜1 を % で見せる等）
    var suffix: String = ""

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shown: Int { Int((value * scale).rounded()) }

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onAppear { text = "\(shown)"; focused = true }
            } else {
                Text("\(shown)\(suffix)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Color(white: 0.88))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = true }
                    .help("ダブルクリックで直接入力")
            }
        }
        .frame(width: 52, alignment: .trailing)
    }

    private func commit() {
        if let v = Double(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(v / scale, range.lowerBound), range.upperBound)
        }
        editing = false
    }
}

// MARK: - Main view

struct ContentView: View {

    @StateObject private var camera = CameraManager()

    @StateObject private var store = FrameStore()
    @State private var selectedIndex: Int? = nil        // nil ならライブビュー（大きく表示するコマ）
    @State private var selection: Set<Int> = []         // 選択中のコマ（複数可）
    @State private var anchorIndex: Int? = nil          // shift 範囲選択の起点
    @State private var isPlaying = false
    @State private var playIndex = 0
    @State private var playTimer: Timer?

    @State private var fps: Double = 12
    @State private var onionEnabled = true
    @State private var onionOpacity: Double = 0.35
    @State private var onionCount: Double = 1
    @State private var loopPlayback = true

    @State private var filter = PencilFilter()
    @State private var projectName = "PencilTest"
    @State private var guideOn = false
    @State private var guideOpacity: Double = 0.6
    @State private var guideSafety: Double = 0.9
    /// true なら撮影された全体、false なら 16:9 ガイドの範囲だけを書き出す
    @State private var exportFullFrame = true
    @State private var exportSize: ExportSize = .original
    /// 畳んでいるセクション名
    @State private var collapsed: Set<String> = []
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var alertMessage: String? = nil
    @State private var flashOpacity: Double = 0

    private let panel = Color(nsColor: NSColor(calibratedWhite: 0.17, alpha: 1))
    private let amber = Color(red: 0.92, green: 0.64, blue: 0.34)
    // 暗いパネルの上では .secondary が暗すぎて読めないので、明示的に指定する
    private let label = Color(white: 0.88)
    private let title = Color(white: 0.94)
    private let hint  = Color(white: 0.74)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    stage
                    Divider()
                    filmstrip
                }
                Divider()
                sidebar
            }
        }
        .background(Color.black)
        .onAppear { camera.start() }
        .alert("お知らせ", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack {
            Text("線画撮りくん")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(label)
            Text(store.projectName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(amber)

            Spacer()

            Spacer()

            Text("コマ数 \(store.frames.count)")
                .font(.system(size: 13).monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(panel)
    }

    // MARK: stage

    private var stage: some View {
        ZStack {
            Color.black

            if let message = camera.errorMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(label)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(40)
            } else if let index = displayedFrameIndex {
                Image(decorative: store.frames[index].display, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                CameraPreview(session: camera.session)
                if onionEnabled, !store.frames.isEmpty {
                    onionLayers
                }
                if guideOn { guideOverlay }
            }

            Color.white.opacity(flashOpacity).allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onionLayers: some View {
        let count = min(Int(onionCount), store.frames.count)
        let slice = Array(store.frames.suffix(count))
        return ZStack {
            ForEach(Array(slice.enumerated()), id: \.offset) { pair in
                let depth = Double(pair.offset + 1) / Double(slice.count)
                Image(decorative: pair.element.display, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(onionOpacity * depth)
            }
        }
        .allowsHitTesting(false)
    }

    /// 映像が実際に表示されている矩形と、その中に収まる 16:9 の枠を求める
    private func guideRects(in size: CGSize) -> (frame: CGRect, safe: CGRect) {
        let camA = max(0.1, camera.activeAspect)
        var iw = size.width, ih = size.width / camA
        if ih > size.height { ih = size.height; iw = ih * camA }
        let ix = (size.width - iw) / 2, iy = (size.height - ih) / 2

        var gw = iw, gh = iw * 9 / 16
        if gh > ih { gh = ih; gw = gh * 16 / 9 }
        let gx = ix + (iw - gw) / 2, gy = iy + (ih - gh) / 2
        let frame = CGRect(x: gx, y: gy, width: gw, height: gh)

        let k = CGFloat(guideSafety)
        let safe = CGRect(x: gx + gw * (1 - k) / 2, y: gy + gh * (1 - k) / 2,
                          width: gw * k, height: gh * k)
        return (frame, safe)
    }

    /// 16:9 のフレームガイド。外枠・セーフティ枠・センター十字。
    private var guideOverlay: some View {
        GeometryReader { g in
            let r = guideRects(in: g.size)
            let arm = min(r.frame.width, r.frame.height) * 0.035
            ZStack {
                Path(r.frame).stroke(amber, lineWidth: 1.5)
                Path(r.safe).stroke(amber.opacity(0.75),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                Path { p in
                    let c = CGPoint(x: r.frame.midX, y: r.frame.midY)
                    p.move(to: CGPoint(x: c.x, y: c.y - arm))
                    p.addLine(to: CGPoint(x: c.x, y: c.y + arm))
                    p.move(to: CGPoint(x: c.x - arm, y: c.y))
                    p.addLine(to: CGPoint(x: c.x + arm, y: c.y))
                }
                .stroke(amber, lineWidth: 1)
            }
            .opacity(guideOpacity)
        }
        .allowsHitTesting(false)
    }

    private var displayedFrameIndex: Int? {
        if isPlaying { return store.frames.isEmpty ? nil : playIndex }
        return selectedIndex
    }

    // MARK: filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    if store.frames.isEmpty {
                        Text("撮影したコマがここに並びます")
                            .font(.system(size: 12))
                            .foregroundColor(label)
                            .padding(.vertical, 24)
                    }
                    ForEach(Array(store.frames.enumerated()), id: \.offset) { pair in
                        thumbnail(index: pair.offset, image: pair.element.display)
                            .id(pair.offset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: store.frames.count) { _ in
                if let last = store.frames.indices.last {
                    proxy.scrollTo(last, anchor: .trailing)
                }
            }
            .scrollIndicators(.visible)
        }
        .frame(height: 106)
        .background(panel)
    }

    private func thumbnail(index: Int, image: CGImage) -> some View {
        let isCurrent = (displayedFrameIndex == index)
        let isSelected = selection.contains(index) && !isPlaying
        return ZStack(alignment: .bottomLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 70, height: 70)
                .clipped()
            Text("\(index + 1)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.white)
                .shadow(radius: 2)
                .padding(3)
        }
        .cornerRadius(7)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? amber : (isCurrent ? amber.opacity(0.5) : Color.clear),
                        lineWidth: isCurrent ? 3 : 2)
        )
        .overlay(alignment: .topTrailing) {
            if isCurrent && !isPlaying {
                Button { deleteSelection() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .padding(2)
                .help(selection.count > 1 ? "選択した\(selection.count)コマを削除" : "このコマを削除")
            }
        }
        .onTapGesture {
            guard !isPlaying else { return }
            if NSEvent.modifierFlags.contains(.shift) {
                extendSelection(to: index)
            } else {
                toggleSelection(index)
            }
        }
        .contextMenu {
            Button("このコマを削除") { delete(at: index) }
            Button("このコマを複製") { duplicate(at: index) }
            Divider()
            Button("ひとつ前へ移動") { move(from: index, to: index - 1) }
            Button("ひとつ後ろへ移動") { move(from: index, to: index + 1) }
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {

            VStack(spacing: 10) {
                Button(action: capture) {
                    Circle()
                        .fill(RadialGradient(colors: [.white, Color(white: 0.72)],
                                             center: .init(x: 0.35, y: 0.3),
                                             startRadius: 4, endRadius: 60))
                        .frame(width: 84, height: 84)
                        .overlay(Circle().stroke(Color(white: 0.25), lineWidth: 5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(" "), modifiers: [])
                .disabled(!camera.isReady || isPlaying)

                Text("スペースキーで撮影")
                    .font(.system(size: 11))
                    .foregroundColor(label)
            }
            .frame(maxWidth: .infinity)

            Group {
                sectionTitle("カメラ")
                if isOpen("カメラ") {
                Picker("", selection: Binding(
                    get: { camera.selectedDeviceID },
                    set: { camera.select(deviceID: $0) })) {
                    ForEach(camera.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
                .disabled(camera.devices.isEmpty)
                HStack(spacing: 6) {
                    Text(camera.activeResolution)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(camera.usingExternal ? amber : .secondary)
                    Text(camera.usingExternal ? "外部" : "内蔵")
                        .font(.system(size: 10))
                        .foregroundColor(label)
                    Spacer()
                    Button("再検出") { camera.refreshDevices() }
                        .controlSize(.small)
                }
                if !camera.canLockExposure {
                    Text("露出はアプリからは固定できません。\nカメラ本体を M モードにして ISO・絞り・SS を決め打ちし、\nピントも MF で固定してください。これでチラつきは消えます。")
                        .font(.system(size: 10))
                        .foregroundColor(label)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }
            }

            Group {
                sectionTitle("鉛筆線")
                if isOpen("鉛筆線") {
                if store.isFiltering {
                    Text("反映中…")
                        .font(.system(size: 10))
                        .foregroundColor(hint)
                }
                Toggle(isOn: $filter.enabled) {
                        Text("2値化する")
                            .font(.system(size: 11))
                            .foregroundColor(label)
                    }
                    .toggleStyle(.checkbox)
                if filter.enabled {
                    Toggle(isOn: $filter.auto) {
                        Text("おまかせ")
                            .font(.system(size: 11))
                            .foregroundColor(label)
                    }
                    .toggleStyle(.checkbox)
                }
                if filter.enabled && filter.auto {
                    VStack(spacing: 5) {
                        sliderRow("強さ", $filter.autoStrength, 0.05...0.5, scale: 100)
                        Text("紙に落ちた影を避けて、線だけを拾います。線がかすれるなら下げ、紙の汚れを拾うなら上げてください。")
                            .font(.system(size: 10))
                            .foregroundColor(hint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if filter.enabled && !filter.auto {
                    VStack(spacing: 5) {
                        Picker("", selection: $filter.adaptive) {
                            Text("適応").tag(true)
                            Text("単純").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        sliderRow("しきい値", $filter.threshold, 0.01...0.99, scale: 100)
                        if filter.adaptive { intRow("範囲", $filter.radius, 2...40) }
                        sliderRow("黒レベル", $filter.black, 0...0.9, scale: 100)
                        sliderRow("白レベル", $filter.white, 0.1...1.0, scale: 100)
                        intRow("ノイズ除去", $filter.blur, 0...4)
                        intRow("線を太く", $filter.dilate, 0...3)
                        sliderRow("強度", $filter.strength, 0...1, scale: 100, suffix: "%")
                        Button("初期値に戻す") {
                            var f = PencilFilter(); f.enabled = true; f.auto = false; filter = f
                        }
                        .controlSize(.small)
                    }
                }
                }
            }
            .onChange(of: filter) { _ in store.setFilter(filter) }

            Group {
                sectionTitle("16:9 ガイド")
                if isOpen("16:9 ガイド") {
                Toggle(isOn: $guideOn) {
                        Text("表示する")
                            .font(.system(size: 11))
                            .foregroundColor(label)
                    }
                    .toggleStyle(.checkbox)
                if guideOn {
                    sliderRow("透明度", $guideOpacity, 0.1...1.0, scale: 100, suffix: "%")
                    sliderRow("セーフティ", $guideSafety, 0.7...0.98, scale: 100, suffix: "%")
                }
                }
            }

            Group {
                sectionTitle("オニオンスキン")
                if isOpen("オニオンスキン") {
                Toggle(isOn: $onionEnabled) {
                        Text("表示する")
                            .font(.system(size: 11))
                            .foregroundColor(label)
                    }
                    .toggleStyle(.checkbox)
                sliderRow("濃さ", $onionOpacity, 0.1...0.8, scale: 100, suffix: "%")
                sliderRow("枚数", $onionCount, 1...3, suffix: "枚", step: 1)
                }
            }

            Group {
                sectionTitle("再生")
                if isOpen("再生") {
                Picker("", selection: $fps) {
                    Text("6").tag(6.0)
                    Text("8").tag(8.0)
                    Text("12").tag(12.0)
                    Text("24").tag(24.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: fps) { _ in restartPlayback() }
                Toggle(isOn: $loopPlayback) {
                        Text("ループ再生")
                            .font(.system(size: 11))
                            .foregroundColor(label)
                    }.toggleStyle(.checkbox)

                HStack(spacing: 6) {
                    Button(isPlaying ? "■ 停止" : "▶ 再生") { togglePlayback() }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(store.frames.count < 2)
                    Button(selection.count > 1 ? "✕ \(selection.count)コマ削除" : "✕ 削除") { deleteNow() }
                        .keyboardShortcut(.delete, modifiers: [])
                        .disabled(store.frames.isEmpty || isPlaying)
                }
                HStack(spacing: 6) {
                    Button(store.undoCount > 0 ? "↺ 取消 (\(store.undoCount))" : "↺ 取消") {
                        store.undo(); clearSelection()
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(store.undoCount == 0 || isPlaying)
                    Button(store.redoCount > 0 ? "↻ やり直し (\(store.redoCount))" : "↻ やり直し") {
                        store.redo(); clearSelection()
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(store.redoCount == 0 || isPlaying)
                }
                HStack(spacing: 6) {
                    Button("◀") { stepFrame(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(store.frames.isEmpty || isPlaying)
                    Button("▶") { stepFrame(1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(store.frames.isEmpty || isPlaying)
                    Button("ライブに戻る") { clearSelection() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .disabled(selectedIndex == nil)
                }
                }
            }

            Group {
                sectionTitle("プロジェクト")
                if isOpen("プロジェクト") {
                TextField("プロジェクト名", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .disabled(!store.frames.isEmpty)
                    .onSubmit { applyProjectName() }
                Text(store.frames.isEmpty
                     ? "return で確定。フォルダ名と連番ファイル名に使われます"
                     : "撮影を始めたあとは変えられません")
                    .font(.system(size: 10))
                    .foregroundColor(hint)
                    .fixedSize(horizontal: false, vertical: true)
                Text(store.folder.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundColor(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("撮影と同時に PNG で保存されます")
                    .font(.system(size: 10))
                    .foregroundColor(label)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("フォルダを開く") { NSWorkspace.shared.open(store.folder) }
                        .controlSize(.small)
                    Button("保存先を変える") { chooseFolder() }
                        .controlSize(.small)
                        .disabled(!store.frames.isEmpty)
                }
                if !store.frames.isEmpty {
                    Text("保存先の変更は撮影を始める前だけです")
                        .font(.system(size: 10))
                        .foregroundColor(hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }
            }

            Group {
                sectionTitle("書き出し")
                if isOpen("書き出し") {
                Picker("", selection: $exportFullFrame) {
                    Text("全体").tag(true)
                    Text("ガイドの内側").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("", selection: $exportSize) {
                    ForEach(ExportSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(exportFullFrame
                     ? "カメラに写った範囲をそのまま書き出します"
                     : "16:9 のセーフティ枠（破線）の内側を切り出します・現在 \(Int(guideSafety * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(hint)
                    .fixedSize(horizontal: false, vertical: true)
                if isExporting {
                    ProgressView(value: exportProgress)
                    Text("MP4に変換中… \(Int(exportProgress * 100))%")
                        .font(.system(size: 11))
                        .foregroundColor(label)
                } else {
                    Button("MP4として書き出す") { exportMovie() }
                        .disabled(store.frames.count < 2)
                        .frame(maxWidth: .infinity)
                }
                }
            }

            Text("space 撮影 / return 再生 / ⌘Z 取消（10回まで）\ndelete 選択コマ（未選択なら直前）を削除\n← → コマ送り / esc ライブに戻る\nshift + クリックで範囲選択 → まとめて削除\n数値はダブルクリックで直接入力")
                .font(.system(size: 11))
                .foregroundColor(hint)
                .lineSpacing(4)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 個別に色を指定していない部品（ボタン等）の既定色。
        // 明示指定のある文字はそちらが優先される。
        .foregroundColor(label)
        }
        .frame(width: 270)
        .background(panel)
    }

    private func isOpen(_ title: String) -> Bool { !collapsed.contains(title) }

    /// クリックで開閉するセクション見出し
    private func sectionTitle(_ text: String) -> some View {
        Button {
            if collapsed.contains(text) { collapsed.remove(text) } else { collapsed.insert(text) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOpen(text) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(title)
    }

    // MARK: actions

    private func capture() {
        guard camera.isReady, !isPlaying else { return }
        clearSelection()
        camera.grabFrame { image in
            store.append(image)
            flashOpacity = 0.45
            withAnimation(.easeOut(duration: 0.18)) { flashOpacity = 0 }
        }
    }

    /// クリック：単独選択。同じコマをもう一度押すとライブに戻る。
    private func toggleSelection(_ index: Int) {
        if selection == [index] {
            selection = []; selectedIndex = nil; anchorIndex = nil
        } else {
            selection = [index]; selectedIndex = index; anchorIndex = index
        }
    }

    /// shift + クリック：起点からクリックしたコマまでをまとめて選ぶ。
    private func extendSelection(to index: Int) {
        guard let anchor = anchorIndex, store.frames.indices.contains(anchor) else {
            toggleSelection(index); return
        }
        selection = Set(min(anchor, index)...max(anchor, index))
        selectedIndex = index
    }

    /// 選択中のコマをまとめて削除する。後ろから消して添字のずれを防ぐ。
    private func deleteSelection() {
        guard !selection.isEmpty, !isPlaying else { return }
        let first = selection.min() ?? 0
        store.remove(indices: selection)
        if store.frames.isEmpty {
            selection = []; selectedIndex = nil; anchorIndex = nil
        } else {
            // 続けて消せるよう、同じ位置に選択を残す
            let next = min(first, store.frames.count - 1)
            selection = [next]; selectedIndex = next; anchorIndex = next
        }
    }

    /// 選択があればそれを、無ければ直前のコマを削除する。
    private func deleteNow() {
        guard !store.frames.isEmpty, !isPlaying else { return }
        if !selection.isEmpty { deleteSelection(); return }
        store.removeLast()
        selectedIndex = nil; anchorIndex = nil
    }

    private func clearSelection() {
        selection = []; selectedIndex = nil; anchorIndex = nil
    }

    private func applyProjectName() {
        if store.setProjectName(projectName) {
            projectName = store.projectName
        } else {
            projectName = store.projectName
            alertMessage = "撮影を始めたあとはプロジェクト名を変えられません。"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "ここに保存"
        panel.title = "コマの保存先フォルダ"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.changeBase(to: url) {
            alertMessage = "撮影を始めたあとは保存先を変えられません。"
        }
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>,
                           _ range: ClosedRange<Double>,
                           scale: Double = 1, suffix: String = "",
                           step: Double? = nil) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(self.label)
                .frame(width: 58, alignment: .leading)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            EditableNumber(value: value, range: range, scale: scale, suffix: suffix)
        }
    }

    private func intRow(_ label: String, _ value: Binding<Int>,
                        _ range: ClosedRange<Int>, suffix: String = "") -> some View {
        let d = Binding(get: { Double(value.wrappedValue) },
                        set: { value.wrappedValue = Int($0.rounded()) })
        return sliderRow(label, d,
                         Double(range.lowerBound)...Double(range.upperBound),
                         suffix: suffix, step: 1)
    }

    private func delete(at index: Int) {
        guard store.frames.indices.contains(index) else { return }
        store.remove(at: index)
        clearSelection()
    }

    private func duplicate(at index: Int) {
        store.duplicate(at: index)
        clearSelection()
    }

    private func move(from: Int, to: Int) {
        store.move(from: from, to: to)
        clearSelection()
    }

    private func stepFrame(_ delta: Int) {
        guard !store.frames.isEmpty else { return }
        let current = selectedIndex ?? store.frames.count
        let next = current + delta
        if next < 0 { toggleSelectionTo(0) }
        else if next >= store.frames.count { clearSelection() }
        else { toggleSelectionTo(next) }
    }

    private func toggleSelectionTo(_ index: Int) {
        selection = [index]; selectedIndex = index; anchorIndex = index
    }

    private func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        guard store.frames.count >= 2 else { return }
        clearSelection()
        isPlaying = true
        playIndex = 0
        scheduleTimer()
    }

    /// 再生中に速度を変えたらタイマーを組み直す
    private func restartPlayback() {
        guard isPlaying else { return }
        playTimer?.invalidate()
        scheduleTimer()
    }

    private func scheduleTimer() {
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { _ in
            let next = playIndex + 1
            if next >= store.frames.count {
                if loopPlayback { playIndex = 0 }
                else { stopPlayback() }
            } else {
                playIndex = next
            }
        }
    }

    private func stopPlayback() {
        playTimer?.invalidate()
        playTimer = nil
        isPlaying = false
    }

    private func exportMovie() {
        guard store.frames.count >= 2 else { return }
        stopPlayback()

        let save = NSSavePanel()
        save.allowedContentTypes = [UTType.mpeg4Movie]
        save.nameFieldStringValue = "\(store.projectName).mp4"
        save.canCreateDirectories = true
        save.title = "MP4の保存先"

        guard save.runModal() == .OK, let url = save.url else { return }

        isExporting = true
        exportProgress = 0
        store.flush()   // 書き込み途中の PNG がないことを保証してから読む
        let snapshot = store.expandedURLs
        let rate = Int(fps)
        // ガイドの枠は「映像に収まる最大の16:9を中央に」なので、
        // 同じ計算で切り抜けば画面で見えている枠と一致する
        let outSize = exportSize
        let transform = makeExportTransform(cropToGuide: !exportFullFrame,
                                            safety: CGFloat(guideSafety),
                                            filter: store.filter)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MP4Exporter.write(urls: snapshot, fps: rate, to: url,
                                      transform: transform, size: outSize) { value in
                    exportProgress = value
                }
                DispatchQueue.main.async {
                    isExporting = false
                    alertMessage = "書き出しが完了しました。\n\(url.path)"
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }
}
