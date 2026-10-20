import SwiftUI
import PencilKit
import UIKit
import UniformTypeIdentifiers

@main
struct RoughFlipApp: App {
    var body: some Scene {
        WindowGroup { RoughFlipView() }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct RoughFlipView: View {

    @StateObject private var store = FrameStore()

    @State private var drawing = PKDrawing()
    /// 背景は全コマ共通。1枚描けば、どのコマの後ろにも出る。
    @State private var background = PKDrawing()
    @State private var layer: Layer = .art
    @State private var rebuilding = false
    /// 背景の濃さ。下敷きとして薄く敷けるようにする。
    @State private var backgroundOpacity: Double = 0.6
    /// 作画中に後ろへ敷く背景の画像
    @State private var backgroundImage: CGImage?
    /// 消し始める前の状態。ひと続きの操作で取り消しを1件にまとめる。
    @State private var eraseStart: PKDrawing?

    enum Layer: String, CaseIterable, Identifiable {
        case art = "作画"
        case back = "背景"
        var id: String { rawValue }
    }
    @State private var tool: DrawTool = .pencil
    @State private var lineWidth: CGFloat = 6
    @State private var inkColor: Color = .black
    @State private var eraserMode: EraserMode = .hard
    /// 消しゴムは描く道具とは別に大きさを持つ
    @State private var eraserSize: EraserSize = .medium
    private var eraserWidth: CGFloat { eraserSize.width }
    @State private var canvas: CanvasView?
    /// 画面上のキャンバスの幅。描いた線を 1920 基準へ直すのに使う。
    /// レイアウトから渡される値より、キャンバス本体の実寸を優先する。
    @State private var canvasWidth: CGFloat = 0
    private var displayWidth: CGFloat {
        if let w = canvas?.bounds.width, w > 1 { return w }
        return canvasWidth
    }
    @State private var current = 0            // いま描いているコマ
    @State private var dragFrom: Int?         // 長押しでつかんだコマ
    @State private var dropAt: Int?           // 落とす先として光っているコマ
    @State private var isPlaying = false
    @State private var playPos = 0
    @State private var playTimer: Timer?

    @State private var fps: Double = 12
    @State private var onionEnabled = true
    @State private var onionOpacity: Double = 0.35
    @State private var onionCount = 1

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var askName = false
    @State private var exportName = "ラフガキちゃん"
    @State private var exportSize: ExportSize = .fhd
    @State private var exportKind: ExportKind = .mp4

    enum ExportKind: String, CaseIterable, Identifiable {
        case mp4 = "MP4"
        case png = "連番PNG"
        var id: String { rawValue }
    }
    @State private var alertMessage: String?
    @State private var askNewProject = false
    @State private var newProjectName = ""
    @State private var showOpen = false

    private let panel = Color(white: 0.11)
    private let amber = Color(red: 0.92, green: 0.64, blue: 0.34)
    /// オニオンの色。前のコマは緑、後のコマは赤。
    private let onionGreen = Color(red: 0.20, green: 0.70, blue: 0.35)
    private let onionRed   = Color(red: 0.88, green: 0.25, blue: 0.25)
    /// 作画で使う色。アタリの青鉛筆と、修正の赤を入れてある。
    private let inkChoices: [(String, Color)] = [
        ("黒", .black),
        ("青", Color(red: 0.18, green: 0.42, blue: 0.75)),
        ("赤", Color(red: 0.80, green: 0.22, blue: 0.20)),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                stage
                filmstrip
            }
            Divider()
            controls.frame(width: 300)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { ensureFirstFrame() }
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
        .alert("新しいプロジェクト", isPresented: $askNewProject) {
            TextField("名前", text: $newProjectName)
            Button("作る") { startNew() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("いまのコマは保存済みです。あとから「開く」で戻せます。")
        }
        .sheet(isPresented: $showOpen) { openSheet }
        .alert("お知らせ", isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
    }

    // MARK: 描画面

    private var stage: some View {
        GeometryReader { g in
            let box = fittedBox(in: g.size)
            ZStack {
                Color.black
                ZStack {
                    Color.white
                    if layer == .art, !isPlaying, let bg = backgroundImage {
                        Image(decorative: bg, scale: 1)
                            .resizable()
                            .frame(width: box.width, height: box.height)
                            .opacity(backgroundOpacity)
                            .allowsHitTesting(false)
                    }
                    onionLayers(box: box)
                    if layer == .back, !isPlaying, store.frames.indices.contains(current) {
                        Image(decorative: store.frames[current].display, scale: 1)
                            .resizable()
                            .frame(width: box.width, height: box.height)
                            .opacity(0.25)
                            .allowsHitTesting(false)
                    }
                    if isPlaying {
                        // 再生中は描けないようにして、絵だけを見せる
                        if let img = playingImage {
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .frame(width: box.width, height: box.height)
                        }
                    } else {
                        if tool == .eraser && !eraserMode.usesPencilKit {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: box.width, height: box.height)
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { v in
                                        // なぞり始めの状態を控えておく
                                        if eraseStart == nil { eraseStart = drawing }
                                        eraseDraft(at: v.location, radius: eraserWidth)
                                    }
                                    // 途中で毎回書き出すと重いので、指を離したときに保存する
                                    .onEnded { _ in
                                        if let start = eraseStart {
                                            canvas?.registerUndoStep(restoring: start)
                                            eraseStart = nil
                                        }
                                        commitCurrent()
                                    })
                                .zIndex(1)
                        }
                        DrawingCanvas(drawing: $drawing,
                                      tool: tool.pkTool(color: UIColor(inkColor),
                                                        // 描く道具と消しゴムで別々の大きさを使う
                                                        width: tool == .eraser ? eraserWidth : lineWidth,
                                                        eraser: eraserMode),
                                      onReady: { c in
                                          canvas = c
                                          if c.bounds.width > 1 { canvasWidth = c.bounds.width }
                                      },
                                      onChange: { _ in commitCurrent() })
                    }
                }
                .frame(width: box.width, height: box.height)
                .clipped()
                .overlay(Rectangle().stroke(Color(white: 0.3), lineWidth: 1))
            }
            .frame(width: g.size.width, height: g.size.height)
            .onAppear { canvasWidth = box.width }
            .onChange(of: box.width) { canvasWidth = box.width }
        }
    }

    private func fittedBox(in size: CGSize) -> CGSize {
        guard size.width > 1, size.height > 1 else { return size }
        var w = size.width - 16
        var h = w / CanvasSpec.ratio
        if h > size.height - 16 { h = size.height - 16; w = h * CanvasSpec.ratio }
        return CGSize(width: max(1, floor(w)), height: max(1, floor(h)))
    }

    /// 前後のコマを薄く重ねる。前は緑、後は赤。
    @ViewBuilder
    private func onionLayers(box: CGSize) -> some View {
        if onionEnabled, !isPlaying {
            ForEach(onionNeighbours, id: \.0) { index, depth, isBefore in
                // 線（暗い所）だけを色に置き換えて重ねる
                Rectangle()
                    .fill(isBefore ? onionGreen : onionRed)
                    .frame(width: box.width, height: box.height)
                    .mask(
                        Image(decorative: store.frames[index].display, scale: 1)
                            .resizable()
                            .frame(width: box.width, height: box.height)
                            .colorInvert()
                            .luminanceToAlpha()
                    )
                    .opacity(onionOpacity * depth)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 重ねるコマ番号と濃さ。離れるほど薄くする。
    private var onionNeighbours: [(Int, Double, Bool)] {
        var out: [(Int, Double, Bool)] = []
        for d in 1...max(1, onionCount) {
            let depth = 1.0 - Double(d - 1) / Double(max(1, onionCount)) * 0.5
            if store.frames.indices.contains(current - d) { out.append((current - d, depth, true)) }
            if store.frames.indices.contains(current + d) { out.append((current + d, depth, false)) }
        }
        return out
    }

    /// なぞった所にある青・赤の線を、部分的に消す
    private func eraseDraft(at point: CGPoint, radius: CGFloat) {
        let targets = inkChoices.dropFirst().map { UIColor($0.1) }
        if let d = drawing.partiallyErased(at: point, radius: radius, onlyColors: targets) {
            drawing = d
        }
    }

    private var playingImage: CGImage? {
        let seq = store.expandedIndices
        guard !seq.isEmpty else { return nil }
        return store.frames[seq[min(playPos, seq.count - 1)]].display
    }

    // MARK: コマ一覧

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(Array(store.frames.enumerated()), id: \.element.id) { pair in
                        Image(decorative: pair.element.display, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 108, height: 61)
                            .background(Color.white)
                            .overlay(
                                Rectangle().stroke(pair.offset == current ? amber : Color(white: 0.3),
                                                   lineWidth: pair.offset == current ? 3 : 1))
                            .overlay(alignment: .bottomLeading) {
                                Text("\(pair.offset + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.black)
                                    .padding(2)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if pair.element.hold > 1 {
                                    Text("×\(pair.element.hold)")
                                        .font(.caption2.bold()).foregroundStyle(.black)
                                        .padding(.horizontal, 4)
                                        .background(amber, in: Capsule())
                                        .padding(2)
                                }
                            }
                            // 落とす先の目印
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(amber)
                                    .frame(width: 4)
                                    .opacity(dropAt == pair.offset && dragFrom != pair.offset ? 1 : 0)
                            }
                            .opacity(dragFrom == pair.offset ? 0.35 : 1)
                            .id(pair.offset)
                            .onTapGesture { go(to: pair.offset) }
                            // 長押しでつかんで、動かせば並べ替え（止めたままならメニュー）
                            .onDrag {
                                dragFrom = pair.offset
                                return NSItemProvider(object: NSString(string: String(pair.offset)))
                            } preview: {
                                Image(decorative: pair.element.display, scale: 1)
                                    .resizable()
                                    .frame(width: 108, height: 61)
                                    .background(Color.white)
                            }
                            .onDrop(of: [.text],
                                    isTargeted: Binding(get: { dropAt == pair.offset },
                                                        set: { dropAt = $0 ? pair.offset : nil })) { _ in
                                drop(onto: pair.offset)
                            }
                            .contextMenu {
                                Section("このコマの長さ") {
                                    ForEach([1, 2, 3, 4, 6, 8, 12, 24, 48], id: \.self) { n in
                                        Button {
                                            store.setHold(at: pair.offset, to: n)
                                        } label: {
                                            if pair.element.hold == n {
                                                Label("\(n)コマ", systemImage: "checkmark")
                                            } else { Text("\(n)コマ") }
                                        }
                                    }
                                }
                                Button("このコマを複製") { duplicate(at: pair.offset) }
                                Divider()
                                Button("ひとつ前へ移動") { moveFrame(pair.offset, by: -1) }
                                    .disabled(pair.offset == 0)
                                Button("ひとつ後ろへ移動") { moveFrame(pair.offset, by: 1) }
                                    .disabled(pair.offset >= store.frames.count - 1)
                                Divider()
                                Button("このコマを削除", role: .destructive) { delete(at: pair.offset) }
                            }
                    }

                    // いちばん後ろへ送るための余白
                    Rectangle()
                        .fill(dropAt == store.frames.count ? amber.opacity(0.4) : Color.clear)
                        .frame(width: 40, height: 61)
                        .onDrop(of: [.text],
                                isTargeted: Binding(get: { dropAt == store.frames.count },
                                                    set: { dropAt = $0 ? store.frames.count : nil })) { _ in
                            drop(onto: store.frames.count - 1)
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: current) { proxy.scrollTo(current, anchor: .center) }
        }
        .frame(height: 90)
        .background(panel)
    }

    // MARK: 操作

    private var controls: some View {
        ScrollView {
            VStack(spacing: 14) {

                VStack(spacing: 6) {
                    Picker("レイヤー", selection: $layer) {
                        ForEach(Layer.allCases) { l in Text(l.rawValue).tag(l) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: layer) { switchedLayer() }
                    if layer == .back {
                        Text("背景は全コマ共通です。いまのコマの絵を薄く重ねて表示しています。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("背景の濃さ").font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .leading)
                        Slider(value: $backgroundOpacity, in: 0...1) { editing in
                            // 指を離したときだけ全コマに反映する
                            if !editing { rebuildAllFrames() }
                        }
                        Text("\(Int(backgroundOpacity * 100))%")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                    if rebuilding {
                        Text("背景を全コマに反映中…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 8) {
                    Picker("道具", selection: $tool) {
                        ForEach(DrawTool.allCases) { t in
                            Image(systemName: t.symbol).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    if tool == .eraser {
                        Picker("消しゴム", selection: $eraserMode) {
                            ForEach(EraserMode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                        .pickerStyle(.segmented)
                        if eraserMode.usesSize {
                            Picker("大きさ", selection: $eraserSize) {
                                ForEach(EraserSize.allCases) { s in Text(s.rawValue).tag(s) }
                            }
                            .pickerStyle(.segmented)
                        }
                    } else {
                        HStack {
                            Text("太さ").font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .leading)
                            Slider(value: $lineWidth, in: 1...30)
                            Text("\(Int(lineWidth))")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 26, alignment: .trailing)
                        }
                    }

                    HStack(spacing: 10) {
                        ForEach(inkChoices, id: \.0) { name, c in
                            Button { inkColor = c } label: {
                                Circle()
                                    .fill(c)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(
                                        inkColor == c ? amber : Color(white: 0.4),
                                        lineWidth: inkColor == c ? 3 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(name)
                        }
                        Spacer()
                        Button { canvas?.undoManager?.undo() } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        Button { canvas?.undoManager?.redo() } label: {
                            Image(systemName: "arrow.uturn.forward")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                if layer == .art {
                // 描いたあとに一番よく使う操作なので、横幅いっぱいで大きく出す
                Button { addFrame() } label: {
                    Label("新しいコマ", systemImage: "plus.square.on.square")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(amber)
                .disabled(isPlaying)

                HStack(spacing: 28) {
                    Button { go(to: current - 1) } label: {
                        Image(systemName: "backward.frame.fill").font(.title3)
                    }
                    .disabled(current == 0 || isPlaying)
                    Button { go(to: current + 1) } label: {
                        Image(systemName: "forward.frame.fill").font(.title3)
                    }
                    .disabled(current >= store.frames.count - 1 || isPlaying)
                }
                .buttonStyle(.bordered)

                Button { togglePlayback() } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(isPlaying ? .orange : .accentColor)
                .disabled(store.frames.count < 2)

                Text(store.totalFrameCount == store.frames.count
                     ? "コマ \(current + 1) / \(store.frames.count)"
                     : "コマ \(current + 1) / \(store.frames.count) → \(store.totalFrameCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("再生 fps").font(.caption2).foregroundStyle(.secondary)
                    Picker("fps", selection: $fps) {
                        Text("6").tag(6.0); Text("8").tag(8.0)
                        Text("12").tag(12.0); Text("24").tag(24.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: fps) { if isPlaying { restartTimer() } }
                }

                VStack(spacing: 6) {
                    Toggle(isOn: $onionEnabled) {
                        Text("🧅 前後のコマを透かす").font(.callout.bold())
                    }
                    .tint(amber)
                    if onionEnabled {
                        HStack {
                            Text("濃さ").font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                            Slider(value: $onionOpacity, in: 0.1...0.8)
                            Text("\(Int(onionOpacity * 100))%")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 42, alignment: .trailing)
                        }
                        Picker("枚数", selection: $onionCount) {
                            Text("1枚").tag(1); Text("2枚").tag(2); Text("3枚").tag(3)
                        }
                        .pickerStyle(.segmented)
                        Text("前は緑、後は赤で出ます。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                }

                Button { clearDraftColors() } label: {
                    Label("下書き（青・赤）を全部消す", systemImage: "eraser.line.dashed")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isPlaying)

                HStack(spacing: 10) {
                    Button("複製") { duplicate(at: current) }.disabled(isPlaying)
                    Button("削除", role: .destructive) { delete(at: current) }
                        .disabled(store.frames.count < 2 || isPlaying)
                }
                .buttonStyle(.bordered)

                VStack(spacing: 6) {
                    Picker("形式", selection: $exportKind) {
                        ForEach(ExportKind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    Picker("大きさ", selection: $exportSize) {
                        ForEach(ExportSize.allCases) { z in Text(z.rawValue).tag(z) }
                    }
                    .pickerStyle(.segmented)

                    if isExporting {
                        ProgressView(value: exportProgress)
                        Text("書き出し中… \(Int(exportProgress * 100))%")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button { askName = true } label: {
                            Label("書き出す", systemImage: "square.and.arrow.up").font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.frames.count < 2)
                    }
                    if exportKind == .png {
                        Text("zip にまとめて渡します。中身は通し番号の PNG です。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(spacing: 6) {
                    Text(store.projectName)
                        .font(.callout.bold())
                        .lineLimit(1).truncationMode(.middle)
                    Text(store.folder.lastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button("新規") { newProjectName = ""; askNewProject = true }
                        Button("開く") { showOpen = true }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(isPlaying)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(panel)
    }

    /// 保存済みプロジェクトの一覧
    private var openSheet: some View {
        NavigationStack {
            List(FrameStore.savedProjects(), id: \.self) { url in
                Button {
                    openProject(url)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).font(.body)
                        Text(frameCountText(url)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("プロジェクトを開く")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { showOpen = false }
                }
            }
        }
    }

    private func frameCountText(_ url: URL) -> String {
        let n = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(".png") }.count
        return "\(n) コマ"
    }

    private func startNew() {
        commitCurrent()
        store.flush()
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        store.startNewProject(named: name.isEmpty ? "ラフガキちゃん" : name)
        current = 0
        drawing = PKDrawing()
        background = PKDrawing()
        layer = .art
        addFrame()
    }

    private func openProject(_ url: URL) {
        commitCurrent()
        store.flush()
        showOpen = false
        if store.open(url) {
            current = 0
            loadBackground()
            loadDrawing(at: 0)
        } else {
            alertMessage = "このプロジェクトを開けませんでした。"
        }
    }

    // MARK: 動作

    private func ensureFirstFrame() {
        loadBackground()
        if store.frames.isEmpty { addFrame() }
    }

    /// いま描いている内容を、そのコマの絵とストローク情報として保存する
    /// レイヤーを切り替えたとき。
    /// キャンバスの接続先は常に drawing なので、中身を入れ替える。
    private func switchedLayer() {
        if layer == .back {
            // 作画を確定してから、背景をキャンバスに載せる
            commitArt()
            drawing = background
        } else {
            // 背景を確定してから、作画をキャンバスに戻す
            background = drawing
            saveBackground()
            loadDrawing(at: current)
            rebuildAllFrames()
        }
    }

    private func saveBackground() {
        let w = displayWidth
        let n = w > 1 ? background.normalized(fromDisplayWidth: w) : background
        store.writeProjectFile(n.dataRepresentation(), named: "background.drawing")
        backgroundImage = n.renderedTransparent()
    }

    private func loadBackground() {
        let w = displayWidth
        if let data = store.readProjectFile(named: "background.drawing"),
           let d = try? PKDrawing(data: data) {
            background = w > 1 ? d.fitted(toDisplayWidth: w) : d
        } else {
            background = PKDrawing()
        }
        if layer == .back { drawing = background }
        let n = w > 1 ? background.normalized(fromDisplayWidth: w) : background
        backgroundImage = n.renderedTransparent()
    }

    /// 背景が変わったので、全コマの絵を描き直す
    private func rebuildAllFrames() {
        let w = displayWidth
        guard w > 1, !store.frames.isEmpty else { return }
        let bg = background.normalized(fromDisplayWidth: w)
        let alpha = backgroundOpacity
        rebuilding = true
        DispatchQueue.global(qos: .userInitiated).async {
            var rendered: [(Int, CGImage)] = []
            for (i, f) in store.frames.enumerated() {
                let art: PKDrawing
                if let data = store.readSidecar(for: f, ext: "drawing"),
                   let d = try? PKDrawing(data: data) { art = d } else { art = PKDrawing() }
                if let img = PKDrawing.renderPaper(background: bg, foreground: art,
                                                   backgroundAlpha: alpha) {
                    rendered.append((i, img))
                }
            }
            DispatchQueue.main.async {
                for (i, img) in rendered where store.frames.indices.contains(i) {
                    store.replace(at: i, with: img)
                }
                rebuilding = false
            }
        }
    }

    /// 描いた内容を、そのコマの絵とストローク情報として保存する。
    /// 画面上の座標のまま保存すると紙の一部に縮こまるので、1920 基準へ直す。
    private func commitCurrent() {
        if layer == .back {
            background = drawing
            saveBackground()
            return
        }
        commitArt()
    }

    /// 作画レイヤーの内容を、そのコマの絵とストローク情報として保存する
    private func commitArt() {
        guard store.frames.indices.contains(current) else { return }
        let w = displayWidth
        // 実寸が取れないうちは等倍で保存する。何も残らないよりはよい。
        let normalized = w > 1 ? drawing.normalized(fromDisplayWidth: w) : drawing
        let bg = w > 1 ? background.normalized(fromDisplayWidth: w) : background
        guard let img = PKDrawing.renderPaper(background: bg, foreground: normalized,
                                              backgroundAlpha: backgroundOpacity) else { return }
        store.replace(at: current, with: img)
        store.writeSidecar(normalized.dataRepresentation(),
                           for: store.frames[current], ext: "drawing")
    }

    private func addFrame() {
        guard layer == .art else { return }
        commitCurrent()
        let blank = PKDrawing()
        guard let img = blank.renderedOnPaper() else { return }
        if store.frames.isEmpty {
            store.append(img)
            current = 0
        } else {
            current = store.insert(img, after: current)
        }
        drawing = blank
    }

    /// 長押しでつかんだコマを、落とした場所へ移す
    private func drop(onto target: Int) -> Bool {
        defer { dragFrom = nil; dropAt = nil }
        guard let from = dragFrom, from != target else { return false }
        return moveFrame(from, to: target)
    }

    /// コマを指定の位置へ移す
    @discardableResult
    private func moveFrame(_ from: Int, to: Int) -> Bool {
        guard layer == .art, !isPlaying else { return false }
        guard store.frames.indices.contains(from), store.frames.indices.contains(to) else { return false }
        commitCurrent()
        store.move(from: from, to: to)
        current = to
        loadDrawing(at: to)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    /// コマの並びを入れ替える
    private func moveFrame(_ index: Int, by delta: Int) {
        let to = index + delta
        guard store.frames.indices.contains(index), store.frames.indices.contains(to) else { return }
        commitCurrent()
        store.move(from: index, to: to)
        current = to
        loadDrawing(at: to)
    }

    private func loadDrawing(at index: Int) {
        guard store.frames.indices.contains(index) else { drawing = PKDrawing(); return }
        if let data = store.readSidecar(for: store.frames[index], ext: "drawing"),
           let d = try? PKDrawing(data: data) {
            // 保存されているのは 1920 基準なので、画面の大きさに合わせ直す
            let w = displayWidth
            drawing = w > 1 ? d.fitted(toDisplayWidth: w) : d
        } else {
            drawing = PKDrawing()
        }
    }

    /// 下書き用の色（青・赤）で描いた線をまとめて消す
    private func clearDraftColors() {
        let drafts = inkChoices.dropFirst().map { UIColor($0.1) }
        let removed = drawing.removingStrokes(matching: Array(drafts))
        guard removed.strokes.count != drawing.strokes.count else { return }
        canvas?.registerUndoStep(restoring: drawing)
        drawing = removed
        commitCurrent()
    }

    private func go(to index: Int) {
        guard layer == .art else { return }
        guard !isPlaying, store.frames.indices.contains(index), index != current else { return }
        commitCurrent()
        current = index
        loadDrawing(at: index)
    }

    private func duplicate(at index: Int) {
        commitCurrent()
        store.duplicate(at: index)
        // 複製先は別ファイルなので、ストローク情報も複写する（1920基準のまま）
        if let data = store.readSidecar(for: store.frames[index], ext: "drawing") {
            store.writeSidecar(data, for: store.frames[index + 1], ext: "drawing")
        }
        current = min(index + 1, store.frames.count - 1)
    }

    private func delete(at index: Int) {
        guard store.frames.count > 1 else { return }
        store.remove(at: index)
        current = min(current, store.frames.count - 1)
        loadDrawing(at: current)
    }

    private func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    private func startPlayback() {
        commitCurrent()
        guard store.frames.count >= 2 else { return }
        isPlaying = true
        playPos = 0
        restartTimer()
    }

    private func restartTimer() {
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { _ in
            let n = store.expandedIndices.count
            guard n > 0 else { return }
            playPos = (playPos + 1) % n
        }
    }

    private func stopPlayback() {
        playTimer?.invalidate(); playTimer = nil; isPlaying = false
    }

    private func exportMovie() {
        commitCurrent()
        stopPlayback()
        store.flush()
        guard store.frames.count >= 2 else { return }

        let urls = store.expandedURLs
        let rate = Int(fps)
        let size = exportSize
        let kind = exportKind
        let name = FrameStore.sanitize(exportName)
        let tmp = FileManager.default.temporaryDirectory

        isExporting = true
        exportProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result: URL
                switch kind {
                case .mp4:
                    let out = tmp.appendingPathComponent("\(name).mp4")
                    try MP4Exporter.write(urls: urls, fps: rate, to: out, size: size) { v in
                        exportProgress = v
                    }
                    result = out
                case .png:
                    let folder = try SequenceExporter.writeFolder(
                        urls: urls, named: name, to: tmp, size: size) { v in
                        exportProgress = v * 0.9
                    }
                    result = try SequenceExporter.zipFolder(folder)
                }
                DispatchQueue.main.async {
                    isExporting = false; shareURL = result; showShare = true
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false; alertMessage = error.localizedDescription
                }
            }
        }
    }
}
