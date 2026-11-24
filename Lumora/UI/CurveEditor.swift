import SwiftUI

/// Point curve editor: tap to add a point, drag to move, double-tap a point to delete it.
struct CurveEditor: View {
    @ObservedObject var model: EditorModel
    @State private var channel: CurveChannel = .master
    @State private var dragIndex: Int?

    var color: Color {
        switch channel { case .master: return .white; case .red: return .red; case .green: return .green; case .blue: return Color(red: 0.3, green: 0.5, blue: 1) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ForEach(CurveChannel.allCases) { c in
                    Chip(title: c.rawValue, selected: channel == c) { channel = c }
                }
                Spacer()
                Button { model.edit { $0.setCurve(channel, EditSettings.identityCurve) } } label: { Image(systemName: "arrow.counterclockwise") }
            }
            GeometryReader { geo in
                let size = geo.size
                let pts = model.settings.curve(channel)
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.35))
                    Path { p in
                        for i in 1..<4 {
                            let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }.stroke(Color.white.opacity(0.12), lineWidth: 1)
                    Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) }
                        .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Path { p in
                        for i in 0...100 {
                            let x = Double(i) / 100
                            let pt = CGPoint(x: size.width * CGFloat(x), y: size.height * CGFloat(1 - Curves.evaluate(pts, x)))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }.stroke(color, lineWidth: 2)
                    ForEach(Array(pts.enumerated()), id: \.offset) { i, pt in
                        Circle().fill(color).frame(width: 14, height: 14)
                            .position(x: size.width * CGFloat(pt.x), y: size.height * CGFloat(1 - pt.y))
                            .onTapGesture(count: 2) {
                                guard i != 0 && i != pts.count - 1 else { return }
                                var p = pts; p.remove(at: i)
                                model.edit { $0.setCurve(channel, p) }
                            }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        var p = model.settings.curve(channel)
                        let x = min(max(Double(g.location.x / size.width), 0), 1)
                        let y = min(max(1 - Double(g.location.y / size.height), 0), 1)
                        if dragIndex == nil {
                            let start = CGPoint(x: g.startLocation.x / size.width, y: 1 - g.startLocation.y / size.height)
                            if let near = p.indices.min(by: { hypot(p[$0].x - start.x, p[$0].y - start.y) < hypot(p[$1].x - start.x, p[$1].y - start.y) }),
                               hypot(p[near].x - start.x, p[near].y - start.y) < 0.07 {
                                dragIndex = near
                            } else {
                                p.append(CurvePoint(x: Double(start.x), y: Curves.evaluate(p, Double(start.x))))
                                p.sort { $0.x < $1.x }
                                dragIndex = p.firstIndex { abs($0.x - Double(start.x)) < 1e-9 }
                            }
                        }
                        guard let i = dragIndex, i < p.count else { return }
                        // keep end points at the edges' x, keep order
                        var nx = x
                        if i == 0 { nx = min(nx, p.count > 1 ? p[1].x - 0.01 : 1) }
                        else if i == p.count - 1 { nx = max(nx, p[i - 1].x + 0.01) }
                        else { nx = min(max(nx, p[i - 1].x + 0.01), p[i + 1].x - 0.01) }
                        p[i] = CurvePoint(x: nx, y: y)
                        model.settings.setCurve(channel, p)
                    }
                    .onEnded { _ in dragIndex = nil; model.commit() })
            }
            .aspectRatio(1.6, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Tap to add a point · drag to adjust · double-tap a point to remove")
                .font(.system(size: 11)).foregroundStyle(Theme.text2)
        }.padding(.top, 6)
    }
}
