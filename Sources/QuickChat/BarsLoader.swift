import SwiftUI

/// Five accent equalizer bars, following CrychicUI's `BarsLoader` proportions.
/// Static (non-animated) heights are used when Reduce Motion is on.
struct BarsLoader: View {
    var label: String
    var barWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stillLevels: [Double] = [0.55, 0.9, 0.4, 0.75, 0.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            Canvas { canvas, size in
                let unit = size.width / 9
                let now = timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<5 {
                    let level = reduceMotion ? Self.stillLevels[index] : Self.level(index: index, at: now)
                    let height = size.height * level
                    let rect = CGRect(
                        x: CGFloat(index) * unit * 2,
                        y: size.height - height,
                        width: unit,
                        height: height
                    )
                    canvas.fill(Path(roundedRect: rect, cornerRadius: unit / 2), with: .color(.accentColor))
                }
            }
        }
        .frame(width: barWidth * 9, height: barWidth * 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private static func level(index: Int, at time: TimeInterval) -> Double {
        0.3 + 0.7 * (0.5 + 0.5 * sin(time * 2 * .pi * (0.9 + 0.23 * Double(index)) + Double(index)))
    }
}
