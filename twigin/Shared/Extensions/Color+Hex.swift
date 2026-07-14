import SwiftUI

extension Color {
    init(hex: UInt32) {
        let alpha = Double((hex >> 24) & 0xff) / 255.0
        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }
}
