import SwiftUI
import PencilKit

/// 描画の基準となる座標系。画面の大きさに関わらずこの寸法で保存する。
enum CanvasSpec {
    static let width: CGFloat = 1920
    static let height: CGFloat = 1080
    static var size: CGSize { CGSize(width: width, height: height) }
    static var ratio: CGFloat { width / height }
}

/// 道具の種類
enum DrawTool: String, CaseIterable, Identifiable {
    case pencil = "鉛筆"
    case pen    = "ペン"
    case marker = "マーカー"
    case eraser = "消しゴム"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pencil: return "pencil"
        case .pen:    return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        }
    }

    func pkTool(color: UIColor, width: CGFloat, eraser: EraserMode) -> PKTool {
        switch self {
        case .pencil: return PKInkingTool(.pencil, color: color, width: width)
        case .pen:    return PKInkingTool(.pen,    color: color, width: width)
        case .marker: return PKInkingTool(.marker, color: color, width: width * 2.5)
        case .eraser: return eraser.pkTool(width: width)
        }
    }
}

/// 消しゴムの効き方。
/// 白で上から描く「消し鉛筆」は、背景レイヤーまで塗り潰してしまうので廃止した。
/// ここでは本当にインクを取り除く。
enum EraserMode: String, CaseIterable, Identifiable {
    /// なぞった所を消す
    case hard  = "ふつう"
    /// 触れた線を丸ごと消す
    case whole = "線ごと"
    /// なぞった所の青・赤だけを消す（自前で処理する）
    case draft = "下書きだけ"

    var id: String { rawValue }

    /// PencilKit の道具で処理できるか（できないものは自前）
    var usesPencilKit: Bool { self != .draft }

    /// 大きさを指定できるか（線ごとは触れた線を丸ごと消すので関係ない）
    var usesSize: Bool { self != .whole }

    func pkTool(width: CGFloat) -> PKTool {
        switch self {
        case .hard:  return PKEraserTool(.fixedWidthBitmap, width: max(4, width))
        case .whole: return PKEraserTool(.vector)
        case .draft: return PKEraserTool(.fixedWidthBitmap, width: max(4, width))
        }
    }
}

/// 消しゴムの大きさ。細かく刻むより、迷わず選べることを優先して三段にする。
enum EraserSize: String, CaseIterable, Identifiable {
    case small  = "小"
    case medium = "中"
    case large  = "大"

    var id: String { rawValue }

    /// 鉛筆の既定が 6 なので、小は線一本をなぞれる太さから始める
    var width: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 32
        case .large:  return 72
        }
    }
}

/// ウインドウに載ったことを知らせるキャンバス
final class CanvasView: PKCanvasView {
    var onAttached: ((CanvasView) -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAttached?(self) }
    }

    /// 自前で絵を差し替えたときに、取り消しの履歴へ1件だけ積む。
    /// PencilKit は自身の編集しか記録しないので、こちらで登録する。
    /// 取り消しの中で「やり直し」も登録されるため、往復できる。
    func registerUndoStep(restoring old: PKDrawing) {
        undoManager?.registerUndo(withTarget: self) { canvas in
            let now = canvas.drawing
            canvas.registerUndoStep(restoring: now)
            canvas.drawing = old
        }
    }
}

/// Apple Pencil で描くキャンバス。
/// PencilKit が筆圧・傾き・手のひら誤タッチ防止・低遅延描画を受け持つ。
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let tool: PKTool
    var onReady: (CanvasView) -> Void = { _ in }
    var onChange: (PKDrawing) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CanvasView {
        let v = CanvasView()
        v.delegate = context.coordinator
        v.drawingPolicy = .anyInput        // 指でも描ける
        v.backgroundColor = .clear
        v.isOpaque = false
        // ダークモードだと PencilKit が黒インクを白に反転させる。
        // 紙は白なので、キャンバスだけ明るい配色に固定する。
        v.overrideUserInterfaceStyle = .light
        v.alwaysBounceVertical = false
        v.alwaysBounceHorizontal = false
        v.drawing = drawing
        v.tool = tool
        v.onAttached = { canvas in
            canvas.becomeFirstResponder()
            context.coordinator.parent.onReady(canvas)
        }
        return v
    }

    func updateUIView(_ v: CanvasView, context: Context) {
        context.coordinator.parent = self
        if v.drawing != drawing { v.drawing = drawing }
        v.tool = tool
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        init(_ parent: DrawingCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            parent.onChange(canvasView.drawing)
        }
    }
}

// MARK: - 座標の正規化と書き出し

extension PKDrawing {
    /// 画面上の大きさで描いた線を、1920 幅の基準座標に直す
    func normalized(fromDisplayWidth w: CGFloat) -> PKDrawing {
        guard w > 1 else { return self }
        let k = CanvasSpec.width / w
        return transformed(using: CGAffineTransform(scaleX: k, y: k))
    }

