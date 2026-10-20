import SwiftUI
import AVFoundation
import UIKit

@main
struct PencilTestApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// MARK: - 共有シート（MP4 を書き出したあとの保存先選択）

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 本体

struct RootView: View {

    @StateObject private var camera = CameraController()
    @StateObject private var store = FrameStore()

    @State private var selectedIndex: Int?
    @State private var isPlaying = false
    @State private var playIndex = 0
    @State private var playTimer: Timer?

    @State private var fps: Double = 12
    /// 横画面で 16:9 固定。選択肢は出さない。
    private let aspect: FrameAspect = .wide
    @State private var onionEnabled = true
    @State private var onionOpacity: Double = 0.35
    @State private var flashOpacity: Double = 0

    @State private var filter = PencilFilter()
    /// 操作パネルを横に置ける広さか（iPad と iPhone 横位置）
    @State private var isWide = false
    @State private var showAdvanced = false
    @State private var fullscreen = false
    /// シャッター速度の分母（露出の詳細設定用）
    @State private var ssDenominator: Double = 60
    @State private var askName = false
    @State private var exportName = "線画撮りくん"
    @State private var guideOn = true
    @State private var safety: Double = 0.9

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var alertMessage: String?

    private let amber = Color(red: 0.84, green: 0.55, blue: 0.27)
    private let panel = Color(white: 0.1)

