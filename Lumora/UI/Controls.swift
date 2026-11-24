import SwiftUI
import UIKit

/// Editing slider: drag horizontally anywhere on the row (vertical drags scroll the panel),
/// double-tap to reset to its default (0 for most sliders).
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
    @State private var active = false

    private var span: Double { range.upperBound - range.lowerBound }
    private func frac(_ v: Double) -> CGFloat { CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) }
    private var changed: Bool { abs(value - defaultValue) > step / 2 }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(label).font(.system(size: 13, weight: changed ? .semibold : .regular))
                    .foregroundStyle(changed ? .white : Color(white: 0.78))
                Spacer()
                Text(format(value)).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(active ? Theme.accent : (changed ? .white : Theme.text2))
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(gradient.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(Color.white.opacity(0.14)))
                        .frame(height: gradient == nil ? 3 : 4)
                    if gradient == nil {
                        let a = frac(defaultValue), b = frac(value)
                        Capsule().fill(Theme.gradient)
                            .frame(width: max(0, abs(b - a) * w), height: 3)
                            .offset(x: min(a, b) * w)
                    }
                    if defaultValue > range.lowerBound && defaultValue < range.upperBound {
                        Capsule().fill(Color.white.opacity(0.35)).frame(width: 2, height: 8).offset(x: frac(defaultValue) * w - 1)
                    }
                    Circle().fill(.white)
                        .frame(width: active ? 22 : 16, height: active ? 22 : 16)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .offset(x: frac(value) * w - (active ? 11 : 8))
                        .animation(.easeOut(duration: 0.12), value: active)
                }
                .frame(height: 22)
            }
            .frame(height: 22)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .overlay(
            SliderGestureView(
                onBegan: { dragStart = value; active = true; UISelectionFeedbackGenerator().selectionChanged() },
                onChanged: { dx, width in
                    guard let start = dragStart, width > 0 else { return }
                    let nv = start + Double(dx / width) * span
                    let stepped = (nv / step).rounded() * step
                    let clamped = min(max(stepped, range.lowerBound), range.upperBound)
                    // gentle detent at the default value
                    if (value - defaultValue) * (clamped - defaultValue) < 0 { UISelectionFeedbackGenerator().selectionChanged() }
                    value = clamped
                },
                onEnded: { dragStart = nil; active = false; onCommit() },
                onDoubleTap: {
                    value = defaultValue
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onCommit()
                })
        )
    }
}

/// UIKit gestures so horizontal drags move the slider while vertical drags still scroll.
struct SliderGestureView: UIViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat, CGFloat) -> Void
    var onEnded: () -> Void
    var onDoubleTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        v.addGestureRecognizer(tap)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SliderGestureView
        init(_ p: SliderGestureView) { parent = p }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let w = (g.view?.bounds.width ?? 1)
            switch g.state {
            case .began: parent.onBegan()
            case .changed: parent.onChanged(g.translation(in: g.view).x, w)
            case .ended, .cancelled, .failed: parent.onEnded()
            default: break
            }
        }
        @objc func doubleTap(_ g: UITapGestureRecognizer) { parent.onDoubleTap() }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14).padding(.bottom, 2)
    }
}

struct Chip: View {
    let title: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.panel2), in: Capsule())
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: selected ? 0 : 1))
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
