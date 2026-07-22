import Foundation
import GameController
import LiveKitWebRTC

// MARK: - Input Event Handler
//
// Same shape as CloudNow's InputEventHandler protocol so VideoSurfaceView's
// keyboard/mouse capture code (HID → VK/scancode mapping) can be reused as-is.
protocol InputEventHandler: AnyObject {
    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16)
    func sendMouseMove(dx: Int16, dy: Int16)
    func sendMouseButton(down: Bool, button: UInt8)
    func sendMouseWheel(delta: Int16)
}

// MARK: - Input Sender
//
// TODO(protocol): this is a skeleton, not a working input encoder. GFN uses a
// proprietary binary packet format over its data channel (see CloudNow's
// InputSender.swift for the kind of detail involved — per-byte layout for
// keyboard/mouse/XInput gamepad frames, a protocol version negotiated on
// connect, etc). We have no idea yet whether Boosteroid:
//   - Uses WebRTC data channels for input at all (vs. e.g. a separate UDP
//     channel, or bundling input into the same channel as stats/control).
//   - Uses a comparable binary/XInput-style encoding, or something completely
//     different (e.g. a JSON event per key/button, more like a remote-desktop
//     protocol).
//   - Requires a handshake before input is accepted (GFN's InputSender waits
//     for a server "ready" message on the channel before sending anything).
//
// Until that's captured from real traffic, every `send*` method below is a
// no-op that only logs what it *would* send, so the rest of the app (video
// rendering, UI, session lifecycle) can be built and tested independently of
// the input protocol.
final class InputSender: InputEventHandler {
    private weak var dataChannel: LKRTCDataChannel?
    private var controllerPollTask: Task<Void, Never>?

    /// Radial deadzone applied to analog stick axes (0.0–1.0).
    var deadzone: Float = 0.15

    init(dataChannel: LKRTCDataChannel?) {
        self.dataChannel = dataChannel
    }

    func start() {
        observeControllers()
    }

    func stop() {
        controllerPollTask?.cancel()
        controllerPollTask = nil
    }

    // MARK: - Keyboard

    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16) {
        log("key", ["down": down, "vk": vk, "scancode": scancode, "modifiers": modifiers])
    }

    // MARK: - Mouse

    func sendMouseMove(dx: Int16, dy: Int16) {
        log("mouseMove", ["dx": dx, "dy": dy])
    }

    func sendMouseButton(down: Bool, button: UInt8) {
        log("mouseButton", ["down": down, "button": button])
    }

    func sendMouseWheel(delta: Int16) {
        log("mouseWheel", ["delta": delta])
    }

    // MARK: - Controller
    //
    // TODO(protocol): reading GCController state is the easy, protocol-agnostic
    // part (unchanged from any tvOS game). Encoding that state into whatever
    // Boosteroid's server expects (an XInput-style struct? something else
    // entirely?) is the unknown part.

    private func observeControllers() {
        controllerPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let pad = GCController.controllers.first?.extendedGamepad {
                    self?.pollGamepad(pad)
                }
                try? await Task.sleep(for: .milliseconds(16)) // ~60Hz poll
            }
        }
    }

    private func pollGamepad(_ pad: GCExtendedGamepad) {
        let lx = applyDeadzone(pad.leftThumbstick.xAxis.value)
        let ly = applyDeadzone(pad.leftThumbstick.yAxis.value)
        let rx = applyDeadzone(pad.rightThumbstick.xAxis.value)
        let ry = applyDeadzone(pad.rightThumbstick.yAxis.value)
        log("gamepad", [
            "leftStick": [lx, ly], "rightStick": [rx, ry],
            "a": pad.buttonA.isPressed, "b": pad.buttonB.isPressed,
            "x": pad.buttonX.isPressed, "y": pad.buttonY.isPressed,
        ])
    }

    private func applyDeadzone(_ value: Float) -> Float {
        abs(value) < deadzone ? 0 : value
    }

    // MARK: - Private

    private func log(_ kind: String, _ payload: [String: Any]) {
        // TODO(protocol): replace with an actual binary/JSON send over
        // `dataChannel` once the wire format is known. Currently a no-op stub.
        #if DEBUG
        print("[InputSender] (stub, not sent) \(kind): \(payload)")
        #endif
    }
}
