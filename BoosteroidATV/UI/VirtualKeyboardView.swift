import SwiftUI

/// An on-screen keyboard for typing into the streamed game — logging into a
/// launcher, searching, entering a name — none of which a gamepad can do.
///
/// Keys are sent straight through `InputEventHandler.sendKeyEvent` as Windows
/// Virtual-Key codes, the same encoding the hardware-keyboard path already uses
/// (see VideoSurfaceView's HID→VK table and BoosteroidControlChannel's
/// `keyboard/button` note). Each tap sends a down followed by an up, since the
/// remote gives no press-and-hold semantics here.
struct VirtualKeyboardView: View {
    /// Where the key events go. Weakly held by the caller's InputSender.
    let inputHandler: InputEventHandler?
    let onClose: () -> Void

    @State private var shifted = false

    // Windows Virtual-Key codes.
    private enum VK {
        static let back: UInt16 = 0x08
        static let tab: UInt16 = 0x09
        static let enter: UInt16 = 0x0D
        static let shift: UInt16 = 0x10
        static let escape: UInt16 = 0x1B
        static let space: UInt16 = 0x20
        static let left: UInt16 = 0x25
        static let up: UInt16 = 0x26
        static let right: UInt16 = 0x27
        static let down: UInt16 = 0x28
    }

    private let rows: [[String]] = [
        ["1","2","3","4","5","6","7","8","9","0"],
        ["Q","W","E","R","T","Y","U","I","O","P"],
        ["A","S","D","F","G","H","J","K","L"],
        ["Z","X","C","V","B","N","M"],
    ]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in
                        keyButton(shifted ? key : key.lowercased()) {
                            send(vk: UInt16(key.unicodeScalars.first!.value))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                keyButton(shifted ? "Shift ON" : "Shift", wide: true) { shifted.toggle() }
                keyButton("Space", wide: true) { send(vk: VK.space) }
                keyButton("Enter", wide: true) { send(vk: VK.enter) }
                keyButton("Back", wide: true) { send(vk: VK.back) }
            }
            HStack(spacing: 10) {
                keyButton("Esc") { send(vk: VK.escape) }
                keyButton("Tab") { send(vk: VK.tab) }
                keyButton("←") { send(vk: VK.left) }
                keyButton("↑") { send(vk: VK.up) }
                keyButton("↓") { send(vk: VK.down) }
                keyButton("→") { send(vk: VK.right) }
                keyButton("Close", wide: true, tint: .red) { onClose() }
            }
        }
        .padding(28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func keyButton(_ label: String, wide: Bool = false, tint: Color = .gray,
                           action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .tint(tint)
            .frame(minWidth: wide ? 150 : 70)
    }

    /// Tap = press and release. `shifted` is reported as the modifier bit the
    /// hardware-keyboard path uses, so capitals and symbols behave the same way.
    private func send(vk: UInt16) {
        let modifiers: UInt16 = shifted ? 0x0001 : 0
        inputHandler?.sendKeyEvent(down: true, vk: vk, scancode: 0, modifiers: modifiers)
        inputHandler?.sendKeyEvent(down: false, vk: vk, scancode: 0, modifiers: modifiers)
    }
}