    /// 基準座標の線を、画面上の大きさに合わせる
    func fitted(toDisplayWidth w: CGFloat) -> PKDrawing {
        guard w > 1 else { return self }
        let k = w / CanvasSpec.width
        return transformed(using: CGAffineTransform(scaleX: k, y: k))
    }

    /// 指定した色で描かれた線だけを取り除く（下書きの一括消去に使う）
    func removingStrokes(matching colors: [UIColor], tolerance: CGFloat = 0.12) -> PKDrawing {
        func rgb(_ c: UIColor) -> (CGFloat, CGFloat, CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        }
        let targets = colors.map(rgb)
        let kept = strokes.filter { stroke in
            let (r, g, b) = rgb(stroke.ink.color)
            return !targets.contains { t in
                abs(r - t.0) < tolerance && abs(g - t.1) < tolerance && abs(b - t.2) < tolerance
            }
        }
        return PKDrawing(strokes: kept)
    }

    /// なぞった所だけを線から取り除く。指定した色の線だけが対象。
    /// 線ごと消すのではなく、消しゴムの中に入った区間だけを切り落とす。
    func partiallyErased(at point: CGPoint, radius: CGFloat,
                         onlyColors colors: [UIColor], tolerance: CGFloat = 0.12) -> PKDrawing? {
        func rgb(_ c: UIColor) -> (CGFloat, CGFloat, CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a); return (r, g, b)
        }
        let want = colors.map(rgb)
        var out: [PKStroke] = []
        var changed = false

        for stroke in strokes {
            let (r, g, b) = rgb(stroke.ink.color)
            let isTarget = want.contains {
                abs(r - $0.0) < tolerance && abs(g - $0.1) < tolerance && abs(b - $0.2) < tolerance
            }
            let pts = Array(stroke.path)
            guard isTarget, pts.count >= 2 else { out.append(stroke); continue }

            let inside = pts.map { pt -> Bool in
                let l = pt.location.applying(stroke.transform)
                return hypot(l.x - point.x, l.y - point.y) < radius
            }
            guard inside.contains(true) else { out.append(stroke); continue }
            changed = true

            var i = 0
            while i < pts.count {
                let state = inside[i]
                var j = i
                while j < pts.count && inside[j] == state { j += 1 }
                if !state {
                    let slice = Array(pts[i..<min(j + 1, pts.count)])
                    if slice.count >= 2 {
                        let path = PKStrokePath(controlPoints: slice,
                                                creationDate: stroke.path.creationDate)
                        out.append(PKStroke(ink: stroke.ink, path: path,
                                            transform: stroke.transform, mask: stroke.mask))
                    }
                }
                i = j
            }
        }
        return changed ? PKDrawing(strokes: out) : nil
    }

    /// 背景と作画を重ねて、白い紙の上の絵として書き出す（1920x1080）
    static func renderPaper(background: PKDrawing?, foreground: PKDrawing,
                            backgroundAlpha: CGFloat = 1) -> CGImage? {
        let rect = CGRect(origin: .zero, size: CanvasSpec.size)
        func strokes(_ d: PKDrawing) -> CGImage? {
            var out: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                out = d.image(from: rect, scale: 1)
            }
            return out?.cgImage
        }
        guard let ctx = CGContext(data: nil,
                                  width: Int(CanvasSpec.width), height: Int(CanvasSpec.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        if let bg = background, let img = strokes(bg), backgroundAlpha > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(backgroundAlpha)
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }
        if let img = strokes(foreground) { ctx.draw(img, in: rect) }
        return ctx.makeImage()
    }

    /// 背景だけを、透ける状態で画像にする（作画中の下敷き用）
    func renderedTransparent() -> CGImage? {
        let rect = CGRect(origin: .zero, size: CanvasSpec.size)
        var out: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            out = image(from: rect, scale: 1)
        }
        return out?.cgImage
    }

    /// 白い紙の上に描いた絵として書き出す（1920x1080）
    ///
    /// PKDrawing.image() は、そのときのアプリの配色設定に従って描画する。
    /// ダーク配色のままだと黒インクが白へ反転し、白い紙に重ねると消えてしまう。
    /// 紙は常に白なので、明るい配色を指定した状態で描き出す。
    func renderedOnPaper() -> CGImage? {
        let rect = CGRect(origin: .zero, size: CanvasSpec.size)
        var rendered: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = image(from: rect, scale: 1)
        }
        guard let strokes = rendered?.cgImage else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: Int(CanvasSpec.width), height: Int(CanvasSpec.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(strokes, in: rect)
        return ctx.makeImage()
    }
}
