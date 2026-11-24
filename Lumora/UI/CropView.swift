import SwiftUI

let cropAspects: [(String, Double?)] = [("Free", nil), ("Original", -1), ("1:1", 1), ("4:5", 4.0 / 5), ("5:4", 5.0 / 4),
                                         ("3:2", 3.0 / 2), ("2:3", 2.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3)]

struct CropPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PanelScroll {
            SectionTitle(text: "Aspect Ratio")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(cropAspects, id: \.0) { a in
                        Chip(title: a.0, selected: model.settings.cropAspect == a.0) { setAspect(a.0, a.1) }
                    }
                }
            }
            LSlider(label: "Straighten", value: model.b(\.straighten), range: -45...45, step: 0.1,
                    format: { String(format: "%+.1f°", $0) }, onCommit: model.commit)
            HStack(spacing: 22) {
                Button { model.edit { $0.rotation90 = ($0.rotation90 + 3) % 4; $0.crop = .full } } label: { Label("Left", systemImage: "rotate.left") }
                Button { model.edit { $0.rotation90 = ($0.rotation90 + 1) % 4; $0.crop = .full } } label: { Label("Right", systemImage: "rotate.right") }
                Button { model.edit { $0.flipH.toggle() } } label: { Label("Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                Button { model.edit { $0.flipV.toggle() } } label: { Label("Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
            }.labelStyle(.iconOnly).font(.system(size: 22)).padding(.vertical, 10)
            Button("Reset Crop") { model.edit { $0.crop = .full; $0.straighten = 0; $0.cropAspect = "Original"; $0.rotation90 = 0; $0.flipH = false; $0.flipV = false } }
                .font(.footnote)
        }
    }

    func setAspect(_ name: String, _ ratio: Double?) {
        model.edit { s in
            s.cropAspect = name
            guard let ratio, let img = model.preview else { return }
            let imgAspect = Double(img.size.width / img.size.height)
            if ratio < 0 { s.crop = .full; return }
            // largest centred rect with the requested aspect
            var w = 1.0, h = imgAspect / ratio
            if h > 1 { h = 1; w = ratio / imgAspect }
            s.crop = NormRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
        }
    }
}

/// Shows the uncropped image with a draggable crop rectangle.
struct CropOverlay: View {
    @ObservedObject var model: EditorModel
    let image: UIImage
    let container: CGSize
    @State private var start: NormRect?

    var fitted: CGRect {
        let inset: CGFloat = 20
        let avail = CGSize(width: container.width - inset * 2, height: container.height - inset * 2)
        let s = min(avail.width / image.size.width, avail.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    var lockedRatio: Double? {
        guard let a = cropAspects.first(where: { $0.0 == model.settings.cropAspect })?.1 else { return nil }
        if a < 0 { return Double(image.size.width / image.size.height) }
        return a
    }

    var body: some View {
        let f = fitted
        let c = model.settings.crop
        let r = CGRect(x: f.minX + CGFloat(c.x) * f.width, y: f.minY + CGFloat(c.y) * f.height,
                       width: CGFloat(c.w) * f.width, height: CGFloat(c.h) * f.height)
        ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable().frame(width: f.width, height: f.height)
                .rotationEffect(.degrees(model.settings.straighten))
                .scaleEffect(straightenFill(f.size))
                .position(x: f.midX, y: f.midY)
            // dim outside
            Path { p in p.addRect(CGRect(origin: .zero, size: container)); p.addRect(r) }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            // thirds grid + border
            Path { p in
                for i in 1..<3 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }.stroke(Color.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false)
            Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .contentShape(Rectangle())
                .gesture(moveGesture(f))
            ForEach(0..<4) { i in
                let pt = CGPoint(x: i % 2 == 0 ? r.minX : r.maxX, y: i < 2 ? r.minY : r.maxY)
                Circle().fill(.white).frame(width: 22, height: 22).position(pt)
                    .gesture(cornerGesture(i, f))
            }
        }
        .frame(width: container.width, height: container.height)
    }

    func straightenFill(_ s: CGSize) -> CGFloat {
        let a = abs(model.settings.straighten) * .pi / 180
        return max((s.width * cos(a) + s.height * sin(a)) / s.width, (s.width * sin(a) + s.height * cos(a)) / s.height)
    }

    func moveGesture(_ f: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { g in
                if start == nil { start = model.settings.crop }
                guard var c = start else { return }
                c.x = min(max(0, c.x + Double(g.translation.width / f.width)), 1 - c.w)
                c.y = min(max(0, c.y + Double(g.translation.height / f.height)), 1 - c.h)
                model.settings.crop = c
            }
            .onEnded { _ in start = nil; model.commit() }
    }

    func cornerGesture(_ i: Int, _ f: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { g in
                if start == nil { start = model.settings.crop }
                guard let s = start else { return }
                let dx = Double(g.translation.width / f.width), dy = Double(g.translation.height / f.height)
                var x0 = s.x, y0 = s.y, x1 = s.x + s.w, y1 = s.y + s.h
                if i % 2 == 0 { x0 = min(max(0, x0 + dx), x1 - 0.05) } else { x1 = max(min(1, x1 + dx), x0 + 0.05) }
                if i < 2 { y0 = min(max(0, y0 + dy), y1 - 0.05) } else { y1 = max(min(1, y1 + dy), y0 + 0.05) }
                if let ratio = lockedRatio {
                    // normalised height for the locked pixel ratio
                    let imgAspect = Double(f.width / f.height)
                    let w = x1 - x0
                    var h = w * imgAspect / ratio
                    if i < 2 { y0 = y1 - h; if y0 < 0 { y0 = 0; h = y1; let nw = h * ratio / imgAspect; if i % 2 == 0 { x0 = x1 - nw } else { x1 = x0 + nw } } }
                    else { y1 = y0 + h; if y1 > 1 { y1 = 1; h = 1 - y0; let nw = h * ratio / imgAspect; if i % 2 == 0 { x0 = x1 - nw } else { x1 = x0 + nw } } }
                }
                model.settings.crop = NormRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
            }
            .onEnded { _ in start = nil; model.commit() }
    }
}
