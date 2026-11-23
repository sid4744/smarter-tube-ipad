import SwiftUI

/// The close button from a Windows XP title bar: a glossy red-orange square, white border, white ✕.
struct XPCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.click()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(red: 0.96, green: 0.62, blue: 0.50),
                                                  Color(red: 0.88, green: 0.33, blue: 0.18),
                                                  Color(red: 0.76, green: 0.20, blue: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                         startPoint: .top, endPoint: .center))
                    .padding(3)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white, lineWidth: 2.5)
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: Color(red: 0.45, green: 0.08, blue: 0.02), radius: 0, x: 1, y: 1)
            }
            .frame(width: 48, height: 48)
            .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 2)
            .padding(10) // a bigger target than it looks
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Close")
    }
}

/// Playback speed as a row of green bars you slide along, like the set's volume display.
struct SpeedSlider: View {
    let rate: Double
    let onChange: (Double) -> Void
    var onTouch: () -> Void = {}

    static let steps: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OSDText(String(format: "SPEED %gX", rate), size: 16)
            GeometryReader { g in
                HStack(spacing: 6) {
                    ForEach(Self.steps.indices, id: \.self) { i in
                        Rectangle()
                            .fill(Color.osdGreen.opacity(Self.steps[i] <= rate + 0.001 ? 1 : 0.22))
                            .overlay(alignment: .top) {
                                if Self.steps[i] == 1 { // a notch at normal speed
                                    Rectangle().fill(Color.osdGreen).frame(width: 2, height: 6).offset(y: -9)
                                }
                            }
                    }
                }
                .frame(height: 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { d in
                        onTouch()
                        let n = Self.steps.count
                        let i = min(n - 1, max(0, Int(d.location.x / max(1, g.size.width) * CGFloat(n))))
                        if Self.steps[i] != rate {
                            Haptics.tap()
                            onChange(Self.steps[i])
                        }
                    }
                )
            }
            .frame(height: 44)
        }
    }
}
