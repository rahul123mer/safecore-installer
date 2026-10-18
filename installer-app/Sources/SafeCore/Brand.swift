import SwiftUI

/// SafeSpace brand colours, taken from safespaceglobal.ai.
enum Brand {
    static let navy = Color(hex: 0x081F5C)
    static let navyDeep = Color(hex: 0x05162B)
    static let cyan = Color(hex: 0x23BFFE)
    static let blue = Color(hex: 0x2387F7)
    static let ice = Color(hex: 0x9EECFA)
    static let sideText = Color(hex: 0xD5E2F7)
    static let sideMuted = Color(hex: 0x8FA6CC)

    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sidebar = LinearGradient(colors: [navy, navyDeep], startPoint: .top, endPoint: .bottom)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The SafeSpace mark (Resources/safespace-mark.png), shown in a single colour.
struct SafeSpaceMark: View {
    var body: some View {
        if let path = Bundle.main.path(forResource: "safespace-mark", ofType: "png"), let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [Color(hex: 0x2E95FF), Brand.blue], startPoint: .top, endPoint: .bottom))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}