    var body: some View {
        GeometryReader { geo in
            // 幅に余裕があれば操作パネルを横に置く。
            // iPad は縦位置でも 800pt 以上あるので、常にこちらになる。
            let wide = geo.size.width >= 700
            // if/else でビューを差し替えると回転のたびに全体が作り直され、
            // カメラのプレビューレイヤーまで再生成されて待たされる。
            // AnyLayout ならビューの同一性を保ったまま並びだけ変えられる。
            let layout = wide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 0) {
                    stage
                    if !fullscreen { filmstrip }
                }
                if !fullscreen {
                    controls
                        .frame(width: wide ? 330 : nil)
                        .frame(maxHeight: wide ? .infinity : geo.size.height * 0.46)
                }
            }
            .onAppear { isWide = wide }
            .onChange(of: wide) { isWide = wide }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard)
        .onAppear { camera.start() }
        .alert("ファイル名", isPresented: $askName) {
            TextField("名前", text: $exportName)
            Button("書き出す") { exportMovie() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("拡張子 .mp4 は自動で付きます")
        }
        .sheet(isPresented: $showShare) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
        .alert("お知らせ", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: ステージ

    /// カメラのプレビューは常に置いたままにする。
    /// 比率の変更やコマの確認のたびに作り直すと、セッションを繋ぎ直すことになり固まる。
    private var stage: some View {
        ZStack {
            Color.black
            liveView
            if let index = displayedIndex {
                // ライブの上に重ねるだけ。プレビューは壊さない。
                Color.black
                Image(decorative: store.frames[index].display, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            if let message = camera.errorMessage {
                Color.black
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            Color.white.opacity(flashOpacity).allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) { fullscreenHint }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            // ダブルタップを先に判定する。単タップはピント合わせのまま。
            SpatialTapGesture(count: 2)
                .onEnded { _ in withAnimation(.easeInOut(duration: 0.2)) { fullscreen.toggle() } }
                .exclusively(before: SpatialTapGesture().onEnded { value in
                    guard displayedIndex == nil else { return }
                    camera.focus(atLayerPoint: value.location)
                })
        )
    }

    /// 与えられた領域に収まる最大の矩形を求める。
    /// aspectRatio 修飾子は固有サイズを持たないビューでは膨らむことがあるので、
    /// 実寸を自分で計算して固定する。
    private func fittedBox(ratio: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 1, size.height > 1, ratio > 0.05, ratio < 20 else { return size }
        var w = size.width
        var h = w / ratio
        if h > size.height { h = size.height; w = h * ratio }
        return CGSize(width: floor(w), height: floor(h))
    }

    /// 比率によって変えるのは「値」だけ。ビューの構造は常に同じにする。
    private var liveView: some View {
        GeometryReader { g in
            let ratio = aspect.ratio ?? camera.activeAspect
            let bounded = aspect.ratio != nil
            let inset: CGFloat = bounded ? 6 : 0
            let area = CGSize(width: max(1, g.size.width - inset * 2),
                              height: max(1, g.size.height - inset * 2))
            let box = fittedBox(ratio: ratio, in: area)
            ZStack {
                CameraPreview(session: camera.session,
                              gravity: bounded ? .resizeAspectFill : .resizeAspect,
                              onReady: { camera.previewLayer = $0 },
                              onRotation: { camera.setOutputRotation($0) })
                onionOverlay
                guideOverlay.opacity(guideOn && bounded ? 1 : 0)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .overlay(Rectangle().stroke(bounded ? amber.opacity(0.7) : .clear, lineWidth: 1))
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    @ViewBuilder
    private var onionOverlay: some View {
        if onionEnabled, let last = store.frames.last {
            Image(decorative: last.display, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(onionOpacity)
                .allowsHitTesting(false)
        }
    }

    /// 16:9 のフレームガイド。外枠・セーフティ枠・センター十字。
    private var guideOverlay: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let arm = min(w, h) * 0.035
            ZStack {
                Rectangle()
                    .stroke(amber.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: w * safety, height: h * safety)
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: h / 2 - arm))
                    p.addLine(to: CGPoint(x: w / 2, y: h / 2 + arm))
                    p.move(to: CGPoint(x: w / 2 - arm, y: h / 2))
                    p.addLine(to: CGPoint(x: w / 2 + arm, y: h / 2))
                }
                .stroke(amber.opacity(0.75), lineWidth: 1)
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
    }

    /// サムネイルの一辺。広い画面では大きくする。
    private var thumbSide: CGFloat { isWide ? 76 : 52 }

    /// 全画面のときだけ、戻り方を小さく出す
    @ViewBuilder
    private var fullscreenHint: some View {
        if fullscreen {
            Text("ダブルタップで戻る")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(12)
        }
    }

    private var displayedIndex: Int? {
        if isPlaying {
            let seq = store.expandedIndices
            guard !seq.isEmpty else { return nil }
            return seq[min(playIndex, seq.count - 1)]
        }
        return selectedIndex
    }

    // MARK: フィルムストリップ

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if store.frames.isEmpty {
                        Text("撮影したコマがここに並びます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    ForEach(Array(store.frames.enumerated()), id: \.element.id) { pair in
                        Image(decorative: pair.element.display, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: thumbSide, height: thumbSide)
                            .clipped()
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(displayedIndex == pair.offset ? amber : .clear, lineWidth: 2)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if pair.element.hold > 1 {
                                    Text("×\(pair.element.hold)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(amber, in: Capsule())
                                        .padding(3)
                                }
                            }
                            .id(pair.offset)
                            .onTapGesture {
                                guard !isPlaying else { return }
                                selectedIndex = (selectedIndex == pair.offset) ? nil : pair.offset
                            }
                            .contextMenu {
                                Section("このコマの長さ") {
                                    ForEach([1, 2, 3, 4, 6, 8, 12, 16, 24, 36, 48], id: \.self) { n in
                                        Button {
                                            store.setHold(at: pair.offset, to: n)
                                        } label: {
                                            let label = "\(n)コマ"
                                            if pair.element.hold == n {
                                                Label(label, systemImage: "checkmark")
                                            } else {
                                                Text(label)
                                            }
                                        }
                                    }
                                }
                                Button("このコマを複製") { store.duplicate(at: pair.offset) }
                                Button("このコマを削除", role: .destructive) {
                                    store.remove(at: pair.offset); selectedIndex = nil
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .onChange(of: store.frames.count) {
                if let last = store.frames.indices.last {
                    proxy.scrollTo(last, anchor: .trailing)
                }
            }
        }
        .frame(height: thumbSide + 16)
        .background(panel)
    }

    // MARK: 操作パネル

    private var controls: some View {
        ScrollView {
            VStack(spacing: 14) {

                HStack(spacing: 26) {
                    Button { undo() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.title3)
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(store.frames.isEmpty || isPlaying)

                    Button { capture() } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 62, height: 62)
                            .overlay(Circle().stroke(Color(white: 0.35), lineWidth: 4))
                    }
                    .keyboardShortcut(KeyEquivalent(" "), modifiers: [])
                    .disabled(!camera.isReady || isPlaying)

                    Button { togglePlayback() } label: {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.title)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isPlaying ? .orange : .accentColor)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(store.frames.count < 2)
                }

                HStack(spacing: 20) {
                    Button { stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(store.frames.isEmpty || isPlaying)
                    Button { selectedIndex = nil } label: {
                        Text("🔴 LIVE")
                            .font(.callout.bold())
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(selectedIndex == nil)
                    Button { stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(store.frames.isEmpty || isPlaying)
                }
                .buttonStyle(.bordered)

                Text(store.totalFrameCount == store.frames.count
                     ? "コマ数 \(store.frames.count)"
                     : "コマ数 \(store.frames.count) → \(store.totalFrameCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // 再生速度
                VStack(spacing: 4) {
                    Text("再生 fps").font(.caption2).foregroundStyle(.secondary)
                    Picker("fps", selection: $fps) {
                        Text("6").tag(6.0)
                        Text("8").tag(8.0)
                        Text("12").tag(12.0)
                        Text("24").tag(24.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: fps) { if isPlaying { restartPlayback() } }
                }

                // 鉛筆線
                VStack(spacing: 8) {
                    Toggle(isOn: $filter.enabled) {
                        Text("✏️ 鉛筆線をくっきり")
                            .font(.callout.bold())
                    }
                    .tint(amber)
                    if store.isFiltering {
                        Text("反映中…").font(.caption2).foregroundStyle(.secondary)
                    }
                    if filter.enabled {
                        Toggle("おまかせ", isOn: $filter.auto).font(.caption)
                        if filter.auto {
                            Picker("", selection: $filter.autoStrength) {
                                Text("弱").tag(0.32)
                                Text("中").tag(0.20)
                                Text("強").tag(0.10)
                            }
                            .pickerStyle(.segmented)
                            Text("紙に落ちた影を避けて、線だけを拾います。\n強いほど薄い線まで拾います。紙の汚れも拾うようなら弱くしてください。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Picker("", selection: $filter.adaptive) {
                                Text("適応").tag(true)
                                Text("単純").tag(false)
                            }
                            .pickerStyle(.segmented)
                            row("しきい値", $filter.threshold, 0.01...0.99) { "\(Int($0 * 100))" }
                            if filter.adaptive { introw("範囲", $filter.radius, 2...40) }
                            row("黒レベル", $filter.black, 0...0.9) { "\(Int($0 * 100))" }
                            row("白レベル", $filter.white, 0.1...1.0) { "\(Int($0 * 100))" }
                            introw("ノイズ除去", $filter.blur, 0...4)
                            introw("線を太く", $filter.dilate, 0...3)
                            row("強度", $filter.strength, 0...1) { "\(Int($0 * 100))%" }
                        }
                    }
                }
                .onChange(of: filter) { store.setFilter(filter) }

                // ガイド
                VStack(spacing: 4) {
                    Toggle("フレームガイド", isOn: $guideOn).font(.caption)
                    if guideOn {
                        row("セーフティ", $safety, 0.7...0.98) { "\(Int($0 * 100))%" }
                    }
                }

                HStack(spacing: 12) {
                    Button(camera.isLocked ? "固定中 — 解除" : "すべて固定") {
                        camera.isLocked ? camera.unlockEverything() : camera.lockEverything()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(camera.isLocked ? amber : .accentColor)

                    Toggle("オニオン", isOn: $onionEnabled)
                        .font(.caption)
                        .fixedSize()
                }

                // 書き出し
                if isExporting {
                    VStack(spacing: 4) {
                        ProgressView(value: exportProgress)
                        Text("MP4に変換中… \(Int(exportProgress * 100))%")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        askName = true
                    } label: {
                        Label("MP4として書き出す", systemImage: "square.and.arrow.up").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.frames.count < 2)
                }

                // 詳細設定（普段は畳んでおく）
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(spacing: 8) {
                        if camera.canSetExposure {
                            Text("露出").font(.caption2).foregroundStyle(.secondary)
                            row("ISO", Binding(
                                get: { Double(camera.iso) },
                                set: { camera.setExposure(iso: Float($0), shutter: camera.shutterDenominator) }),
                                Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound)) { "\(Int($0))" }
                            row("SS", $ssDenominator, 30...1000) { "1/\(Int($0))" }
                                .onChange(of: ssDenominator) {
                                    camera.setExposure(iso: camera.iso, shutter: ssDenominator)
                                }
                        }
                    }
                    .onChange(of: filter) { store.setFilter(filter) }
                } label: {
                    Text("詳細設定").font(.caption).foregroundStyle(.secondary)
                }

                if let mm = camera.minimumFocusDistanceMM {
                    Text("最短撮影距離 \(mm)mm — 紙をこれより近づけるとピントが合いません")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text("ステージをダブルタップすると全画面")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(panel)
    }


    private func row(_ label: String, _ value: Binding<Double>,
                     _ range: ClosedRange<Double>,
                     _ fmt: @escaping (Double) -> String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
            Text(fmt(value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func introw(_ label: String, _ value: Binding<Int>,
                        _ range: ClosedRange<Int>) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value.wrappedValue)")
                .font(.caption2.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: 動作

    private func capture() {
        guard camera.isReady, !isPlaying else { return }
        selectedIndex = nil
        let ratio = aspect.ratio
        camera.grabFrame { image in
            let final = ratio.map { cropCenter(image, ratio: $0) } ?? image
            store.append(final)
            flashOpacity = 0.45
            withAnimation(.easeOut(duration: 0.18)) { flashOpacity = 0 }
        }
    }

    private func undo() {
        guard !store.frames.isEmpty, !isPlaying else { return }
        store.removeLast()
        selectedIndex = nil
    }

    private func stepFrame(_ delta: Int) {
        guard !store.frames.isEmpty, !isPlaying else { return }
        let current = selectedIndex ?? store.frames.count
        let next = current + delta
        if next < 0 { selectedIndex = 0 }
        else if next >= store.frames.count { selectedIndex = nil }
        else { selectedIndex = next }
    }

    private func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        guard store.frames.count >= 2 else { return }
        selectedIndex = nil
        isPlaying = true
        playIndex = 0
        scheduleTimer()
    }

    private func restartPlayback() {
        playTimer?.invalidate()
        scheduleTimer()
    }

    private func scheduleTimer() {
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { _ in
            let count = store.expandedIndices.count
            guard count > 0 else { return }
            playIndex = (playIndex + 1) % count
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
        store.flush()   // 書き込み途中の PNG がないことを保証してから読む

        let urls = store.expandedURLs
        let rate = Int(fps)
        // iOS は撮影時に比率で切り抜いているので、書き出しでは切り抜かない
        let transform = makeExportTransform(cropToGuide: false, filter: store.filter)
        let safe = FrameStore.sanitize(exportName)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe).mp4")

        isExporting = true
        exportProgress = 0

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MP4Exporter.write(urls: urls, fps: rate, to: out,
                                      transform: transform) { value in
                    exportProgress = value
                }
                DispatchQueue.main.async {
                    isExporting = false
                    shareURL = out
                    showShare = true
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
