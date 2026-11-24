import SwiftUI

/// Editing slider: label + value, gradient track, drag anywhere, double-tap to reset.
struct LSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var defaultValue: Double = 0
    var step: Double = 1
    var gradient: [Color]? = nil
    var format: (Double) -> String = { v in
        let r = v.rounded()
        return r > 0 ? "+\(Int(r))" : "\(Int(r))"
    }
    var onCommit: () -> Void = {}

    @State private var dragStart: Double?

    private var span: Double { range.upperBound - range.lowerBound }
    private func frac(_ v: Double) -> CGFloat { CGFloat((v - range.lowerBound) / span) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(value == defaultValue ? Theme.text2 : .white)
                Spacer()
                Text(format(value)).font(.system(size: 13).monospacedDigit()).foregroundStyle(value == defaultValue ? Theme.text2 : .white)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(gradient.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(Color(white: 0.28)))
                        .frame(height: gradient == nil ? 3 : 5)
                    if gradient == nil {
                        let a = frac(defaultValue), b = frac(value)
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: max(0, abs(b - a) * w), height: 3)
                            .offset(x: min(a, b) * w)
                    }
                    if defaultValue > range.lowerBound && defaultValue < range.upperBound {
                        Rectangle().fill(Color(white: 0.5)).frame(width: 1, height: 9).offset(x: frac(defaultValue) * w)
                    }
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: frac(value) * w - 9)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        let nv = dragStart! + Double(g.translation.width / w) * span
                        let stepped = (nv / step).rounded() * step
                        value = min(max(stepped, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil; onCommit() })
                .onTapGesture(count: 2) { value = defaultValue; onCommit() }
            }
            .frame(height: 22)
        }
        .padding(.vertical, 3)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }
}

struct Chip: View {
    let title: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Theme.accent.opacity(0.9) : Theme.panel2, in: Capsule())
                .foregroundStyle(selected ? .black : .white)
        }.buttonStyle(.plain)
    }
}

/// Hue/saturation wheel for colour grading.
struct ColorWheel: View {
    @Binding var hue: Double         // 0...360
    @Binding var saturation: Double  // 0...100
    var onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2
            let ang = hue * .pi / 180
            let rr = CGFloat(saturation / 100) * r
            ZStack {
                Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
                                              center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
                Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().stroke(.black.opacity(0.4), lineWidth: 1)
                Circle().fill(.white).frame(width: 16, height: 16).shadow(radius: 2)
                    .offset(x: cos(ang) * rr, y: sin(ang) * rr)
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let dx = g.location.x - r, dy = g.location.y - r
                    var a = atan2(dy, dx) * 180 / .pi
                    if a < 0 { a += 360 }
                    hue = a
                    saturation = min(100, Double(hypot(dx, dy) / r) * 100)
                }
                .onEnded { _ in onCommit() })
            .onTapGesture(count: 2) { saturation = 0; onCommit() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct HistogramView: View {
    let data: [[Float]]
    var body: some View {
        Canvas { ctx, size in
            guard data.count == 3 else { return }
            let colors: [Color] = [.red, .green, .blue]
            for c in 0..<3 {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                let n = data[c].count
                for (i, v) in data[c].enumerated() {
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(max(n - 1, 1)), y: size.height * (1 - CGFloat(sqrt(v)))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.blendMode = .screen
                ctx.fill(p, with: .color(colors[c].opacity(0.55)))
            }
        }
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// Gradients used by slider tracks
enum Tracks {
    static let temp = [Color(red: 0.25, green: 0.5, blue: 1), Color(white: 0.85), Color(red: 1, green: 0.8, blue: 0.2)]
    static let tint = [Color(red: 0.2, green: 0.8, blue: 0.3), Color(white: 0.85), Color(red: 0.9, green: 0.3, blue: 0.9)]
    static func hue(for band: ColorBand) -> [Color] {
        let h = band.hue / 360
        return [Color(hue: (h - 0.08 + 1).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 0.9),
                Color(hue: h, saturation: 0.9, brightness: 0.9),
                Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 0.9)]
    }
    static func sat(for band: ColorBand) -> [Color] {
        [Color(white: 0.6), Color(hue: band.hue / 360, saturation: 1, brightness: 0.95)]
    }
    static func lum(for band: ColorBand) -> [Color] {
        [Color(hue: band.hue / 360, saturation: 0.9, brightness: 0.25), Color(hue: band.hue / 360, saturation: 0.35, brightness: 1)]
    }
    static let sat = [Color(white: 0.6), Color(red: 1, green: 0.2, blue: 0.2), Color(red: 0.2, green: 0.4, blue: 1)]
}
